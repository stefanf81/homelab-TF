# TaskFlow — Performance Analysis

> **Scope note:** The initial review was static analysis (cluster unreachable). The monitoring stack (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) is deployed, and the backend plus GitOps configuration now expose its existing Micrometer Prometheus registry for in-cluster scraping. JVM, HTTP, Hikari, PostgreSQL, Redis, node, and disk metrics are configured for the TaskFlow Performance Grafana dashboard after the normal application deployment.

---

## 1. Tier 1 — Likely real problems (fix first)

### 1.1 JVM off-heap memory is unbounded → OOM-restart risk (HIGH) — ✅ RESOLVED

> **Resolved:** The backend uses deployment-supplied `JAVA_TOOL_OPTIONS` with `MaxRAMPercentage=50.0` for a 1 GiB heap at the unchanged 2 GiB limit, plus `MaxDirectMemorySize=256m` and `MaxMetaspaceSize=256m`. The configured memory request is 1536Mi. QoS is **Burstable**, not Guaranteed: CPU has a 500m request and no limit. See `BACKEND_INTEGRATION_CONTEXT.md` for the full contract.

**Previous config (for reference):**
```
-Xms1536m -Xmx1536m ... -XX:+ExitOnOutOfMemoryError
resources:
  requests: cpu 1000m, memory 2048Mi
  limits:   cpu 4000m, memory 2560Mi
```

**Current config** (`backend.yaml` + image Dockerfile):
```yaml
# backend.yaml — sizing and GC/logging owned by the deployment (excerpt)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:ActiveProcessorCount=2 -XX:MaxRAMPercentage=50.0
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/var/log/taskflow/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
resources:
  requests: { cpu: "500m", memory: "1536Mi" }
  limits:   { memory: "2Gi" }   # Burstable; deliberately no CPU limit
```
The deployment owns heap sizing via `JAVA_TOOL_OPTIONS` and
`-XX:MaxRAMPercentage=50.0` → 1 GiB heap at the 2 GiB limit.

#### Memory request review (2026-11-03)

This change adjusts scheduling reservations only; it does not lower actual memory use.
All container memory limits and JVM/Go memory budgets remain unchanged.

| Workload | Memory request before → configured | Evidence from available samples |
|---|---|---|
| Backend | 2048Mi → 1536Mi | Working-set peak ~588Mi; summed JVM heap peak ~221Mi; current container cgroup peak ~938Mi |
| Grafana | 256Mi → 384Mi | Current 13.3.0 image working-set peak ~489Mi; ~1000Mi peak belongs to 13.2.4 |
| VMSingle | 512Mi → 768Mi | Recent p95 ~791Mi; working-set peak ~897Mi |
| Cilium agent | 256Mi → 384Mi | Recent p95 ~428Mi; working-set peak ~548Mi |
| Trivy operator | 256Mi → 320Mi | Recent p95 ~270Mi; working-set peak ~350Mi |
| Kyverno admission | 256Mi → 192Mi | Working-set peak ~163Mi |
| Frontend | 128Mi → 32Mi | Working-set peak ~11Mi |

Net for the current replica counts: **96Mi less requested memory**, no change to limits.
The backend retains its 2Gi limit/1Gi heap, and Grafana retains its 1Gi limit and
`goMemLimit.factor: 0.8` (~819MiB soft budget).

**Method and limits of the evidence:** query `max(max_over_time(container_memory_working_set_bytes{namespace="taskflow",container="backend"}[14d])) / 1048576`
(substitute namespace/container for other workloads). Aggregate across every matching
series rather than overwriting series with duplicate pod/container keys. For JVM heap,
sum the pools per pod before taking the time maximum:

```promql
max(max_over_time((sum by (pod) (
  max by (pod, id) (jvm_memory_used_bytes{namespace="taskflow",area="heap"})
))[14d:30s])) / 1048576
```

The earlier 148Mi figure was the largest individual heap pool, not total heap.
The 14-day window has substantial telemetry gaps around October 30–November 1;
available non-actuator traffic peaked at only ~0.15 requests/second over five minutes.
These observations do not establish safety for smaller limits under load. Working set
is not total cgroup memory; the ~938Mi backend cgroup peak is since container start,
not a 14-day measurement. Sampled metrics can miss short spikes.

Direct backend startup/GC logs showed normal operation. The frontend's previous
failure was DNS resolution (`host not found in upstream`), not memory. No OOM
indicators were found for these seven workloads in the available telemetry, but
absence is not proof: backend/frontend logs were missing from Loki because Alloy's
label selectors did not match their pod labels. That logging issue is not fixed by
this memory change. Schema validation also cannot establish runtime memory safety.

### 1.2 ~~No observability → you are tuning blind~~ (RESOLVED)
**Files:** `gitops/monitoring/platform/release.yaml` (VictoriaMetrics stack), `gitops/monitoring/app/vmservicescrapes.yaml` (app scrapes)

> **Resolved:** The monitoring stack is deployed and collecting cluster-wide metrics:
> - **VictoriaMetrics** (VMSingle + vmagent) — replaces Prometheus, ~⅓ the RAM
> - **Grafana** — dashboards queryable at `https://grafana.jokelab.dev`
> - **kube-state-metrics** — pod/Deployment/replica/namespace resource metrics
> - **node-exporter** — host-level CPU/memory/disk/network per node
> - **PostgreSQL exporter** — DB query latency, active connections, cache hit ratio
> - **Redis exporter** — cache hit rate, memory usage, evictions
> - **Falco** — runtime security event metrics
> - **Spring Boot Actuator + Micrometer** — JVM, HTTP latency, and Hikari connection-pool metrics from `/actuator/prometheus`; the endpoint is reachable without application credentials only from the monitoring namespace.
>
> The backend Service and VMServiceScrape use the same named `http` port, so discovery does not depend on an unnamed numeric Service port.

#### Monitoring stack tuning (October 2026)

- **No duplicate scrapes:** the stack's own CoreDNS scrape is disabled (`coreDns.enabled: false`; the custom `coredns` VMServiceScrape selects the same pods), and the `loki` VMServiceScrape skips the chart's headless Service. Both previously ingested every series twice.
- **CPU limits:** Loki and VMSingle limits raised from 500m to 1 CPU so split Loki queries run in parallel and VMSingle merges are not throttled; memory limits (768Mi / 1Gi) stay the protective limit.
- **Loki:** in-process results cache (100 MB, no memcached pod); a repeated range query went from 4.4 s to 0.009 s in the lab. Tenant ingestion set explicitly to 8 MB/s with a 16 MB burst (the 4/6 MB default made the 15 MB per-stream burst unreachable).
- **Grafana:** the VictoriaMetrics datasource sets `timeInterval: 30s` to match the scrape interval.
- **Dashboards:** the WAF and Rate Limits overviews read Alloy-derived counters instead of scanning Loki: log data read per dashboard open at 6h fell from 949 to 89 MB (WAF) and 2,108 to 516 MB (Rate Limits).
- **Open:** drop unused high-cardinality series (API server histograms, unused cAdvisor metrics) after checking the VMUI cardinality explorer.

#### Grafana manifest warnings and Flux throttling review (2026-11-03)

**Grafana 13.3.0:** the recurring `search-manifest-watcher` warning is from its
in-process discovery of optional app/plugin manifests, not dashboard ConfigMap
provisioning. At inspection the watcher reported 42 **empty** polls, zero reloads,
zero manifests and a current successful-poll timestamp. Grafana health reported the
database OK, and Bleve logs showed indexes being built/cached successfully.

The pinned source starts `NewLocalManifestWatcher` for in-process search and retries
an empty discovery list, logging two warnings per cycle. Built-in manifests are
compiled into the binary separately; an empty live set does not mean zero dashboards.
The optional `appplugins.loadAppManifest` toggle is experimental and defaults to
false. Do **not** enable it or change storage/search modes merely to silence this
warning. No Grafana settings or logger filters are changed by this investigation.
Recheck if watcher **error** counters appear, indexes fail, or dashboard search fails.

Source inspected at tag v13.3.0:
[`client.go`](https://github.com/grafana/grafana/blob/v13.3.0/pkg/storage/unified/client.go),
[`manifest_watcher.go`](https://github.com/grafana/grafana/blob/v13.3.0/pkg/storage/unified/resource/manifest_watcher.go),
[`app_manifests.go`](https://github.com/grafana/grafana/blob/v13.3.0/pkg/storage/unified/resource/app_manifests.go).

**Flux:** retain the current 1-CPU controller limits. Around 11:58 UTC, the latest
five-minute throttled-time increases were ~0.106s for helm-controller and 0s for
kustomize-controller; the preceding 30-minute increases were ~1.12s and ~3.53s.
Another five-minute check around 12:04 showed 0s and ~0.10s respectively. Five-minute
average CPU use was ~3m and ~0.7m. Throttled-period percentages exaggerate the impact
of these short bursts and are not a percentage of total wall time lost.

All Kustomizations were Ready; latest non-rollout reconciliation durations were
typically ~0.2–1.8s. `monitoring-logging` took ~25.3s including the gateway rollout.
No sustained backlog/latency symptom justifies relaxing CPU limits here. Flux-specific
`gotk_*` duration metrics were not present in VictoriaMetrics, so these duration
observations come from Kustomization status history, not a measured latency p99.

#### Configuration review (2026-11-11)

Static review: the pinned charts were rendered with this repository's values
(`helm template`) and compared before and after. Nothing was measured on the cluster.

| Change | Where | Why |
|---|---|---|
| vmagent default scrape interval 20s → 30s | `monitoring/platform/release.yaml` | Five bundled scrapes (kube-state-metrics, node-exporter, kube-apiserver, Grafana, the VM operator) set no interval and inherited the chart's 20s, while kubelet/cAdvisor, every custom scrape and the Grafana datasource use 30s or 60s. A third fewer samples from those jobs |
| Loki rules sidecar off | `monitoring/logging/loki-release.yaml` | No `loki_rule` ConfigMap or Secret exists. Removes a Python sidecar (128Mi requested, ~97Mi peak) and the cluster-wide ConfigMap/Secret read it needed |
| Kyverno background and cleanup controllers off | `infrastructure/controllers/kyverno/release.yaml` | Only `ValidatingPolicy` objects exist; the reports controller does the background scans (PERF-11). Two pods, 256Mi of requests and two Leases less |
| `GOMEMLIMIT` on both WAFs (690MiB / 460MiB) | `apps/taskflow/*-waf.yaml` | Go's GC does not see the cgroup limit (PERF-06) |
| Redis and Jaeger probe timeouts 1s → 3s | `apps/taskflow/redis.yaml`, `jaeger.yaml` | The only probes still on the 1s default; a liveness restart of Redis empties the cache (§2.3, PERF-05) |
| Loki nginx gateway removed | `monitoring/logging/loki-release.yaml`, the three clients and two network policies below | In monolithic mode it forwarded every path to the one Loki Service (PERF-10). One pod (nginx + exporter) and one proxy hop per push and query less; no nginx that fails to start while DNS is down |

Requests freed: 432Mi memory and 75m CPU.

The gateway removal moves three clients and two policies to
`http://loki.monitoring.svc.cluster.local:3100` in one commit: Alloy's `loki.write`
(`alloy-release.yaml`), the Grafana datasource (`loki-datasource.yaml`), `abuseipdb-sync`'s
`LOKI_PUSH_URL` (`platform/abuseipdb/config.yaml`), and port 3100 on the single-binary pod in
`allow-abuseipdb-sync-to-loki` (`monitoring/platform/network-policies.yaml`) and
`abuseipdb-sync-egress` (`platform/abuseipdb/network-policy.yaml`).
`tests/validate-startup-scope.rb` compares all five with the rendered chart, and the Alloy
pipeline tests ran against a disposable Loki without a gateway. The Cilium policies themselves
can only be confirmed on the cluster (checks below). The default URL compiled into
`abuseipdb-sync` names the Loki Service from image `0.3.3-r1` (`config.go`); images up to
`0.3.2-r2` default to the removed gateway, so keep `LOKI_PUSH_URL` set while one is pinned.

Check after Flux applies it:

```bash
kubectl -n monitoring get pod loki-0 -o jsonpath='{.spec.containers[*].name}{"\n"}'
```

```bash
kubectl -n kyverno get pods
```

```bash
kubectl get validatingwebhookconfigurations | grep -E 'kyverno-(cleanup|ttl)'
```

The first prints `loki` only and the second lists the admission and reports controllers. The
third should print nothing; delete any configuration it still lists
(`KYVERNO_POLICY_ENGINE.md` §4). In Grafana Explore,
`count_over_time(up{job="kube-state-metrics"}[5m])` drops from ~15 to ~10.

For the gateway removal:

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
```

```bash
kubectl -n abuseipdb logs deploy/abuseipdb-sync --since=15m | grep -i loki
```

The first lists `loki-0` only. The second should show no push errors after the pod's
restart. The collector polls every 5 minutes and pushes only when Cloudflare blocked
something in that window; a failed push is retried by the next poll with the same
window (up to 24h back), so a short gap during the rollout loses nothing. In Grafana Explore
`increase(cloudflare_firewall_collector_errors_total{reason="loki"}[30m])` stays 0, any
Loki dashboard shows lines newer than the rollout, and
`rate(loki_write_sent_bytes_total[5m])` (Alloy) is above 0. If the `abuseipdb-sync` push
times out, the two policies and the pod labels do not agree: compare
`kubectl -n monitoring get pod loki-0 --show-labels` with both policies.

**PostgreSQL volume → `proxmox-csi-db`** (`cache: none`, `noatime`; was `proxmox-csi`,
`cache: writethrough`). A PVC's class cannot change, so `postgres-data` is a new PVC and the
`migrate-pgdata` init container in `postgres-db.yaml` copies the old volume into it once:
the Deployment is `Recreate`, so the old pod has stopped first; the old volume is mounted
read-only; the copy is renamed into place only when complete and its entry count matches.
Rehearsed with the pinned `postgres:18.6-alpine` image in Docker: clean stop, killed pod
(normal crash recovery on the copy), interrupted copy (redone) and an empty old volume
(initdb). `postgres-pvc` stays as the rollback copy; it receives no writes after the switch.

Before merging, check that the class exists (`kubectl get sc proxmox-csi-db`): if the new
PVC cannot be provisioned, Postgres stays down until the commit is reverted. Afterwards:

```bash
kubectl -n taskflow logs deploy/postgres-db -c migrate-pgdata
```

```bash
kubectl -n taskflow get pvc postgres-data postgres-pvc
```

The first prints `copied … entries`, the second shows both `Bound`. Rollback: revert the
commit (Postgres returns to `postgres-pvc`; writes made since the switch are lost).
Cleanup after a few days without problems: remove the init container, the
`postgres-storage-old` volume and the `postgres-pvc` object from Git; the PV is `Retain`, so
delete its Proxmox disk by hand once no longer wanted.

### 1.3 ~~PostgreSQL runs on Longhorn (network storage)~~ (RESOLVED)
**File:** `gitops/apps/taskflow/postgres-pvc.yaml` (`postgres-data`, `storageClassName: proxmox-csi-db` since 2026-11-11)

> **Resolved:** PostgreSQL has been migrated from Longhorn to native **Proxmox CSI** storage. Disk space is scaled to `10Gi` and volumes are dynamically provisioned on your Proxmox VE hypervisor with backing snapshots and backups handled natively at the hypervisor layer. This bypasses in-cluster network storage overhead entirely, providing local-SSD-grade performance.

---

## 2. Tier 2 — Tuning mismatches

### 2.1 `effective_cache_size` is overstated (MEDIUM) — ✅ RESOLVED

> **Resolved:** `effective_cache_size` is now `256MB` in `postgres-db.yaml` (lowered from `700MB` on 2026-10-22).

**Previous config (for reference):**
```yaml
effective_cache_size=1152MB   # but container memory limit is only 1024Mi
```

**Current config** (`postgres-db.yaml`):
```yaml
effective_cache_size=256MB    # matches realistic cache inside the 512Mi cap
```

> **2026-10-22:** container cut to 512 MiB and `shared_buffers` to 128 MB (database
> is ~17 MB), so the hint dropped from 700 MB to 256 MB. The history below explains
> the earlier 1152 MB → 700 MB correction.

The value was corrected because the container is capped at 1024 MiB; Postgres RSS is ~384 (shared_buffers) + ~300 (30 backends × ~10 MiB) ≈ 800–900 MiB, leaving only ~300 MiB of real OS page cache. The original 1152 MiB hint (~2×+ reality) made index scans look artificially cheap and could cause suboptimal plans under load.

### 2.2 Backend CPU quota throttling — ✅ RESOLVED

> **Resolved:** The backend deliberately has no CPU limit, so it can burst without a CFS quota. Its CPU request is 500m and QoS is Burstable. Burstable QoS itself does not cause CPU quota throttling; setting a CPU limit does. Memory usage above the request can increase eviction exposure under node memory pressure, and `taskflow-critical` priority does not guarantee immunity.

**Previous config:**
```yaml
requests: { cpu: "1000m" }
limits:   { cpu: "4000m" }    # Burstable QoS
```

**Current config** (`backend.yaml`):
```yaml
requests: { cpu: "500m", memory: "1536Mi" }
limits:   { memory: "2Gi" }   # Burstable; no CPU quota
```

### 2.3 Redis is ephemeral → cold-cache stampede on restart (MEDIUM)
**File:** `gitops/apps/taskflow/redis.yaml`

`/data` is an `emptyDir` with a clear comment that persistence is intentionally off. That's a legitimate L2-cache choice, **but** on every Redis pod restart (or the node rebooting) the entire cache is lost and the backend falls back to PostgreSQL — a cache stampede that can spike DB latency/CPU until the cache warms. With a single replica there's no warm standby.

**Fix:** Accept it (documented tradeoff) **or** back Redis with a small Proxmox CSI PVC + `appendonly yes` so restartswarm doesn't start fully cold. At minimum, ensure the backend degrades gracefully (it presumably does, since Redis is "L2").
### 2.4 Default connection pool vs `max_connections=50` (LOW-MEDIUM)

**File:** `gitops/apps/taskflow/postgres-db.yaml` (`max_connections=50`)

Spring Boot's default HikariCP `maximumPoolSize` is 10, while `postgres-db.yaml` budgets for a 25-connection pool. With one backend replica that's fine, but if the backend ever scales, each replica multiplies the pool and can exhaust `max_connections=50` with no headroom for `psql`/migrations/admin.

**Fix:** Pin `spring.datasource.hikari.maximum-pool-size` explicitly in the app (≤25 total across replicas) and keep `max_connections` sized from that number, or raise `max_connections` to ~50–100 (cheap at this RAM).

---

## 3. Tier 3 — Minor / nice-to-have

| # | Item | Where | Note |
|---|------|-------|------|
| 3.1 | `synchronous_commit` tuning | `postgres-db.yaml` | Set to `on` (REL-04): a commit is acknowledged after its WAL is flushed. `off` would trade up to ~600 ms of acknowledged writes for lower commit latency; measure first (`reports/PERF_DEEP_DIVE_2026-10.md` §5.4). |
| 3.2 | Compression / `Cache-Control` on nginx | `frontend` repo `nginx.conf` | ✅ Done in the app repo: Brotli and gzip (precompressed `.br`/`.gz` sidecars served statically, level 6 on the fly for the rest), `Cache-Control: public, immutable, max-age=15552000` on the hashed JS/CSS bundles, `no-cache` on the HTML shells. Cloudflare caches the bundles (`cf-cache-status: HIT` after the first request per data center, checked 2026-10-30); Smart Tiered Cache would also remove those first per-location fetches (`reports/NETWORK_REVIEW_2026-10.md` §2.6). |
| 3.3 | HTTP/2 | `backend.yaml` Service, `backend-waf.yaml` | Backend `server.http2.enabled=true` (app repo) and `appProtocol: kubernetes.io/h2c` on the backend Service, but no hop uses it: the Gateway routes to the WAFs (`gatewayAPI.enableAppProtocol` is off) and the backend WAF pins its upstream to HTTP/1.1. Intentional, see `reports/NETWORK_REVIEW_2026-10.md` §2.7. |
| 3.4 | JVM GC logging / `-XX:MaxGCPauseMillis` | `backend.yaml` | ✅ Applied: rotated `-Xlog:gc*` + `MaxGCPauseMillis=100`. |
| 3.5 | Single replica / autoscaling | `backend.yaml` | Backend is intentionally fixed at one replica. Local SSE state and the PostgreSQL connection budget must be redesigned before autoscaling is reintroduced. PDBs protect backend and frontend availability. |
| 3.6 | `random_page_cost=1.1` assumes SSD | `postgres-db.yaml` | Reasonable for Proxmox-CSI-backed-SSD; re-check if you move DB to spinning disk. |

---

## 4. Status of recommended actions

| # | Action | Status |
|---|--------|--------|
| 1 | **Monitoring stack** (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) | ✅ Deployed and collecting metrics |
| 2 | **Backend `/actuator/prometheus`** — Micrometer registry, exposure, SecurityConfig permit, and named VMServiceScrape port | ✅ Configured — the normal application and Flux deployment activates backend JVM, HTTP, and Hikari scrapes alongside existing PostgreSQL, Redis, node, and disk telemetry. |
| 3 | **JVM sizing** — single source of truth via `MaxRAMPercentage=50.0` (deployment), 2Gi limit / 1Gi heap, Burstable QoS | ✅ Configured — `backend.yaml` owns JVM sizing; memory request 1536Mi, with no CPU limit |
| 4 | **`effective_cache_size`** corrected to 700MB, then 256MB | ✅ Applied in `postgres-db.yaml` |
| 5 | **Postgres PVC** migrated from Longhorn to Proxmox CSI | ✅ Applied in `postgres-pvc.yaml` |
| 6 | **Harden Redis** — add persistence PVC or document stampede risk | ✅ Resolved (intentionally ephemeral) — RDB/AOF are now explicitly disabled (`--save ""`, `--appendonly no`) so no stray bgsave/fork memory spikes occur; stampede risk on restart is accepted (see §2.3) |
| 7 | **Re-evaluate pool sizes** when adding replicas | Backend autoscaling is disabled. Local SSE state and the Hikari pool require distributed event fan-out and connection-pool redesign before scaling. |
| 8 | **Redis / Jaeger QoS** — Guaranteed (requests==limits) | ⚠️ Redis and Jaeger use Burstable QoS (requests < limits). This is intentional: Redis is ephemeral and Jaeger is a dev tool. Guaranteed QoS is not required for either. |
| 9 | **Backend startup probe** tightened 20→15 failures | ✅ Applied in `backend.yaml` |
| 10 | **Scrape intervals** relaxed to 60s for postgres/redis exporters | ✅ Applied in `vmservicescrapes.yaml` |
| 11 | **Flux image-poll interval** 5m→10m | ✅ Applied in `image-automation/*-repository.yaml` |
### Note on item 3 (JVM sizing) — resolution of the TF-vs-image conflict
The previous config had a **silent bug**: `backend.yaml` set `-Xmx1024m` + `-XX:MaxDirectMemorySize=512m`
in `JAVA_TOOL_OPTIONS`, while the Dockerfile set `MaxRAMPercentage=75.0` + `MaxDirectMemorySize=256m`.
Because Dockerfile CMD args win over `JAVA_TOOL_OPTIONS` (JVM "last-wins"), the in-cluster reality was:
heap = 1GiB (env only source), `MaxDirectMemorySize = 256m` (image won) — so the "512Mi direct"
comment was wrong, and `MaxRAMPercentage` was dead (ignored when `-Xmx` is set).

Resolution: the **deployment owns JVM sizing** via `JAVA_TOOL_OPTIONS` and
`MaxRAMPercentage=50.0` (75% would give 1.5GiB heap at the 2Gi limit and OOMKill the pod given
Netty/Lettuce direct buffers + ~200 thread stacks). The image must not introduce
competing sizing flags. See `BACKEND_INTEGRATION_CONTEXT.md` §0/§4 for the corrected contract.

---

## 5. Quick "before/after" for the highest-impact change (§1.1 / §item 3)

```yaml
# backend.yaml — JAVA_TOOL_OPTIONS (deployment owns sizing and GC/logging; excerpt)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:ActiveProcessorCount=2 -XX:MaxRAMPercentage=50.0
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/var/log/taskflow/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
      -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/log/taskflow
# Deployment owns heap: -XX:MaxRAMPercentage=50.0  → 1GiB heap at the 2Gi limit
resources:
  requests: { cpu: "500m", memory: "1536Mi" }
  limits:   { memory: "2Gi" }   # Burstable; no CPU quota
```

This removes the rigid heap, fixes the silent direct-memory override, and caps direct memory
and metaspace. Those caps do not bound all native allocations; OOM can still result from
legitimate load as well as a leak.

---

## 6. Node OS and Proxmox host tuning

See **`NODE_HOST_TUNING.md`**: what is already tuned, the remaining changes ranked by
impact and risk, the commands for the running node, the Terraform apply and the
Proxmox host, how to measure, and the community benchmarks behind each item.
