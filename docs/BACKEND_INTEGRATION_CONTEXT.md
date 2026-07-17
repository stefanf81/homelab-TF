# Backend Integration Context (for the Spring Boot repo)

This document is **hand-off context for an AI (or engineer) working on the TaskFlow
Spring Boot backend source repository** (`taskflow-backend`). It explains what the
*infrastructure* side (this `homelab/TF` repo) already assumes about the backend, and
exactly what still has to change in the backend so the monitoring stack we scaffolded
actually receives metrics.

Read `docs/ARCHITECTURE.md` first for the full platform picture. This file is the
backend-specific slice.

---

## 0. TL;DR — what the backend owes the infra

1. **Add `micrometer-registry-prometheus`** so `/actuator/prometheus` exists.
2. **Expose that endpoint** (`management.endpoints.web.exposure.include`).
3. **Let VictoriaMetrics scrape it unauthenticated** — Spring Security must permit
   `GET /actuator/prometheus` (and already must permit `/actuator/health/*`).
4. **Do not fight the container contract** — run as non-root UID `10001`, read-only
   root FS (only `/tmp` writable), heap via the `JAVA_TOOL_OPTIONS` env (already set
   by the deployment, don't hard-code heap in the Dockerfile).

Everything else (VictoriaMetrics, Grafana, the VMServiceScrape, exporters) is already wired
in the infra repo and will light up the moment the endpoint exists.

---

## 1. The deployment contract (already enforced — don't break it)

Defined in `gitops/apps/taskflow/backend.yaml`:

| Concern | Expectation | Why it matters to you |
|---------|-------------|----------------------|
| Image | `ghcr.io/stefanf81/taskflow-backend:latest`, digest-pinned by Flux | Push `:latest`; Flux rewrites to `@sha256:`. No manifest change needed for a deploy. |
| Listening port | **8080** (ContainerPort `http`) | Gateway routes `/api` → `backend:8080`. Don't change. |
| Liveness/readiness | `GET /actuator/health/liveness` and `/actuator/health/readiness` on 8080 | Probes already use these. Actuator health must stay enabled. |
| Security context | `runAsNonRoot: true`, `UID/GID 10001`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]` | The image **must** run as 10001 with no writes to the image layer. Mount only `/tmp` (already provided). Log to **stdout/stderr**, not a file. |
| Env (config) | `SPRING_PROFILES_ACTIVE=prod`, `APP_CORS_ALLOWED_ORIGINS`, secrets via `SPRING_SECURITY_PASSWORD` / `SPRING_DATASOURCE_PASSWORD` / `SPRING_DATA_REDIS_PASSWORD` (and `SPRING_REDIS_PASSWORD`) | Don't hard-code these; they come from ConfigMap/Secret. |
| JVM heap | Set via `JAVA_TOOL_OPTIONS` env: `-Xms1024m -Xmx1024m ...` (off-heap capped) | **Do not set `-Xmx` in the Dockerfile/entrypoint** — it would be overridden by the env anyway, but keep the image neutral so the deployment stays the source of truth. |
| Graceful shutdown | 45s termination grace | Configure `server.shutdown=graceful` so in-flight requests drain on rollout. |

The backend **already** sends traces to Jaeger (OTLP `jaeger:4317`/`4318`) — that
integration is infra-complete; nothing to do there unless you change the tracing lib.

---

## 2. The one missing piece: Prometheus metrics

### 2.1 Dependency to add

```gradle
// Spring Boot 3.5.3 — Micrometer Prometheus registry + Actuator
implementation 'org.springframework.boot:spring-boot-starter-actuator'
implementation 'io.micrometer:micrometer-registry-prometheus'
```

### 2.2 Application properties (prod profile)

```properties
# Expose the Prometheus scrape endpoint (and keep health/info for probes & ops).
management.endpoints.web.exposure.include=prometheus,health,info
management.endpoint.prometheus.enabled=true
management.endpoint.health.probes.enabled=true
management.health.livenessstate.enabled=true
management.health.readinessstate.enabled=true

# Optional but recommended: tag every series with the app + env so dashboards
# can filter cleanly once more services emit metrics.
management.metrics.tags.application=taskflow-backend
```

After this, `GET /actuator/prometheus` returns the OpenMetrics text format.

### 2.3 Spring Security — let VictoriaMetrics in

The scrape comes from **in-cluster** VictoriaMetrics (`vmagent` in namespace `monitoring`) over
**plain HTTP** on port 8080. There is **no mTLS and no auth** in front of the
scrape. You must permit the endpoint unauthenticated, otherwise `vmagent` records
the target as down / 401 and you get no series.

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                // Actuator probes + VictoriaMetrics scrape must be reachable without auth
                .requestMatchers("/actuator/health/**", "/actuator/prometheus").permitAll()
                .requestMatchers("/api/**").authenticated()   // your real app traffic
                .anyRequest().permitAll()                     // adjust to your needs
            )
            // ... rest of your config
        ;
        return http.build();
    }
}
```

> **Gotcha:** If you rely on a global `authenticated()` default or a CSRF policy that
> covers Actuator, the scrape (a plain `GET`, no session) will be rejected.
> The probe endpoints already have to be open for the existing liveness/readiness
> checks, so treat `/actuator/prometheus` the same way.

### 2.4 That's it for the backend

The VMServiceScrape is **already defined** in the infra repo at
`gitops/monitoring/app/vmservicescrapes.yaml` and looks like:

```yaml
- port: "8080"
  path: /actuator/prometheus
  interval: 30s
  scheme: http
selector: { matchLabels: { app: taskflow-backend } }   # matches the backend Service
```

It is valid today but collects **zero series** until 2.1–2.3 ship. No infra change is
required when you add the dependency — Flux will just start showing backend metrics in
Grafana within ~30s of the new image digest landing.

---

## 3. How to verify locally before pushing

```bash
# Build & run with the prod-like profile
SPRING_PROFILES_ACTIVE=prod ./gradlew bootRun
curl -s localhost:8080/actuator/prometheus | head
# Expect a stream of `# TYPE` / `jvm_*` / `http_server_requests_*` lines, not 404/401.
```

If that curl returns metrics, the cluster integration is already done.

---

## 4. Things NOT to do

- **Don't change the listening port from 8080** — the Gateway `HTTPRoute` and the
  VMServiceScrape both assume 8080.
- **Don't connect to Redis without password authentication** — Redis authentication is now enabled on the cluster. The deployment injects the password from the SOPS secret into your container under `SPRING_DATA_REDIS_PASSWORD` and `SPRING_REDIS_PASSWORD`. Ensure your application reads and uses these properties.
- **Don't add a `/metrics` path** — Spring Boot Actuator's Prometheus endpoint is
  `/actuator/prometheus` by default; the VMServiceScrape targets exactly that.
- **Don't require auth on `/actuator/prometheus`** (see 2.3).
- **Don't write to the filesystem** outside `/tmp` — the container root FS is read-only.
- **Don't set JVM heap in the image** — it's owned by `JAVA_TOOL_OPTIONS` in the
  deployment manifest.

---

## 5. Where things live on the infra side (for reference)

| File | What |
|------|------|
| `gitops/apps/taskflow/backend.yaml` | Deployment + Service (port 8080, probes, securityContext, JVM env) |
| `gitops/apps/taskflow/configmap.yaml` | `SPRING_PROFILES_ACTIVE=prod`, CORS origins |
| `gitops/monitoring/app/vmservicescrapes.yaml` | The `taskflow-backend` VMServiceScrape (waits on you) |
| `gitops/monitoring/platform/release.yaml` | victoria-metrics-k8s-stack (VictoriaMetrics + Grafana) |
| `docs/ARCHITECTURE.md` §10.9 | How to reach Grafana/VictoriaMetrics (via the public Gateway) |
