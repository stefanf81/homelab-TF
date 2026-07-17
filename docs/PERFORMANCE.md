# TaskFlow — Performance Analysis

> **Scope note:** The initial review was static analysis (cluster unreachable). Since then the cluster is live and several findings have been resolved. The monitoring stack (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) is now fully deployed. The remaining blind spot — the backend's `/actuator/prometheus` endpoint — needs `micrometer-registry-prometheus` added in the app repo (see `BACKEND_INTEGRATION_CONTEXT.md`). Once that ships, every finding below becomes measurable.

---

## 1. Tier 1 — Likely real problems (fix first)

### 1.1 JVM off-heap memory is unbounded → OOM-restart risk (HIGH)
**File:** `gitops/apps/taskflow/backend.yaml`

```
-Xms1536m -Xmx1536m ... -XX:+ExitOnOutOfMemoryError
resources:
  requests: cpu 1000m, memory 2048Mi
  limits:   cpu 4000m, memory 2560Mi
```

- Heap is fixed at **1.5 GiB**. The container **requests 2 GiB**, so the *guaranteed* off-heap budget is only **512 MiB** (2 GiB − 1.5 GiB). Kubernetes only guarantees the request; under node memory pressure the pod can't grow toward its 2.56 GiB limit.
- Off-heap must hold: metaspace, compressed class space, thread stacks, **Netty/direct ByteBuffers** (OTLP export + JDBC + Lettuce Redis), mmap'd files, GC structures. A Spring Boot 3.5 app with JPA/Hibernate + Jackson + actuator + an OTLP agent routinely uses 400–900 MiB off-heap under load.
- `-XX:+ExitOnOutOfMemoryError` means **any** transient off-heap spike kills the JVM → pod restart → cold start (~110 s startup probe budget) → request errors.

**Fix (pick one, both is best):**
- Raise the memory request to meet the limit and add off-heap caps:
  ```yaml
  # Guaranteed QoS: requests == limits so the full budget is reserved and CPU isn't throttled
  requests: { cpu: "2000m", memory: "2Gi" }
  limits:   { cpu: "2000m", memory: "2Gi" }
  ```
  ```bash
  -Xms1024m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=512m
  ```
  (Heap 1 GiB + metaspace 256 MiB + direct 512 MiB ≈ 1.75 GiB, comfortably under 2 GiB, leaving ~256 MiB for thread stacks/GC. Trimmed from 3Gi/1.5GiB heap to free ~1 GiB on the 14 GiB node.)
- The README already admits metaspace/direct caps were "intentionally omitted until measured" — but with `ExitOnOutOfMemoryError` on, *unmeasured* means *unprotected*. Cap them now.

### 1.2 ~~No observability → you are tuning blind~~ (RESOLVED — infra side)
**Files:** `gitops/monitoring/platform/release.yaml` (VictoriaMetrics stack), `gitops/monitoring/app/vmservicescrapes.yaml` (app scrapes)

> **Resolved (infrastructure):** The monitoring stack is deployed and collecting cluster-wide metrics:
> - **VictoriaMetrics** (VMSingle + vmagent) — replaces Prometheus, ~⅓ the RAM
> - **Grafana** — dashboards queryable at `https://grafana.jokelab.dev`
> - **kube-state-metrics** — pod/Deployment/replica/namespace resource metrics
> - **node-exporter** — host-level CPU/memory/disk/network per node
> - **PostgreSQL exporter** — DB query latency, active connections, cache hit ratio
> - **Redis exporter** — cache hit rate, memory usage, evictions
> - **Falco** — runtime security event metrics
>
> **Remaining gap (backend app repo):** The backend's `/actuator/prometheus` is still INERT — no `micrometer-registry-prometheus` dependency in the app build. Until that ships, you cannot see JVM GC, heap, HTTP request latencies, or DB pool metrics from the backend. See `docs/BACKEND_INTEGRATION_CONTEXT.md` for the exact 3-line change required. This is the single prerequisite for confirming items 1.1, 2.1, 2.2 with real data.

### 1.3 ~~PostgreSQL runs on Longhorn (network storage)~~ (RESOLVED)
**File:** `gitops/apps/taskflow/postgres-pvc.yaml` (`storageClassName: proxmox-csi`)

> **Resolved:** PostgreSQL has been migrated from Longhorn to native **Proxmox CSI** storage. Disk space is scaled to `10Gi` and volumes are dynamically provisioned on your Proxmox VE hypervisor with backing snapshots and backups handled natively at the hypervisor layer. This bypasses in-cluster network storage overhead entirely, providing local-SSD-grade performance.

---

## 2. Tier 2 — Tuning mismatches

### 2.1 `effective_cache_size` is overstated (MEDIUM)
**File:** `gitops/apps/taskflow/postgres-db.yaml`

```yaml
effective_cache_size=1152MB   # but container memory limit is only 1024Mi
```

`effective_cache_size` is a **planner hint** for how much of the data set is cached by the OS. The container is capped at 1024 MiB; Postgres RSS is ~384 (shared_buffers) + ~300 (30 backends × ~10 MiB) ≈ 800–900 MiB, leaving only **~300 MiB** of real OS page cache. Setting the hint to 1152 MiB (~2×+ reality) makes index scans look artificially cheap → the planner can pick suboptimal plans (wrong join/scan choices) under load.

**Fix:** Set `effective_cache_size=700MB` to match the realistic cache, or raise the container memory limit and set it proportionally.

> **Resolved:** `effective_cache_size` is now `700MB` in both the manifest and `README.md` (the prior drift — README said `768MB`, manifest said `1152MB` — has been corrected).

### 2.2 Backend is "Burstable" QoS → CPU throttling under load (MEDIUM)
**File:** `gitops/apps/taskflow/backend.yaml`

`requests.cpu=1000m` but `limits.cpu=4000m` → **Burstable** QoS. Under node CPU pressure the pod can be throttled below its 4-core ceiling, and on a shared node a latency-sensitive API can stall. For a single, latency-sensitive service it's usually better to run **Guaranteed** QoS (`requests == limits`) so it never gets squeezed and never throttles below its reservation.

**Fix:** Set `requests.cpu == limits.cpu` (e.g. both `2000m`) when you resize memory per §1.1.

### 2.3 Redis is ephemeral → cold-cache stampede on restart (MEDIUM)
**File:** `gitops/apps/taskflow/redis.yaml`

`/data` is an `emptyDir` with a clear comment that persistence is intentionally off. That's a legitimate L2-cache choice, **but** on every Redis pod restart (or the node rebooting) the entire cache is lost and the backend falls back to PostgreSQL — a cache stampede that can spike DB latency/CPU until the cache warms. With a single replica there's no warm standby.

**Fix:** Accept it (documented tradeoff) **or** back Redis with a small Proxmox CSI PVC + `appendonly yes` so restartswarm doesn't start fully cold. At minimum, ensure the backend degrades gracefully (it presumably does, since Redis is "L2").

### 2.4 Default connection pool vs `max_connections=30` (LOW-MEDIUM)
**File:** `gitops/apps/taskflow/postgres-db.yaml` (`max_connections=30`)

Spring Boot's default HikariCP `maximumPoolSize` is 10. With one backend that's fine (10 of 30). But if the backend scales to 3+ replicas, `3 × 10 = 30` exhausts `max_connections` with zero headroom for `psql`/migrations/admin. 

**Fix:** Either raise `max_connections` to ~50–100 (cheap at this RAM) or explicitly set `spring.datasource.hikari.maximum-pool-size` lower (e.g. 8) and size it against expected replicas.

---

## 3. Tier 3 — Minor / nice-to-have

| # | Item | Where | Note |
|---|------|-------|------|
| 3.1 | `synchronous_commit` tuning | `postgres-db.yaml` | ✅ Applied: `synchronous_commit=off` (no replicas → no durability cost, 5–20× write gain). |
| 3.2 | gzip / `Cache-Control` on nginx | `frontend` repo `nginx.conf` | ✅ Already done in the app repo: `gzip on; comp_level 6`, `Cache-Control "public"` + `expires 6M` on static assets. |
| 3.3 | HTTP/2 | `backend.yaml` Service + `gateway` | ✅ Backend `server.http2.enabled=true` (app repo) + `appProtocol: kubernetes.io/h2c` on the backend Service so Cilium Gateway multiplexes to the backend. |
| 3.4 | JVM GC logging / `-XX:MaxGCPauseMillis` | `backend.yaml` | ✅ Applied: rotated `-Xlog:gc*` + `MaxGCPauseMillis=100`. |
| 3.5 | Single replica / autoscaling | `backend.yaml` + `backend-hpa.yaml` | ✅ HPA added (CPU 70%, 1–3 replicas). Needs metrics-server for the `metrics.k8s.io` API (not in the VM stack) — see `backend-hpa.yaml` note. PDBs added for backend + frontend. |
| 3.6 | `random_page_cost=1.1` assumes SSD | `postgres-db.yaml` | Reasonable for Proxmox-CSI-backed-SSD; re-check if you move DB to spinning disk. |

---

## 4. Status of recommended actions

| # | Action | Status |
|---|--------|--------|
| 1 | **Monitoring stack** (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) | ✅ Deployed and collecting metrics |
| 2 | **Backend `/actuator/prometheus`** — `micrometer-registry-prometheus` + exposure + SecurityConfig permit | ✅ Already done in the app repo (see §below) |
| 3 | **JVM sizing** — single source of truth via `MaxRAMPercentage=50.0` (image), Guaranteed QoS `2Gi` | ✅ Applied — `backend.yaml` JAVA_TOOL_OPTIONS no longer overrides heap/direct; image owns sizing |
| 4 | **`effective_cache_size`** corrected to 700MB | ✅ Applied in `postgres-db.yaml` |
| 5 | **Postgres PVC** migrated from Longhorn to Proxmox CSI | ✅ Applied in `postgres-pvc.yaml` |
| 6 | **Harden Redis** — add persistence PVC or document stampede risk | ⏳ Pending (see §2.3) — still ephemeral by design |
| 7 | **Re-evaluate pool sizes** when adding a second backend replica | ✅ `max_connections` raised 30→50 in `postgres-db.yaml`; HPA caps at 3 replicas (25×3=75 > 50, so scale past 2 only with another `max_connections` bump) |
| 8 | **Redis / Jaeger QoS** — Guaranteed (requests==limits) | ✅ Applied in `redis.yaml` / `jaeger.yaml` |
| 9 | **Backend startup probe** tightened 20→15 failures | ✅ Applied in `backend.yaml` |
| 10 | **Scrape intervals** relaxed to 60s for postgres/redis exporters | ✅ Applied in `vmservicescrapes.yaml` |
| 11 | **Flux image-poll interval** 5m→10m | ✅ Applied in `image-automation.yaml` |

### Note on item 2 (backend metrics) — already implemented in the app repo
The app repo (`taskflow` / `msx`) already ships everything PERFORMANCE.md originally
flagged as "pending":
- `build.gradle`: `io.micrometer:micrometer-registry-prometheus` ✅
- `application-prod.properties`: `management.endpoints.web.exposure.include=health,info,prometheus` + `prometheus.enabled=true` ✅
- `SecurityConfig.java`: `.requestMatchers("/actuator/health/**", "/actuator/prometheus").permitAll()` ✅
- `application.properties`: `server.http2.enabled=true` ✅

So the VMServiceScrape in `gitops/monitoring/app` is **live**, not inert.

### Note on item 3 (JVM sizing) — resolution of the TF-vs-image conflict
The previous config had a **silent bug**: `backend.yaml` set `-Xmx1024m` + `-XX:MaxDirectMemorySize=512m`
in `JAVA_TOOL_OPTIONS`, while the Dockerfile set `MaxRAMPercentage=75.0` + `MaxDirectMemorySize=256m`.
Because Dockerfile CMD args win over `JAVA_TOOL_OPTIONS` (JVM "last-wins"), the in-cluster reality was:
heap = 1GiB (env only source), `MaxDirectMemorySize = 256m` (image won) — so the "512Mi direct"
comment was wrong, and `MaxRAMPercentage` was dead (ignored when `-Xmx` is set).

Resolution (Option 1, best-practice): the **image owns JVM sizing** via `MaxRAMPercentage=50.0`
(changed from 75.0 — 75% would give 1.5GiB heap at the 2Gi limit and OOMKilled the pod given
Netty/Lettuce direct buffers + ~200 thread stacks). The TF `JAVA_TOOL_OPTIONS` keeps only GC
logging/caps and no longer sets heap or direct memory. See `BACKEND_INTEGRATION_CONTEXT.md` §0/§4
for the corrected contract.

---

## 5. Quick "before/after" for the highest-impact change (§1.1 / §item 3)

```yaml
# backend.yaml — JAVA_TOOL_OPTIONS (deployment only adds GC/logging; heap owned by image)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
      -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/dump.hprof
# Image (Dockerfile) owns heap: -XX:MaxRAMPercentage=50.0  → 1GiB heap at the 2Gi limit
resources:
  requests: { cpu: "2000m", memory: "2Gi" }   # Guaranteed QoS
  limits:   { cpu: "2000m", memory: "2Gi" }
```

This removes the rigid heap, fixes the silent direct-memory override, and bounds native memory
so `ExitOnOutOfMemoryError` only triggers on a real leak, not a benign spike.


---

## 5. Quick "before/after" for the highest-impact change (§1.1)

```yaml
# backend.yaml — container section (proposed)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -Xms1024m -Xmx1024m
      -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=512m
resources:
  requests: { cpu: "2000m", memory: "2Gi" }   # Guaranteed QoS
  limits:   { cpu: "2000m", memory: "2Gi" }
```

This removes the 512 MiB off-heap trap, stops CPU throttling, and bounds native memory so `ExitOnOutOfMemoryError` only triggers on a real leak, not a benign spike.
