# Backend Integration Context (for the Spring Boot repo)

This document is **hand-off context for an AI (or engineer) working on the TaskFlow
Spring Boot backend source repository** (`taskflow-backend`). It explains what the
*infrastructure* side (this `homelab/TF` repo) already assumes about the backend and
the monitoring integration that the backend must preserve.

Read `docs/ARCHITECTURE.md` first for the full platform picture. This file is the
backend-specific slice.

---

## 0. TL;DR — what the backend owes the infra

1. **Keep `micrometer-registry-prometheus` and Actuator** in the backend build.
2. **Keep `/actuator/prometheus` exposed** (`management.endpoints.web.exposure.include`).
3. **Let VictoriaMetrics scrape it unauthenticated** — Spring Security permits only
   `GET /actuator/prometheus`; Cilium NetworkPolicy limits access to `monitoring`.
4. **Do not fight the container contract** — run as non-root UID `10001`, read-only
   root FS (only `/tmp` writable), heap via the `JAVA_TOOL_OPTIONS` env (already set
   by the deployment, don't hard-code heap in the Dockerfile).

VictoriaMetrics, Grafana, the VMServiceScrape, exporters, and the performance dashboard are
already wired in the infra repo.

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
| JVM heap | Owned by the **image** (`Dockerfile`): `-XX:MaxRAMPercentage=50.0` → 1GiB heap at the 2Gi limit | **Do not set `-Xmx` / `-XX:MaxDirectMemorySize` in `JAVA_TOOL_OPTIONS`** — Dockerfile CMD args win over `JAVA_TOOL_OPTIONS` for conflicting flags (JVM "last-wins"), so an env `-Xmx` would either be ignored (when RAM% is set) or silently override the image's direct-memory cap. The image is the single source of truth for JVM sizing; the deployment env adds only GC logging/caps. |
| Graceful shutdown | 45s termination grace | Configure `server.shutdown=graceful` so in-flight requests drain on rollout. |

The backend **already** sends traces to Jaeger (OTLP `jaeger:4317`/`4318`) — that
integration is infra-complete; nothing to do there unless you change the tracing lib.

---

## 2. Prometheus metrics contract

### 2.1 Build dependencies

```gradle
// Both dependencies are already declared in the backend build.
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

# Tag every series with the application name for dashboard filtering.
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
                .requestMatchers("/actuator/health/**").permitAll()
                .requestMatchers(HttpMethod.GET, "/actuator/prometheus").permitAll()
                .requestMatchers("/actuator/**").hasRole("ADMIN")
                .anyRequest().authenticated()
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

### 2.4 Scrape wiring

The VMServiceScrape is **already defined** in the infra repo at
`gitops/monitoring/app/vmservicescrapes.yaml` and looks like:

```yaml
- port: http
  path: /actuator/prometheus
  interval: 30s
  scheme: http
selector: { matchLabels: { app: taskflow-backend } }   # matches the backend Service
```

The backend Service exposes the matching named `http` port. The `allow-monitoring-scrape`
NetworkPolicy permits port 8080 from the `monitoring` namespace while the public Gateway has
no route to the backend's Actuator paths.

---

## 3. How to verify locally before pushing

```bash
# Build & run with the prod-like profile
SPRING_PROFILES_ACTIVE=prod ./gradlew bootRun
curl -s localhost:8080/actuator/prometheus | head
# Expect a stream of `# TYPE` / `jvm_*` / `http_server_requests_*` lines, not 404/401.
```

If that curl returns metrics, verify the output includes `jvm_memory_used_bytes`,
`http_server_requests_seconds`, and `hikaricp_connections_active` before deployment.

---

## 4. Things NOT to do

- **Don't change the listening port from 8080** — the Gateway `HTTPRoute` and the
  VMServiceScrape both assume 8080.
- **Don't connect to Redis without password authentication** — Redis authentication is now enabled on the cluster. The deployment injects the password from the SOPS secret into your container under `SPRING_DATA_REDIS_PASSWORD` and `SPRING_REDIS_PASSWORD`. Ensure your application reads and uses these properties.
- **Don't add a `/metrics` path** — Spring Boot Actuator's Prometheus endpoint is
  `/actuator/prometheus` by default; the VMServiceScrape targets exactly that.
- **Don't require auth on `/actuator/prometheus`** (see 2.3).
- **Don't write to the filesystem** outside `/tmp` — the container root FS is read-only.
- **Don't set JVM heap in `JAVA_TOOL_OPTIONS`** — it's owned by the image's
  `MaxRAMPercentage=50.0`. The deployment env only adds GC logging/caps. (Dockerfile CMD
  args override `JAVA_TOOL_OPTIONS` for conflicting flags, so an env `-Xmx` is at best ignored
  and at worst silently overrides the image's direct-memory cap.)

---

## 5. Where things live on the infra side (for reference)

| File | What |
|------|------|
| `gitops/apps/taskflow/backend.yaml` | Deployment + Service (port 8080, probes, securityContext, JVM env) |
| `gitops/apps/taskflow/configmap.yaml` | `SPRING_PROFILES_ACTIVE=prod`, CORS origins |
| `gitops/monitoring/app/vmservicescrapes.yaml` | The `taskflow-backend` VMServiceScrape (waits on you) |
| `gitops/monitoring/platform/release.yaml` | victoria-metrics-k8s-stack (VictoriaMetrics + Grafana) |
| `docs/ARCHITECTURE.md` §10.9 | How to reach Grafana/VictoriaMetrics (via the public Gateway) |
