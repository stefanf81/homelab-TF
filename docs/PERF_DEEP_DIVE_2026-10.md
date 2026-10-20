# Performance Deep Dive — CPU sizing, Cilium, PostgreSQL (October 2026)

Detailed investigation of three items from `REMEDIATION_PLAN_2026-10.md`:
**PERF-02** (CPU reservations, limits and throttling), **PERF-03** (Cilium
tuning) and **PERF-04** (PostgreSQL tuning). For each: how the mechanism works
on *this* node, what is wrong today and why, the options with a verdict, the
recommended change as ready-to-commit YAML, how to measure before and after,
and how to roll it out and back.

Sources were read at the versions this repository runs: Cilium v1.20.2
(`install/kubernetes/cilium/values.yaml`, `templates/cilium-envoy/*`,
`pkg/datapath/linux/bandwidth/bandwidth.go`, `Documentation/operations/performance/tuning.rst`,
`Documentation/network/kubernetes/bandwidth-manager.rst`), PostgreSQL 18
(`postgresql.conf.sample` on `REL_18_STABLE`), postgres_exporter README,
proxmox-csi-plugin `docs/options.md`, Proxmox `qm.adoc`, containerd's default
seccomp profile, victoria-metrics-k8s-stack 0.96.0 `values.yaml`, and the Flux
`gotk-components.yaml` and Trivy operator chart defaults in this repo. Nothing
was run against the live cluster; numbers marked **measure** come from the
queries in §2.

---

## 0. Summary

| # | Change | Why | Disruption |
|---|---|---|---|
| 0 | Instrument first: scrape the Gateway's Envoy, enable four postgres-exporter collectors, run the baseline queries (§2) | VictoriaMetrics already holds 14 days of history; decide from data | exporter restart |
| 1 | PERF-04: `pg_stat_statements`, `jit=off`, 15-min checkpoints, `autovacuum_work_mem`, memory-backed `/dev/shm`, fixed probes, slow-query logging | Visibility first; remove known latency sources; prevent the crash-recovery loop | one Postgres restart (~10 s) |
| 2 | PERF-03: `rollOutCiliumPods` + `rollOutPods`, Envoy requests, drop agent/operator CPU limits, bandwidth manager + BBR | Config changes actually applied; Gateway data plane protected; BBR/fq pacing reaches the **host-network Envoy** that answers Cloudflare | agent restart (seconds), Envoy restart (seconds), app pods rolled |
| 3 | PERF-02: right-size requests, drop CPU limits on long-running services, fix the LimitRange (`default.cpu` **and** `max.cpu`), PriorityClass, pin JVM/Go CPU counts, fix three resource blocks that never applied (§1.5) | Node is ~90–123 % reserved; 42 of 43 containers are CFS-capped; backend rollouts need 2 free CPU; Alloy runs unbounded | rolling restarts |
| 4 | PERF-04 storage: new StorageClass with `cache: none` + `noatime` for the database volume, applied when the data moves (CNPG migration or a dump/restore) | `cache: writethrough` makes every guest write synchronous and double-caches in host RAM | Postgres migration window |

Expected effect at this traffic level: fewer latency spikes (no CFS throttling
stalls), faster backend start-up (it can use idle cores), reliable rollouts,
better behaviour of the uplink under load, and — mainly — the data to tune
further. Not more throughput: the cluster is nowhere near saturated.

---

## 1. Ground truth about this node

### 1.1 What is reserved today

From every `resources.requests` in Git plus chart defaults that are not visible
in the HelmRelease values (Flux controllers 350m from `gotk-components.yaml`,
image-reflector/automation controllers ~200m at Flux defaults, Trivy server
200m from the chart):

| | CPU requests | Memory requests |
|---|---|---|
| `taskflow` namespace | 4.26 | 3.98 GiB |
| platform (everything else) | 2.62 | 4.54 GiB |
| **steady-state total (as written in Git)** | **6.88** | **8.52 GiB** |

| VM vCPU | Allocatable (−400m kube/system reserved) | Reserved | Free | Backend surge needs |
|---|---|---|---|---|
| 6 (Terraform default) | 5.6 | 123 % | −1.28 | 2.0 |
| 8 | 7.6 | 90 % | +0.72 | 2.0 |
| 10 | 9.6 | 72 % | +2.72 | 2.0 |

Effective requests are ~0.15 CPU lower because three resource blocks never
applied (§1.5); the conclusions do not change. At 6 vCPU the pods could not all
be scheduled, so the VM must have more cores
than the Terraform default (**measure**: `kubectl describe node | grep -A8
'Allocated resources'`). At 8 vCPU the backend's rolling update — default
`maxSurge: 25 %` → 1 extra pod, `maxUnavailable: 0` — cannot schedule its 2-CPU
surge pod and waits `Pending` until the progress deadline, while Flux's health
check on `taskflow-app` fails. Transient jobs (Trivy scans 250m, Renovate 100m)
compete for the same remaining headroom.

Memory is 66 % reserved of ~12.9 GiB allocatable
(14 336 MiB − 1 000 MiB reserved − 100 MiB eviction threshold): fine.

### 1.2 Where CPU limits are

42 of 43 long-running containers have a CPU limit (sum 16.7 CPU). The ones most
likely to be throttled are those whose work is bursty and whose limit is low:

| Container | Limit | Burst pattern |
|---|---|---|
| backend (JVM) | 2 | JIT compilation, G1 concurrent marking, request spikes, start-up |
| postgres | 1 | checkpoints, autovacuum, parallel query |
| vmagent | 200m | every scrape interval (~20 targets every 30 s) |
| node-exporter / kube-state-metrics | 100m | every scrape |
| metrics-server | 200m | every 15 s kubelet poll |
| Grafana | 250m | dashboard queries and rendering |
| Kyverno admission controller | 500m in Git, **not applied** (§1.5) | every admission request (webhook latency adds to `kubectl apply` and Flux applies) |
| cilium-agent | 1 | endpoint regeneration after policy/config changes |
| Falco | 1 | syscall bursts — a throttled Falco drops events |

### 1.3 The request path

```
client ─▶ Cloudflare ─▶ router :443 ─▶ 192.168.50.201 (L2-announced)
        ─▶ cilium-envoy  (DaemonSet, hostNetwork: true, no resource requests)
        ─▶ taskflow-{frontend,backend}-waf pod (Caddy + Coraza CRS)   [pod veth]
        ─▶ frontend (nginx) | backend (JVM) ─▶ postgres / redis / jaeger
```

Two consequences matter below: the hop that talks to the internet (Envoy →
Cloudflare) runs in the **host network namespace**, so pod-level networking
features do not touch it; and the Gateway's data plane currently has no CPU or
memory request at all.

### 1.4 Storage under Postgres

`proxmox-csi` StorageClass: `local-lvm` (LVM-thin), `ext4`, **`cache:
writethrough`**, `ssd: true`. Proxmox's default and documented balance of
safety and speed is `cache=none` (`qm.adoc`: "provides a good balance between
safety and speed"). With `writethrough` the host page cache serves reads while
every write is reported complete only after it reaches storage — so even
Postgres's non-fsync writes (background writer, checkpoints) wait for the disk,
and data is cached three times (shared_buffers, guest page cache, host page
cache). The plugin cannot change `cache` on an existing volume (it is not among
the `VolumeAttributesClass`-mutable parameters), so it changes only when the
data moves to a new PVC.

### 1.5 Resource settings that never applied

Checked against each chart's `values.yaml` and templates at the pinned versions.
Helm silently ignores values a chart does not read, so these blocks look
configured in Git but have no effect:

| Component | Repo sets | Chart reads | Effect today |
|---|---|---|---|
| Kyverno admission controller (chart 3.9.1) | `admissionController.resources` | `admissionController.container.resources` | Chart defaults: 100m / 128Mi request, 384Mi memory limit, no CPU limit — not the intended 256Mi/512Mi + 500m. The other three controllers use the top-level key correctly. |
| Grafana Alloy (chart 1.13.1) | top-level `resources` | `alloy.resources` (template merges `.Values.alloy`) | **No requests or limits on the Alloy container** — it can grow without bound; only the config-reloader sidecar has its 10m/50Mi default request |
| Hubble UI (Cilium chart) | `hubble.ui.resources` | `hubble.ui.backend.resources` and `hubble.ui.frontend.resources` | Both UI containers run without requests or limits |
| Policy Reporter plugins | (nothing) | `plugin.kyverno.resources`, `plugin.trivy.resources` | The two plugin Deployments run BestEffort |
| cilium-envoy | (nothing) | `envoy.resources` (default `{}`) | The Gateway data plane runs without requests or limits (PERF-03) |

Correct keys are used in the changes below. A quick way to see what a pod
actually got: `kubectl get pod <pod> -n <ns> -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.resources}{"\n"}{end}'`.

---

## 2. Measure first

VictoriaMetrics keeps 14 days and already scrapes cAdvisor (the stack's kubelet
scrape drops only `rest_client_request_duration_seconds_*` and the `uid`/`id`/
`name` labels, so all `container_cpu_*` series are kept). Run these in Grafana
Explore before changing anything and save the results.

### 2.1 Add the missing instrumentation (no app restarts)

The Gateway's Envoy exposes metrics on port 9964 through the chart's headless
`cilium-envoy` Service (port name `envoy-metrics`, enabled by default), but
nothing scrapes it. It is the best end-to-end latency signal you have:

```yaml
# gitops/monitoring/app/vmservicescrapes.yaml (append)
---
# --- Cilium Envoy (Gateway data plane: downstream/upstream latency, 5xx) ------
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cilium-envoy
  namespace: monitoring
spec:
  jobLabel: app.kubernetes.io/name
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: cilium-envoy
  endpoints:
    - port: envoy-metrics
      path: /metrics
      interval: 30s
      scheme: http
```

postgres_exporter: `stat_checkpointer` is **disabled by default** — and since
PostgreSQL 17 checkpoint statistics live only in `pg_stat_checkpointer` — as are
`stat_statements`, `long_running_transactions` and `statio_user_indexes`:

```yaml
# gitops/apps/taskflow/postgres-exporter.yaml, container
          args:
            - --collector.stat_checkpointer
            - --collector.stat_statements          # needs the extension (PERF-04 step 1)
            - --collector.stat_statements.limit=50
            - --collector.long_running_transactions
            - --collector.statio_user_indexes
            - --collector.stat_activity_autovacuum
```

(Add `stat_statements` only after the extension exists, or the collector logs
errors every scrape.)

### 2.2 CPU (PERF-02)

```promql
# p95 and max CPU per container, 14 days (the sizing input)
quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])[14d:5m])
max_over_time(rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])[14d:5m])

# throttling: share of CFS periods in which the container hit its quota
sum by (namespace, pod, container) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
  / sum by (namespace, pod, container) (rate(container_cpu_cfs_periods_total{container!=""}[5m]))

# requests vs real use, per namespace
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))

# node reservation and saturation
sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"})
1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))

# memory sizing input
max_over_time(container_memory_working_set_bytes{container!="",container!="POD"}[14d])
```

Decision thresholds: throttled-period ratio > 5 % on a latency-sensitive
container is worth fixing, > 25 % is certainly hurting; a request more than 3×
the p95 is over-reserved.

### 2.3 Latency (all three)

```promql
# backend (Micrometer): p95 server latency
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{job=~".*taskflow-backend.*"}[5m])))

# Gateway (Envoy): p95 downstream request time; confirm series names in VMUI first
histogram_quantile(0.95, sum by (le) (rate(envoy_http_downstream_rq_time_bucket[5m])))

# JVM GC pauses and Hikari waits
rate(jvm_gc_pause_seconds_sum[5m]) / rate(jvm_gc_pause_seconds_count[5m])
histogram_quantile(0.95, sum by (le) (rate(hikaricp_connections_acquire_seconds_bucket[5m])))
```

### 2.4 Disk (PERF-04)

```promql
# average write / read latency per device (find the PV device: lsblk on the node)
rate(node_disk_write_time_seconds_total[5m]) / rate(node_disk_writes_completed_total[5m])
rate(node_disk_read_time_seconds_total[5m])  / rate(node_disk_reads_completed_total[5m])
```

On the Proxmox host, see how the PV disk is really attached:
`qm config <vmid> | grep -E '^scsi'` (look for `cache=`, `iothread=`, `ssd=`,
`discard=` on the disks the CSI plugin added).

### 2.5 PostgreSQL

```bash
kubectl -n taskflow exec -it deploy/postgres-db -- psql -U postgres -d taskflow
```

```sql
-- size vs shared_buffers (384MB): if the DB fits, reads are memory-speed already
SELECT pg_size_pretty(pg_database_size('taskflow'));

-- buffer hit ratio (≥ 99 % expected for a small OLTP DB)
SELECT round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_pct,
       temp_files, pg_size_pretty(temp_bytes) AS temp, deadlocks
FROM pg_stat_database WHERE datname = 'taskflow';

-- checkpoints: requested (WAL-size driven) vs timed, and their cost
SELECT num_timed, num_requested, write_time, sync_time, buffers_written
FROM pg_stat_checkpointer;

-- WAL volume and I/O (PG 18 reports WAL I/O in pg_stat_io)
SELECT * FROM pg_stat_wal;
SELECT backend_type, object, context, writes, write_time, fsyncs, fsync_time
FROM pg_stat_io WHERE object = 'wal';

-- tables that need autovacuum attention
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, autovacuum_count
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;

-- long or idle-in-transaction sessions (before considering idle_in_transaction_session_timeout)
SELECT pid, usename, state, now() - xact_start AS xact_age, left(query, 60)
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY xact_age DESC NULLS LAST;
```

Low-level checks inside the pod (both binaries ship with the server image):

```bash
# fsync latency of the PV — the cost of synchronous_commit=on per commit
kubectl -n taskflow exec deploy/postgres-db -- sh -c \
  'pg_test_fsync -s 2 -f /var/lib/postgresql/18/data/pg_test_fsync.tmp; rm -f /var/lib/postgresql/18/data/pg_test_fsync.tmp'
# clock read overhead — the cost of track_io_timing
kubectl -n taskflow exec deploy/postgres-db -- pg_test_timing
```

`pg_test_fsync` reports operations per second for each sync method; latency per
commit ≈ 1 / (`fdatasync` ops/s). `pg_test_timing` should show most reads under
100 ns (KVM guests normally use `kvm-clock`/TSC and pass).

---

## 3. PERF-02 — CPU reservations, limits and throttling

### 3.1 How it works here (cgroup v2, k3s 1.36)

- **Requests** become `cpu.weight` on the container's cgroup. They matter in two
  places: the scheduler (a pod fits only if the sum of requests fits the node's
  allocatable) and contention (when the node is busy, CPU is shared in proportion
  to weight). An idle node ignores them.
- **Limits** become `cpu.max` = quota per 100 ms period. A 2-CPU limit allows
  200 ms of CPU time per 100 ms across all threads; once used, *every* thread of
  the container sleeps until the next period, **even if the node is idle**.
  Multi-threaded runtimes hit this in bursts: a JVM with 8 GC/JIT threads can
  burn a 2-CPU quota in 25 ms and then stall 75 ms.
- **QoS** is derived from both: requests = limits for every resource →
  Guaranteed; otherwise Burstable. Guaranteed does **not** mean unthrottled
  unless the kubelet's static CPU manager gives the pod exclusive cores.
- **Runtimes read the limit, not the request.** The JVM sizes
  `availableProcessors` (GC threads, JIT threads, ForkJoin pools, Netty/Lettuce
  event loops) from the CPU limit; with no limit it sees every node CPU (since
  JDK 19 it no longer derives a count from CPU shares). Go ≥ 1.25 derives
  `GOMAXPROCS` from the CPU limit and otherwise uses all CPUs. nginx's
  `worker_processes auto` always sees all CPUs.

### 3.2 What is wrong

1. Over-reservation (§1.1): requests are set to *peak* expectations, not typical
   use, so idle pods block scheduling.
2. Throttling: almost every container is capped, several far below their burst
   needs (§1.2). The `backend.yaml` comment claims Guaranteed QoS means CPU is
   never throttled; that is only true with the static CPU manager.
3. The `taskflow` `LimitRange` injects `default.cpu: 500m` into any container
   without a CPU limit **and** sets `max.cpu: 4`. The LimitRanger admission
   plugin rejects a container that has no CPU limit when a CPU `max` exists
   ("maximum cpu usage per Container is 4, … No limit is specified") unless a
   default fills it in. So removing CPU limits from a Deployment either gets a
   tighter 500m limit injected or — once the default is removed — the pod is
   rejected. Both keys must go.
4. Runtime coupling: removing the backend's CPU limit without pinning the JVM's
   processor count roughly quadruples its GC/JIT/event-loop threads.

### 3.3 Options

| Option | What | Pros | Cons | Verdict |
|---|---|---|---|---|
| A | Requests ≈ measured p95 × 1.3 (floor 10m); **no CPU limit** on long-running services; memory request = limit for stateful/critical pods; limits kept on batch jobs | No throttling; idle CPU is shared; scheduling headroom returns; what onedr0p/buroa run | Pods become Burstable (see 3.7 for why that is fine); a runaway pod can use idle CPU (bounded by weights under contention) | **Recommended** |
| A2 | As A, but keep a *generous* CPU limit (≥ 4× request, ≥ 1 CPU) as a runaway cap | Bounds a spinning process | Still throttles at the cap; two numbers to maintain | Use for third-party components you do not trust |
| B | Keep Guaranteed integer CPUs and enable the kubelet static CPU manager | Truly exclusive cores | Reserves whole cores (wasteful on 6–8 vCPU); kubelet drop-in, `k3s-killall.sh` and state-file reset; Proxmox vCPUs are not pinned to physical cores anyway | Not worth it here |
| C | Kubelet `cpuCFSQuota: false` (node-wide: limits ignored) | One switch | Also disables limits for scan/batch jobs; invisible in manifests | No |
| D | VPA in recommendation mode (`updateMode: "Off"`) or Goldilocks | Continuous recommendations | One more controller; the queries in §2.2 give the same answer once | Optional |
| E | Bigger VM | No YAML changes | Hides the problem; costs host RAM/CPU | No |

### 3.4 Recommended design (option A)

Rules:

1. **CPU requests** = p95 over 14 days × 1.3, rounded up, minimum 10m. For the
   latency-critical path (backend, Postgres, WAFs) use p99 × 1.2 if it is much
   higher than p95.
2. **No CPU limits** on long-running services. Keep CPU limits on jobs and
   scanners (Trivy scan jobs, Trivy server, Renovate) so they cannot starve the app.
3. **Memory**: request = limit for Postgres, Redis, backend (stateful or
   expensive to restart); others request ≈ p95 working set, limit ≈ max × 1.3.
4. **PriorityClass** `taskflow-critical` for the request path and data stores, so
   they are scheduled first and evicted last under node pressure.
5. **Pin runtime CPU counts** where the runtime reads the limit: JVM
   `-XX:ActiveProcessorCount=2`; Go services `GOMAXPROCS=2` (optional).
6. **LimitRange**: drop `default.cpu` and `max.cpu`; keep CPU `defaultRequest`
   and all memory settings.
7. Re-enable the `CPUThrottlingHigh` alert afterwards (REL-01 disabled it) — it
   then only fires for workloads that still have limits.

### 3.5 Starting values (confirm with §2.2)

| Workload | CPU req now → new | CPU limit now → new | Memory req / limit |
|---|---|---|---|
| backend | 2000m → **500m** | 2000m → none | 2Gi / 2Gi |
| postgres | 1000m → **250m** | 1000m → none | 1Gi / 1Gi |
| redis | 500m → **50m** | 500m → none | 512Mi / 512Mi |
| backend WAF | 100m → 100m | 750m → none | 128Mi / 768Mi |
| frontend WAF | 50m → 50m | 500m → none | 96Mi / 512Mi |
| frontend (nginx) | 250m → **25m** | 250m → none | 128Mi / 256Mi |
| jaeger | 250m → **25m** | 250m → none | 128Mi / 256Mi |
| postgres/redis exporters | 50m → 10m | 250m → none | 32Mi / 128Mi |
| cloudflare-ddns | 10m → 5m | 50m → none | 16Mi / 32Mi |
| cilium agent / operator | 100m / 50m (keep) | 1 / 500m → none | unchanged |
| cilium-envoy | none → **50m** | none | 128Mi / 512Mi (PERF-03) |
| Kyverno admission (fix key: `admissionController.container.resources`) / 3 others | 100m → 50m / 25m | (not applied) / 200m → none | 256Mi / 512Mi (now actually applied); others unchanged |
| vmagent, node-exporter, kube-state-metrics, metrics-server | 50m, 10m, 10m, 50m → 50m, 10m, 10m, 20m | 200m, 100m, 100m, 200m → none | unchanged |
| Grafana, Loki, VMSingle | 50m, 100m, 100m (keep) | 250m, 1, 1 → none | unchanged |
| Alloy (fix key: `alloy.resources`) | none applied → 50m | none applied → none | 128Mi / 512Mi (first time applied) |
| Hubble UI (fix keys: `hubble.ui.backend/frontend.resources`) | none applied → 10m each | none | 32Mi request; limit 256Mi backend, 128Mi frontend (first-time caps) |
| Policy Reporter plugins (`plugin.kyverno/trivy.resources`) | none → 10m each | none | 32Mi / 128Mi each |
| Falco | 100m (keep) | 1 → none (a throttled Falco drops events) | unchanged |
| policy-reporter ×3, oauth2-proxy ×2, trivy-operator, renovate-operator | 50m → 10–25m | → none | unchanged |
| Trivy server / scan jobs, Renovate job | 200m / 250m / 100m → 50m / keep / keep | **keep limits** | unchanged |

Projected steady-state reservation: **~2.9 CPU** (from 6.88) — `taskflow`
~1.0 CPU, platform including Flux ~1.9 CPU. That leaves several cores of
headroom on any VM size ≥ 6 vCPU, including room for the backend's surge pod.

### 3.6 Changes

**PriorityClass** — new file `gitops/infrastructure/configs/priorityclasses.yaml`
(and add it to that directory's `kustomization.yaml`):

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: taskflow-critical
value: 100000
globalDefault: false
# Never preempt other pods to make room: the class only orders scheduling and
# makes these pods the last eviction candidates under node pressure. With
# right-sized requests there is room without preemption.
preemptionPolicy: Never
description: "TaskFlow request path and data stores (WAFs, frontend, backend, Postgres, Redis)."
```

**LimitRange** — `gitops/apps/taskflow/namespace.yaml`:

```yaml
spec:
  limits:
    - type: Container
      # No default CPU limit and no CPU max: a CPU max makes the LimitRanger
      # reject containers without a CPU limit. Memory stays bounded.
      default:
        memory: 512Mi
      defaultRequest:
        cpu: 50m
        memory: 128Mi
      max:
        memory: 4Gi
```

**Backend** — `gitops/apps/taskflow/backend.yaml`:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  template:
    spec:
      priorityClassName: taskflow-critical
      containers:
        - name: backend
          env:
            - name: JAVA_TOOL_OPTIONS
              # add -XX:ActiveProcessorCount=2 (keeps GC/JIT/event-loop thread counts
              # as they are today now that no CPU limit caps what the JVM sees);
              # drop -XX:+UseContainerSupport (default since JDK 10)
              value: "-XX:ActiveProcessorCount=2 -XX:+UseG1GC -XX:MaxRAMPercentage=50.0 …"
          resources:
            requests: {cpu: 500m, memory: 2Gi}
            limits: {memory: 2Gi}
```

The `wait-for-db` init container keeps its explicit values (they no longer make
the pod Guaranteed, but they stop the LimitRange from injecting defaults).

**Other TaskFlow workloads** — excerpts under each Deployment's
`spec.template.spec` (same pattern; the WAFs add `GOMAXPROCS`):

```yaml
# postgres-db.yaml (full container change in §5.5)
priorityClassName: taskflow-critical
containers:
  - name: postgres
    resources:
      requests: {cpu: 250m, memory: 1Gi}
      limits: {memory: 1Gi}
---
# redis.yaml
priorityClassName: taskflow-critical
containers:
  - name: redis
    resources:
      requests: {cpu: 50m, memory: 512Mi}
      limits: {memory: 512Mi}
---
# backend-waf.yaml (frontend-waf: requests 50m / 96Mi, memory limit 512Mi)
priorityClassName: taskflow-critical
containers:
  - name: waf
    env:
      - {name: GOMAXPROCS, value: "2"}
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {memory: 768Mi}
---
# frontend.yaml
priorityClassName: taskflow-critical
containers:
  - name: frontend
    resources:
      requests: {cpu: 25m, memory: 128Mi}
      limits: {memory: 256Mi}
---
# jaeger.yaml (no priority class: tracing is optional)
containers:
  - name: jaeger
    resources:
      requests: {cpu: 25m, memory: 128Mi}
      limits: {memory: 256Mi}
```

**Platform HelmReleases** — remove `limits.cpu` and lower requests per the table,
for example:

```yaml
# monitoring/platform/release.yaml
    vmagent:
      spec:
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {memory: 256Mi}
# infrastructure/controllers/kyverno/release.yaml — admission controller key fixed (§1.5)
    admissionController:
      replicas: 1
      container:
        resources:
          requests: {cpu: 50m, memory: 256Mi}
          limits: {memory: 512Mi}
    backgroundController:            # top-level key is correct for the other three
      resources:
        requests: {cpu: 25m, memory: 128Mi}
        limits: {memory: 256Mi}
# monitoring/logging/alloy-release.yaml — move the block under `alloy:` (§1.5)
    alloy:
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: 512Mi}
# infrastructure/controllers/cilium/release.yaml — Hubble UI keys fixed (§1.5)
    hubble:
      ui:
        backend:
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 256Mi}}
        frontend:
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
# infrastructure/controllers/policy-reporter/release.yaml — plugins had none
    plugin:
      kyverno:
        enabled: true
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
      trivy:
        enabled: true
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
```

Giving Alloy a memory limit for the first time can surface a real need: check
`max_over_time(container_memory_working_set_bytes{container="alloy"}[14d])`
first and set the limit to at least 1.3× that. After committing, confirm every
pod got what Git says (command in §1.5).

### 3.7 Side effects and guardrails

- **QoS changes from Guaranteed to Burstable** for backend, Postgres and the
  frontend. Two things depend on QoS:
  - OOM killer score: Guaranteed −997; Burstable `1000 − 1000 × memoryRequest /
    nodeMemory` (≈ 860 for a 2 GiB request on 14 GiB). The kernel OOM killer
    only acts when the *node* runs out of memory; container-level OOM (hitting
    its own limit) is unaffected.
  - Kubelet node-pressure eviction ranks first the pods whose usage exceeds their
    requests, then by priority, then by usage above request. With memory request
    = limit a pod never exceeds its request, and `taskflow-critical` puts it
    last — so in practice they keep the protection Guaranteed gave them.
- **Noisy neighbours**: without limits, requests are the protection. Under full
  contention each container gets CPU in proportion to its request, so the
  backend (500m) and Postgres (250m) are guaranteed at least that much.
- **The k3s server process** (API server, kine, controllers) runs outside the
  `kubepods` cgroup and competes by cgroup weight. `system-reserved` and
  `kube-reserved` (200m each) only reduce allocatable; they do not cap pods. Add
  an alert on node CPU saturation (`1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.9`
  for 15 min) so a runaway pod is noticed.
- **Startup** gets faster: the JVM can use idle cores during class loading and
  JIT warm-up instead of being capped at 2.

### 3.8 Rollout, verification, rollback

1. Commit the PriorityClass first (cluster-scoped, no effect on its own).
2. One commit for `taskflow`: LimitRange + all Deployment changes together (the
   LimitRange must change in the same reconcile, or the first Deployment without
   a CPU limit is rejected or capped at 500m). Flux rolls the pods one by one.
3. Platform HelmReleases in a second commit.
4. Verify: `kubectl -n taskflow get pod -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass,PRIO:.spec.priority`;
   throttled-period ratio ≈ 0 for every container without a limit; node CPU
   requests < 50 %; force a backend rollout (`kubectl -n taskflow rollout restart
   deploy/taskflow-backend`) and watch it complete; compare §2.3 latency with
   the baseline.
5. Rollback: `git revert` the commit; Flux restores the previous limits.

---

## 4. PERF-03 — Cilium tuning

### 4.1 How traffic flows through Cilium here

- Kube-proxy replacement with socket-level load balancing handles ClusterIP
  traffic inside the node (WAF → backend Service etc.).
- Gateway traffic to `192.168.50.201` is handed to the per-node `cilium-envoy`
  DaemonSet, which the chart hard-codes to `hostNetwork: true`. Envoy terminates
  TLS and opens new connections to the WAF pods.
- `routingMode` defaults to `tunnel` (VXLAN), but on a single node pod-to-pod
  traffic never leaves the node, so nothing is encapsulated today.
- Pods use veth pairs (`bpf.datapathMode: veth`), eBPF host routing is on
  (`bpf.hostLegacyRouting: false`) and masquerading is in eBPF.

### 4.2 Every candidate setting, evaluated

| Setting | Default | Effect on this cluster | Verdict |
|---|---|---|---|
| `rollOutCiliumPods`, `operator.rollOutPods`, `envoy.rollOutPods`, `hubble.relay.rollOutPods`, `hubble.ui.rollOutPods` | all false | Today a Helm value change updates `cilium-config` but the agents keep running with the old configuration until something restarts them. These add a config-checksum annotation so changes roll out. | **Enable** (correctness) |
| `envoy.resources` | `{}` | The Gateway data plane has no CPU request (it gets no share under contention) and no memory request (worst OOM score on the node). | **Set** requests 50m / 128Mi, memory limit 512Mi |
| Agent/operator CPU limits (`1`, `500m`) | none in chart | Throttling extends endpoint regeneration after policy or config changes. | **Remove** CPU limits (keep memory limits) |
| `bandwidthManager.enabled` + `bbr` | false | The agent (host network) sets `net.core.default_qdisc=fq`, `net.ipv4.tcp_congestion_control=bbr` and `net.ipv4.tcp_slow_start_after_idle=0` (`bandwidth.go`), and raises `somaxconn`/`tcp_max_syn_backlog` to 4096. Because Envoy runs in the host namespace, **its connections to Cloudflare get BBR + fq pacing**: lower queueing delay on the home uplink under load, and no cwnd collapse on idle keep-alive connections (`slow_start_after_idle=0`). Pods get BBR on new sockets (requires kernel ≥ 5.18 and eBPF host routing: both satisfied). | **Enable** — see caveat below |
| `bandwidthManager.bbrHostNamespaceOnly` | false | Only needed with legacy host routing. | Leave false |
| `gatewayAPI.enableAlpn` | false | Lets clients negotiate HTTP/2 with Envoy. Useful only if Cloudflare's *HTTP/2 to Origin* is on, or with a Cloudflare Tunnel using `http2Origin: true` (SEC-01). | Enable together with SEC-01 |
| `gatewayAPI.enableAppProtocol` | false | Honours Service `appProtocol` (h2c) for upstream. The Gateway routes to the WAFs, whose Services have no appProtocol; the backend's h2c is never used. | Skip |
| `bpf.datapathMode: netkit` | veth | Lower per-packet overhead for pods. Beta in 1.20; "the CNI plugin cannot simply replace veth with netkit after Pod creation" and "running both flavors in parallel is currently not supported" (`tuning.rst`). On a single node that means drain-all, switch, restart everything. Gain for an app with human traffic: negligible. | **Defer** to the next node rebuild |
| `routingMode: native` + `autoDirectNodeRoutes` | tunnel | No effect with one node; changing it live briefly disrupts pod networking. | Set **before adding a second node** |
| `enableIPv4BIGTCP` | false | "Supported NICs: mlx4, mlx5, ice" and needs tunnelling off; the VM has virtio-net. | Not applicable |
| `loadBalancer.acceleration` (XDP) | disabled | Accelerates BPF-terminated LoadBalancer/NodePort traffic; Gateway traffic is terminated by Envoy, not the BPF LB. | Not applicable |
| `bpf.distributedLRU` + `mapDynamicSizeRatio` | off | Large-cluster map scaling; recreating maps on a running cluster is disruptive. | Skip |
| `bpf.preallocateMaps` | false | Slightly steadier latency for more memory. Unmeasurable at this scale. | Skip |
| `installNoConntrackIptablesRules` | false | Requires native routing. | Skip |
| Hubble | on (dns, drop, tcp, flow, icmp, httpV2; DROPPED/ERROR export) | Cilium documents 1–15 % overhead depending on traffic; at homelab traffic it is small and the visibility is used (dashboards, SEC-04a). | Keep; revisit `bpf.events.monitorInterval` only if agent CPU is high |

**BBR caveat.** Cilium's docs note BBR "could lead to a higher amount of TCP
retransmissions and more aggressive behavior towards TCP CUBIC connections".
The cluster shares the home uplink with other devices; with BBR the cluster's
uploads (responses to Cloudflare) compete harder against household CUBIC
traffic. At this traffic volume that is unlikely to be noticeable, and fq
pacing reduces burstiness — but if household upload latency matters more than
the site's, enable `bandwidthManager` without `bbr` (you still get fq and the
backlog sysctls).

### 4.3 Changes

`gitops/infrastructure/controllers/cilium/release.yaml` — merged into the
existing values:

```yaml
  values:
    rollOutCiliumPods: true
    resources:                       # agent: CPU limit removed
      requests: {cpu: 100m, memory: 256Mi}
      limits: {memory: 1Gi}
    operator:
      replicas: 1
      rollOutPods: true
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: 512Mi}
      prometheus: {enabled: true, metricsService: true}
    envoy:
      rollOutPods: true
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: 512Mi}
    bandwidthManager:
      enabled: true
      bbr: true
    hubble:
      relay:
        rollOutPods: true
        # (existing resources stay; CPU limit may be dropped per PERF-02)
      ui:
        rollOutPods: true
        # replaces the ignored `hubble.ui.resources` block (§1.5)
        backend:
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 256Mi}}
        frontend:
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
    # unchanged: ipam, kubeProxyReplacement, k8sServiceHost/Port, devices, bpf.*,
    # encryption, prometheus, gatewayAPI, l2announcements, hubble metrics/export
```

### 4.4 Rollout, verification, rollback

1. Commit; Flux upgrades the release. With `rollOutCiliumPods` now set, the
   agent restarts (a few seconds; established connections survive, the eBPF
   datapath keeps forwarding during the restart).
2. Restart Envoy so its listening sockets are re-created with BBR (the
   bandwidth-manager change does not alter the Envoy ConfigMap, so `rollOutPods`
   does not trigger): `kubectl -n kube-system rollout restart ds/cilium-envoy`
   — a few seconds of Gateway interruption.
3. Restart the workloads so new pod sockets use BBR (`kubectl -n taskflow
   rollout restart deploy`; others at leisure). Cilium: "In-place upgrade by just
   enabling BBR on an existing cluster is not possible."
4. Verify:

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'BandwidthManager|Host Routing|KubeProxyReplacement'
   #   BandwidthManager: EDT with BPF [BBR] [eth0]
   # on the node:
   sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_slow_start_after_idle
   tc qdisc show dev eth0                      # mq / fq
   ss -tin state established '( sport = :443 )' | grep -o 'bbr' | sort | uniq -c   # Envoy's client connections
   kubectl -n kube-system get pod -l k8s-app=cilium-envoy -o jsonpath='{..resources}'
   ```

   Then compare Envoy p95 downstream latency (§2.3) before and after.
5. Rollback: set `bandwidthManager.bbr: false` (the agent writes `cubic` back) or
   disable the bandwidth manager entirely (sysctls then stay as last set until a
   reboot or a manual `sysctl -w`), and restart Envoy.

### 4.5 Deferred, with triggers

- **netkit**: at the next node rebuild (new node, `bpf.datapathMode: netkit` and
  `routingMode: native` from first boot).
- **Native routing**: in the same change that adds a second node.
- **Gateway ALPN**: with SEC-01 (tunnel) or when enabling Cloudflare's HTTP/2 to
  Origin.

---

## 5. PERF-04 — PostgreSQL tuning

### 5.1 Memory budget of the 1 GiB container

| Consumer | Typical | Worst case | Notes |
|---|---|---|---|
| `shared_buffers` | 384 MB | 384 MB | Counted once (shared memory), once touched |
| Backends (Hikari pool + exporter + psql) | 15 × ~6 MB ≈ 90 MB | 50 × ~10 MB ≈ 500 MB | `max_connections=50` |
| `work_mem` sorts/hashes | ~0 | 25 × 2 × 8 MB = 400 MB | Per sort/hash node per backend |
| Autovacuum | small | 3 × `autovacuum_work_mem` | Defaults to `maintenance_work_mem` (64 MB) → 192 MB |
| `/dev/shm` (parallel query) | ~0 | few MB | Counts against the limit when used |
| Page cache for data files | reclaimable | — | Charged to the cgroup, reclaimed under pressure |

Typical total ≈ 500–600 MB; the theoretical worst case exceeds 1 GiB only with
dozens of concurrent large sorts. Capping autovacuum at 32 MB per worker
(`autovacuum_work_mem=32MB`; PostgreSQL 17+'s radix-tree TID store makes this
go much further than it used to) removes 96 MB from the worst case without
affecting index builds, which keep `maintenance_work_mem=64MB`.

### 5.2 Settings, evaluated (PostgreSQL 18 defaults from `postgresql.conf.sample`)

| Setting | Default | Current | Recommended | Why |
|---|---|---|---|---|
| `shared_preload_libraries` | — | — | `pg_stat_statements` | Per-statement timing; prerequisite for any query tuning. Restart. |
| `pg_stat_statements.track_utility` | on | — | `off` | Ignore `SET`/`BEGIN` noise |
| `track_io_timing` | off | — | `on` | I/O time per query/table; check `pg_test_timing` first |
| `track_wal_io_timing` | off | — | `on` | WAL write/fsync timing in `pg_stat_io` — the input for the `synchronous_commit` decision |
| `jit` | on (`jit_above_cost` 100000) | on | `off` | JIT compiles only expensive plans, but a misestimate on a short OLTP query adds tens of ms. The CNPG minimal image has no JIT, so this also matches a future migration. |
| `checkpoint_timeout` | 5min | 300 (s) | `15min` | Fewer checkpoints → fewer full-page images in WAL; `max_wal_size=2GB` already allows it. Crash recovery replays more WAL, which is why REL-03's probe fix comes in the same change. |
| `max_parallel_maintenance_workers` | 2 | 2 | remove | Already the default |
| `autovacuum_work_mem` | −1 (= maintenance_work_mem) | — | `32MB` | Memory budget (5.1) |
| `log_min_duration_statement` | −1 | — | `500ms` | Slow-query log |
| `log_temp_files` | −1 | — | `0` | Shows when `work_mem` is too small |
| `log_lock_waits` | off | — | `on` | Logs waits longer than `deadlock_timeout` (1 s) |
| `synchronous_commit` | on | off | decide from `pg_test_fsync` + pgbench (5.4); recommendation **on** | REL-04 |
| `io_method` | worker (`io_workers=3`) | worker | **keep** | `io_uring` needs a liburing build and its syscalls are not in containerd's default seccomp allowlist, which `seccompProfile: RuntimeDefault` uses — it would fail. Worker mode is fine for an in-memory OLTP dataset. |
| `effective_io_concurrency` | 16 | 200 | keep (or 64) | Prefetch depth for read streams/bitmap scans; harmless on SSD, no effect while data fits in memory |
| `wal_compression` | off | zstd | keep | Smaller WAL for little CPU |
| `wal_level` | replica | replica | keep | `minimal` would save WAL on bulk loads but rules out archiving/backups (REL-02) |
| `huge_pages` | try | try | keep | Would need node hugepages + a `hugepages-2Mi` resource on the pod; gain for 384 MB of buffers is small |
| `max_parallel_workers_per_gather` | 2 | 2 | keep | Useful once the CPU limit is gone (PERF-02); OLTP queries rarely qualify |
| `idle_in_transaction_session_timeout` | 0 | — | only after checking `pg_stat_activity` | Could kill a legitimate long transaction (check the SSE endpoint's behaviour first) |
| `shared_buffers` | 128MB | 384MB | keep unless DB ≪ 384 MB and memory is needed elsewhere | Check DB size and hit ratio (§2.5) |

### 5.3 The storage layer

Recommended: a dedicated StorageClass for databases, used when the data moves
(the CNPG migration in REL-02 creates a new PVC anyway; otherwise a planned
dump/restore):

```yaml
# gitops/infrastructure/controllers/proxmox-csi/release.yaml — second entry in the
# chart's storageClass list (the chart supports cache, ssd and mountOptions per entry)
    storageClass:
      - name: proxmox-csi              # unchanged (still the default class)
        storage: local-lvm
        volumeBindingMode: WaitForFirstConsumer
        reclaimPolicy: Retain
        fstype: ext4
        cache: writethrough
        ssd: true
        annotations:
          storageclass.kubernetes.io/is-default-class: "true"
      - name: proxmox-csi-db
        storage: local-lvm
        volumeBindingMode: WaitForFirstConsumer
        reclaimPolicy: Retain
        fstype: ext4
        cache: none                    # Proxmox default; guest fsyncs are honoured
        ssd: true                      # also enables discard
        mountOptions:
          - noatime                    # no metadata write on every read
```

The chart's StorageClass template hard-codes `allowVolumeExpansion: true` and
renders `mountOptions` per entry, so no patch is needed for online growth.

Before moving data, measure both classes with the same tool Postgres cares
about:

```yaml
# one-off benchmark: create once per StorageClass (change the two names), compare outputs
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fsync-test-db, namespace: taskflow}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: proxmox-csi-db           # then: proxmox-csi
  resources: {requests: {storage: 1Gi}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: fsync-test-db, namespace: taskflow}
spec:
  backoffLimit: 0
  template:
    metadata: {labels: {app.kubernetes.io/name: fsync-test, app.kubernetes.io/part-of: taskflow}}
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 70, fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: test
          image: postgres:18.6-alpine
          command: ["sh", "-c", "pg_test_fsync -s 5 -f /data/test.tmp"]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 128Mi}}
          volumeMounts: [{name: d, mountPath: /data}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: fsync-test-db}}]
```

`kubectl -n taskflow logs job/fsync-test-db`, then delete the Job and PVC (and
the Retained PV). Expect `cache: none` to show equal or better `fdatasync` and
clearly better non-sync write numbers; if it does not on your hardware, keep
`writethrough`.

### 5.4 Deciding `synchronous_commit` with data (REL-04)

```bash
kubectl -n taskflow exec -it deploy/postgres-db -- sh
createdb -U postgres bench
pgbench -U postgres -i -s 10 bench                                  # ~150 MB
PGOPTIONS='-c synchronous_commit=on'  pgbench -U postgres -c 4 -j 2 -T 60 -N bench
PGOPTIONS='-c synchronous_commit=off' pgbench -U postgres -c 4 -j 2 -T 60 -N bench
dropdb -U postgres bench
```

Run it off-hours (it shares the container's CPU and memory with production).
Compare `latency average`: if `on` adds about one `fdatasync` (typically 0.1–2 ms
on SSD-backed LVM-thin) per write transaction, that is invisible behind a
browser round trip through Cloudflare, and durability wins. Keep `off` only if
the difference is large *and* losing up to ~600 ms (3 × `wal_writer_delay`) of
confirmed bookings after a crash is acceptable.

### 5.5 Changes

`gitops/apps/taskflow/postgres-db.yaml` — end state, including REL-03's probe fix.
The resources part lands with step 4 of §6 (it needs the LimitRange change in
the same commit), so Postgres restarts twice across the rollout, a few seconds
each:

```yaml
spec:
  template:
    spec:
      priorityClassName: taskflow-critical
      terminationGracePeriodSeconds: 60
      containers:
        - name: postgres
          image: postgres:18.6-alpine
          args:
            - "-c"
            - "shared_buffers=384MB"
            - "-c"
            - "effective_cache_size=700MB"
            - "-c"
            - "work_mem=8MB"
            - "-c"
            - "maintenance_work_mem=64MB"
            - "-c"
            - "autovacuum_work_mem=32MB"
            - "-c"
            - "max_connections=50"
            - "-c"
            - "random_page_cost=1.1"
            - "-c"
            - "effective_io_concurrency=200"
            - "-c"
            - "checkpoint_timeout=15min"
            - "-c"
            - "wal_buffers=16MB"
            - "-c"
            - "wal_compression=zstd"
            - "-c"
            - "max_wal_size=2GB"
            - "-c"
            - "synchronous_commit=on"        # REL-04: confirm with §5.4 first
            - "-c"
            - "jit=off"
            - "-c"
            - "shared_preload_libraries=pg_stat_statements"
            - "-c"
            - "pg_stat_statements.track_utility=off"
            - "-c"
            - "track_io_timing=on"
            - "-c"
            - "track_wal_io_timing=on"
            - "-c"
            - "log_min_duration_statement=500ms"
            - "-c"
            - "log_temp_files=0"
            - "-c"
            - "log_lock_waits=on"
          resources:
            requests: {cpu: 250m, memory: 1Gi}
            limits: {memory: 1Gi}
          volumeMounts:
            - {name: postgres-storage, mountPath: /var/lib/postgresql}
            - {name: dshm, mountPath: /dev/shm}
          startupProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 120          # 10 min for crash recovery (REL-03)
          livenessProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 4
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 2
      volumes:
        - name: postgres-storage
          persistentVolumeClaim: {claimName: postgres-pvc}
        - name: dshm
          emptyDir: {medium: Memory, sizeLimit: 256Mi}
```

After the restart, once:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- in database taskflow
SHOW shared_preload_libraries;  SHOW jit;  SHOW checkpoint_timeout;
```

Then add `--collector.stat_statements` to the exporter (§2.1).

### 5.6 Verification and rollback

- Logs show `database system is ready to accept connections`; the backend's
  readiness is UP; `pg_stat_statements` returns rows after a few minutes of use.
- Over the next days: `pg_stat_checkpointer.num_requested` stays near 0 (checkpoints
  are timed, not WAL-forced); no temp-file log lines (else raise `work_mem` for
  the offending query, not globally); slow-query log is quiet or points at the
  queries to index.
- Rollback: `git revert`; Postgres restarts with the previous arguments. The
  extension can stay installed.

### 5.7 If CloudNativePG comes first (REL-02)

The same tuning maps to `spec.postgresql.parameters` (values as strings).
CNPG manages `shared_preload_libraries` itself and preloads
`pg_stat_statements` automatically; use the `proxmox-csi-db` StorageClass in
`spec.storage.storageClass` and drop the probe changes (CNPG manages its own
probes and shutdown).

---

## 6. Combined rollout

| Step | Change | Gate before the next step |
|---|---|---|
| 0 | Envoy scrape, exporter collectors (without `stat_statements`), baseline queries, `pg_test_fsync`/`pg_test_timing`, pgbench A/B off-hours, StorageClass benchmark | Baseline saved |
| 1 | PriorityClass | Exists |
| 2 | PERF-04 Postgres change + `CREATE EXTENSION` + exporter `stat_statements` | Postgres healthy for 24 h; statement stats flowing |
| 3 | PERF-03 Cilium values → Envoy restart → workload restarts | `BandwidthManager: EDT with BPF [BBR]`; Envoy p95 not worse |
| 4 | PERF-02 `taskflow` (LimitRange + Deployments in one commit) | QoS/priorities as expected; no throttling; backend rollout completes |
| 5 | PERF-02 platform HelmReleases | Node CPU requests < 50 %; no new OOMs |
| 6 | Re-run §2 after a week; tighten requests to the new p95 | — |
| later | Move Postgres to `proxmox-csi-db` with the CNPG migration (REL-02) | Restore drill passed |
