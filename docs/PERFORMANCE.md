# TaskFlow — Resource Sizing and Tuning

The current sizing and tuning decisions for the workloads, and the evidence behind them.
The values themselves live in the manifests (with comments); this document records why
they are what they are, so a later change can be checked against the reasoning. Node and
Proxmox host tuning is in [`NODE_HOST_TUNING.md`](NODE_HOST_TUNING.md); open performance
items are in [`BACKLOG.md`](BACKLOG.md).

---

## 1. Backend JVM (`gitops/apps/taskflow/backend.yaml`)

```yaml
# backend.yaml — sizing and GC/logging owned by the deployment (excerpt)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:ActiveProcessorCount=2 -XX:MaxRAMPercentage=50.0 -XX:InitialRAMPercentage=50.0
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/var/log/taskflow/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
      -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/log/taskflow
resources:
  requests: { cpu: "500m", memory: "1536Mi" }
  limits:   { memory: "2Gi" }   # Burstable; deliberately no CPU limit
```

- **The deployment owns JVM sizing.** The image must not add competing sizing flags: an
  earlier image's `MaxRAMPercentage`/`MaxDirectMemorySize` silently overrode the deployment's
  values. Contract: `BACKEND_INTEGRATION_CONTEXT.md`.
- **50 % heap** (1 GiB at the 2 GiB limit). 75 % would leave too little for Netty/Lettuce
  direct buffers, metaspace and ~200 thread stacks and risk a cgroup OOM kill. Direct memory
  and metaspace are capped; other native allocations are not, so an OOM is still possible
  under real load.
- **No CPU limit** (see §2.2); `ActiveProcessorCount=2` keeps GC and pool sizing stable.

---

## 2. Data tier and CPU

### 2.1 PostgreSQL memory and `effective_cache_size`

`shared_buffers=128MB` already holds the whole dataset (~17 MB; the container peaked at
102Mi over 14 days, 2026-10-22). The 768Mi limit covers `shared_buffers` + `wal_buffers` +
three autovacuum workers at `autovacuum_work_mem=32MB` + 25 pooled connections × `work_mem`
+ `/dev/shm`. `effective_cache_size=384MB` is a planner hint for shared buffers plus OS page
cache, and inside the cap that is ~128 + ~256 MB; overstating it (it was once 1152MB in a
1 GiB container) makes index scans look artificially cheap. Raise `shared_buffers` and the
limit together if the data approaches ~100 MB.

### 2.2 No CPU limits on long-running services

The backend, Postgres, Redis and the other services request CPU but have no CPU limit: a CFS
quota throttles bursts (JVM start-up, GC, checkpoints, autovacuum) even on an idle node, while
the request already guarantees the share under contention. Burstable QoS does not throttle; a
CPU limit does. Rationale and measurements: `reports/PERF_DEEP_DIVE_2026-10.md` §3.

### 2.3 Redis is ephemeral (accepted)

`/data` is an `emptyDir`, and RDB and AOF are explicitly off (`--save ""`, `--appendonly no`),
so there are no fork/bgsave memory spikes. A Redis restart therefore starts with a cold cache
and the backend falls back to PostgreSQL until it warms. If that ever shows up in the
PostgreSQL metrics, back Redis with a small Proxmox CSI PVC and `appendonly yes`.

### 2.4 `max_connections=80`

The backend's HikariCP pool is fixed at 25 (`minimum-idle = maximum-pool-size`). During a
`RollingUpdate` (`maxSurge: 1, maxUnavailable: 0`) the surge pod opens 25 connections while the
old pod still holds 25 through its `preStop` drain, plus 2 for `postgres-exporter`: 52 > the
old 50, which logged `FATAL: sorry, too many clients already`. 80 leaves room for that,
Flyway migrations and an admin `psql`. Revisit the pool if the backend ever runs more than one
replica.

### 2.5 PostgreSQL storage

`postgres-data` is a 10Gi PVC on `proxmox-csi-db` (`cache: none`, `noatime`), on the host's
local SSD rather than network storage. The previous `proxmox-csi` (`cache: writethrough`) PV
is `Retain`, so its Proxmox disk stays until it is deleted by hand. Proxmox CSI attaches PV
disks with `backup=0`: VM backups exclude this data (backups are REL-02 in the backlog).

---

## 3. Smaller decisions

| # | Item | Where | Decision |
|---|------|-------|----------|
| 3.1 | `synchronous_commit=on` | `postgres-db.yaml` | A commit is acknowledged after its WAL is flushed (REL-04). `off` would trade up to ~600 ms of acknowledged bookings for lower commit latency; measure first (`reports/PERF_DEEP_DIVE_2026-10.md` §5.4). |
| 3.2 | Compression and `Cache-Control` | frontend repo `nginx.conf` | Brotli and gzip (precompressed sidecars served statically), `Cache-Control: public, immutable, max-age=15552000` on hashed bundles, `no-cache` on HTML. Cloudflare caches the bundles (`cf-cache-status: HIT`, checked 2026-10-30); Smart Tiered Cache would remove the first per-location fetch (NET-01). |
| 3.3 | HTTP/2 to the backend | `backend.yaml` Service, `backend-waf.yaml` | The backend enables HTTP/2 and its Service declares `appProtocol: kubernetes.io/h2c`, but no hop uses it: the Gateway routes to the WAFs (`gatewayAPI.enableAppProtocol` off) and the backend WAF pins its upstream to HTTP/1.1. Intentional (`reports/NETWORK_REVIEW_2026-10.md` §2.7). |
| 3.4 | GC logging, `MaxGCPauseMillis=100` | `backend.yaml` | Rotated `-Xlog:gc*` to `/var/log/taskflow`. |
| 3.5 | Single backend replica | `backend.yaml` | Local SSE state and the connection budget are not multi-replica safe; PDBs keep drains from deadlocking. |
| 3.6 | `random_page_cost=1.1` | `postgres-db.yaml` | Assumes SSD; revisit if the database moves to spinning disk. |

---

## 4. Monitoring stack

- **No duplicate scrapes:** the stack's own CoreDNS scrape is off (`coreDns.enabled: false`;
  the custom `coredns` VMServiceScrape covers the pods), and the `loki` VMServiceScrape skips
  the chart's headless Service.
- **Cardinality:** `monitoring/platform/release.yaml` drops ~81k duplicate control-plane
  series from the kubelet scrape, `kubelet_.+` from the apiserver scrape and ~58k unused API
  server histogram buckets (PERF-12).
- **Scrape intervals:** the vmagent default is 30s (the chart's 20s applied only to the bundled
  jobs that set none); the Grafana datasource sets `timeInterval: 30s`; the Postgres and Redis
  exporters scrape every 60s.
- **No CPU limits** on Loki and VMSingle, so split Loki queries run in parallel and VMSingle
  merges are never throttled; memory limits protect the node.
- **Loki:** monolithic, no nginx gateway (clients use the Service on 3100), no rules sidecar,
  an in-process 100 MB results cache, and ingestion limits of 8 MB/s with a 16 MB burst (the
  4/6 MB default made the 15 MB per-stream burst unreachable).
- **Dashboards read Alloy-derived counters** for the WAF and Rate Limits overviews instead of
  scanning Loki: data read per open at 6h fell from 949 to 89 MB and from 2,108 to 516 MB.
- **Kyverno** runs only the admission and reports controllers (PERF-11).
- **Not changed on purpose:** Grafana 13.3's recurring `search-manifest-watcher` warning comes
  from optional app-manifest discovery, not from dashboard provisioning; do not enable the
  experimental `appplugins.loadAppManifest` or change storage/search modes to silence it.
  Flux controllers keep their 1-CPU limits: throttling measured on 2026-11-03 was a fraction
  of a second per 30 minutes with no reconcile backlog.

---

## 5. Memory requests (measured 2026-11-03)

Requests were set from 14 days of VictoriaMetrics data; limits and JVM/Go memory budgets were
not changed.

| Workload | Request | Evidence |
|---|---|---|
| Backend | 1536Mi (was 2048Mi) | Working-set peak ~588Mi; summed JVM heap peak ~221Mi; cgroup peak since start ~938Mi |
| Grafana | 384Mi (was 256Mi) | Working-set peak ~489Mi on 13.3; limit 1Gi with `goMemLimit.factor: 0.8` |
| VMSingle | 768Mi (was 512Mi) | p95 ~791Mi; peak ~897Mi |
| Cilium agent | 384Mi (was 256Mi) | p95 ~428Mi; peak ~548Mi |
| Trivy operator | 320Mi (was 256Mi) | p95 ~270Mi; peak ~350Mi |
| Kyverno admission | 192Mi (was 256Mi) | Peak ~163Mi |
| Frontend | 32Mi (was 128Mi) | Peak ~11Mi |

Query (substitute namespace and container):

```promql
max(max_over_time(container_memory_working_set_bytes{namespace="taskflow",container="backend"}[14d])) / 1048576
```

For JVM heap, sum the pools per pod before taking the maximum:

```promql
max(max_over_time((sum by (pod) (
  max by (pod, id) (jvm_memory_used_bytes{namespace="taskflow",area="heap"})
))[14d:30s])) / 1048576
```

Limits of this evidence: the window had telemetry gaps around 2026-10-30 to 11-01 and very
light traffic (~0.15 requests/s), sampled metrics miss short spikes, and working set is not
total cgroup memory. Re-measure before lowering a limit.
