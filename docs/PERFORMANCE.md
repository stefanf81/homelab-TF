# TaskFlow — Performance Analysis

> **Scope note:** The cluster was unreachable during this review (`kubeconfig` → connection refused), so this is **static analysis** of the manifests + reasoning about runtime behavior. Several findings (especially the JVM off-heap and PostgreSQL planner behavior) are *likelihood* assessments that should be confirmed with real metrics. The single biggest gap (see #1) is that **there are no metrics at all**, so today you cannot actually measure any of this.

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

### 1.2 No observability → you are tuning blind (HIGH)
**Files:** whole repo (nothing for metrics)

There is Jaeger for **traces** but **no Prometheus, no node-exporter, no kube-state-metrics, no Grafana, no Spring Boot Actuator Prometheus endpoint wired**. You cannot see CPU saturation, GC pause times, heap/off-heap usage, DB query latency, cache hit rate, or disk I/O. Every other item below is a guess until this exists.

**Fix:** Add (at minimum) `kube-prometheus-stack` (or Prometheus Operator) via a Flux HelmRelease, enable the Spring Boot Actuator `/actuator/prometheus` endpoint on the backend, and scrape it. This is the prerequisite for confirming 1.1, 2.1, 2.2.

### 1.3 PostgreSQL runs on Longhorn (network storage) (MEDIUM-HIGH)
**File:** `gitops/apps/taskflow/postgres-pvc.yaml` (`storageClassName: longhorn`)

PostgreSQL is the most I/O-sensitive workload in the stack, yet it sits on Longhorn — which, even single-replica on the same node, routes every read/write through the Longhorn engine process (and its replica sync) rather than straight to the local block device. Expect measurable write-latency and fsync overhead vs. a local disk. On a homelab this is usually acceptable, but it's the first thing to move if the DB feels slow.

**Fix:** Create a `local` StorageClass (Longhorn `storageClass: local` / `retain`, or a `local-storage` hostPath/LV) and pin the Postgres PVC to it. Keep Longhorn for everything else.

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

**Fix:** Accept it (documented tradeoff) **or** back Redis with a small Longhorn PVC + `appendonly yes` so restartswarm doesn't start fully cold. At minimum, ensure the backend degrades gracefully (it presumably does, since Redis is "L2").

### 2.4 Default connection pool vs `max_connections=30` (LOW-MEDIUM)
**File:** `gitops/apps/taskflow/postgres-db.yaml` (`max_connections=30`)

Spring Boot's default HikariCP `maximumPoolSize` is 10. With one backend that's fine (10 of 30). But if the backend scales to 3+ replicas, `3 × 10 = 30` exhausts `max_connections` with zero headroom for `psql`/migrations/admin. 

**Fix:** Either raise `max_connections` to ~50–100 (cheap at this RAM) or explicitly set `spring.datasource.hikari.maximum-pool-size` lower (e.g. 8) and size it against expected replicas.

---

## 3. Tier 3 — Minor / nice-to-have

| # | Item | Where | Note |
|---|------|-------|------|
| 3.1 | No `wal_compression` / `synchronous_commit` tuning | `postgres-db.yaml` | Enabling `wal_compression=on` reduces WAL I/O on the network-backed volume. |
| 3.2 | No gzip / `Cache-Control` on nginx | `frontend.yaml` (nginx image) | Angular bundles should be gzipped + immutable-cache headers; otherwise first load is slower. (Can't see the Dockerfile from this repo — verify the prod build + nginx config there.) |
| 3.3 | No HTTP/2 at the Gateway | `gateway.yaml` | Cilium Gateway supports it; enables multiplexing for the `/api` calls. |
| 3.4 | JVM lacks GC logging / `-XX:MaxGCPauseMillis` | `backend.yaml` | Add `-Xlog:gc*:time` + a pause target once metrics exist, to tune G1. |
| 3.5 | Single replica everywhere | all Deployments | No horizontal headroom; CPU/mem are hard-capped per pod. Add HPA for the backend once metrics exist. |
| 3.6 | `random_page_cost=1.1` assumes SSD | `postgres-db.yaml` | Reasonable for Longhorn-on-SSD; re-check if you move DB to spinning disk. |

---

## 4. Recommended order of operations

1. **Add Prometheus/Grafana + Actuator Prometheus** (unblocks measuring everything else).
2. **Fix the JVM off-heap** (§1.1): run as Guaranteed QoS `requests==limits=2Gi` with a 1 GiB heap, add `-XX:MaxMetaspaceSize` / `-XX:MaxDirectMemorySize`. (Applied; later trimmed from 3Gi/1.5GiB heap to free ~1 GiB on the node.)
3. **Correct `effective_cache_size`** to ~700 MB (§2.1) and fix the README drift.
4. **Move Postgres PVC to a local StorageClass** (§1.3) if DB latency is noticeable.
5. **Harden Redis** (§2.3) or document the stampede risk prominently.
6. Re-evaluate pool sizes (§2.4) when you add a second backend replica.

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
