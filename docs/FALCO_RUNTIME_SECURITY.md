# Falco Runtime Security: GitOps & Monitoring Guide

This document covers the installation, architecture, Kubernetes-native integration, and monitoring configuration for **Falco** in the TaskFlow homelab cluster.

---

## 1. Architecture Overview

In this cluster, Falco is deployed as a cluster-wide runtime security system using a low-overhead, highly integrated **GitOps and Kubernetes-Native design**:

```text
                                  +-------------------+
                                  |   Linux Kernel    | (Ubuntu 26.04)
                                  +---------+---------+
                                            | (modern eBPF probe)
                                            v
                                  +-------------------+
                                  |  Falco DaemonSet  | (Detects syscall violations)
                                  +----+-----------+--+
                                       |           |
                       (Internal gRPC) |           | (Prometheus scrape of Falco's
                                       v           |  /metrics: port 8765)
                          +------------+---+       |
                          |  Falcosidekick |       |
                          | (Routes alerts)|       |
                          +------------+---+       |
       (Directly writes wgpolicyk8s.io |           |
        PolicyReport Custom Resources) |           |
                                       v           v
                          +------------+---+   +---+------------+
                          |  Kubernetes API|   | VictoriaMetrics| (via VMServiceScrape)
                          +------------+---+   +---+------------+
                                       |           |
                                       v           v
                          +------------+---+   +---+------------+
                          |Policy Reporter |   |  Grafana UI    |
                          |  Dashboard     |   |                |
                          +----------------+   +----------------+
```

### Key Integrations
1. **Runtime Protection:** Falco hooks into the Linux kernel using a **modern eBPF probe** to capture security-relevant system calls.
2. **Kubernetes-Native Audit (Policy Reporter):** When an alert triggers, **Falcosidekick** generates a standard CNCF `PolicyReport` (wgpolicyk8s.io) directly in the Kubernetes API. The **Policy Reporter UI** observes these reports dynamically and renders them under `https://kyverno.jokelab.dev`.
3. **Time-Series Monitoring (Grafana):** Falco exposes Prometheus metrics on port `8765` (port name `metrics`). **VictoriaMetrics** scrapes them using a custom `VMServiceScrape` and routes them to **Grafana** (`https://grafana.jokelab.dev`).

---

## 2. GitOps Configuration (Flux CD)

All resources are version-controlled and automatically reconciled by Flux CD.

### Namespace (`gitops/infrastructure/controllers/falco/namespace.yaml`)
Falco pods require high privileges to inspect kernel syscalls, so the namespace enforces the `privileged` Pod Security level; warn and audit stay `restricted`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
```

### Chart source (`gitops/infrastructure/controllers/falco/repository.yaml`)
The official Falco chart, pulled as an OCI artifact. The version is pinned here
(`ref.tag` + `ref.digest`), not in the HelmRelease. Do not go below chart 9.2.0 (Falco 0.45.0):
Falco 0.44.1 crashes on the node's kernel 7.0 (see the comment in the file):
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: falco
  namespace: falco
spec:
  interval: 24h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 9.2.2
    digest: sha256:08cd4fd501f12b33c8220886a595bb0cc6a6b5bf9713b5fad9e3381148409d6f
  url: oci://ghcr.io/falcosecurity/charts/falco
```

### Helm Release (`gitops/infrastructure/controllers/falco/release.yaml`, excerpt — omits `customRules.homelab-api-clients.yaml`)
Configures the Falco DaemonSet and single-replica Falcosidekick with custom homelab-specific values:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: falco
  namespace: falco
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: falco
  install:
    createNamespace: true
    crds: CreateReplace
  upgrade:
    crds: CreateReplace
  values:
    # Use modern eBPF driver which is fully supported on modern kernels (Ubuntu 26.04)
    driver:
      kind: modern_ebpf

    # Memory is capped; CPU is not: a throttled Falco falls behind the syscall stream
    # and drops events.
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        memory: "1024Mi"

    # Expose Prometheus metrics (Port 8765 / port name "metrics")
    metrics:
      enabled: true

    # Enable Falcosidekick and configure native PolicyReport creation
    falcosidekick:
      enabled: true
      replicaCount: 1
      image:
        tag: 2.35.1
      resources:
        requests:
          cpu: 10m
          memory: 64Mi
        limits:
          memory: 256Mi
      config:
        policyreport:
          enabled: true
          minimumpriority: "notice"
          maxevents: 300
          prunebypriority: true
```

### Privileges, priority and rules source

Not shown in the excerpt above:

* **No `privileged: true`.** `containerSecurityContext` adds `BPF`, `SYS_RESOURCE`,
  `PERFMON` and `SYS_PTRACE` and sets the AppArmor profile to `Unconfined` (the
  chart's `leastPrivileged` capability list, written with the `appArmorProfile`
  field). The host mounts remain, so the namespace stays PSA `privileged`.
* **`podPriorityClassName: system-cluster-critical`**: scheduled first and exempt
  from kubelet eviction, without the OOM-killer immunity of `system-node-critical`.
* **Rules come from the image, not from falcoctl.** `falcoctl.artifact.install` and
  `.follow` are off; Falco loads the `falco_rules.yaml` and the `container` plugin
  baked into its image (for 0.45.2 byte-identical to `falco-rules` 5.2.0 and
  container plugin 0.7.6, the artifacts falcoctl downloaded) plus `customRules`.
  A rules update is a chart/image bump in Git. To run a newer ruleset than the image ships, re-enable
  `falcoctl.artifact.install` only, with an exact ref and digest
  (`falcoctl.config.artifact.install.refs: [falco-rules:5.2.0@sha256:…]`) and
  `falcoctl.artifact.install.resources`.

Check after a change: `kubectl -n falco logs ds/falco -c falco | grep -iE 'opening|loaded|rules'`
shows the modern eBPF probe opening and the rule files loading, and
`kubectl -n falco exec ds/falco -c falco -- cat /proc/1/status | grep CapEff` is
no longer `000001ffffffffff`.

### API-client noise tuning

`customRules.homelab-api-clients.yaml` in the HelmRelease appends an exception to
**Contact K8S API Server From Container** for known controller clients. Each entry
matches the exact namespace, image repository and executable observed in Falco
events. This avoids thousands of routine API-contact notices crowding the bounded
PolicyReports without exempting whole namespaces or disabling the rule.

Unexpected images, namespaces and executables (including shells inside an allowed
controller image) remain subject to the rule. All other Falco detections are unchanged.
When a controller changes its registry or executable, review the new events before
updating the allowlist; do not replace it with a namespace-wide exclusion.

### VMServiceScrape (`gitops/monitoring/app/vmservicescrapes.yaml`)

VictoriaMetrics operator automatically discovers `VMServiceScrape` resources. The Falco scrape config is:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: falco-metrics
  namespace: monitoring
spec:
  jobLabel: app.kubernetes.io/name      # <-- CRITICAL: Sets job="falco" instead of job="monitoring/falco-metrics"
  namespaceSelector:
    matchNames:
      - falco
  selector:
    matchLabels:
      app.kubernetes.io/name: falco     # Matches Falco's metrics Service labels
  endpoints:
    - port: metrics                     # Falco metrics service port name (TCP 8765)
      path: /metrics
      interval: 30s
      scheme: http
```

> **Why `jobLabel: app.kubernetes.io/name` matters:** Without it, VictoriaMetrics auto-generates the `job` label as `namespace/name` of the scrape resource (e.g. `monitoring/falco-metrics`). The provisioned dashboard selects Falco's metrics by name and does not filter on `job`, but a stable `job="falco"` keeps ad-hoc and alert queries such as `up{job="falco"}` predictable.

---

## 3. Grafana Dashboard

The dashboard is a homelab-adapted copy of the Falco chart's own dashboard
(`charts/falco/dashboards/falco-dashboard.json` upstream), kept at
`gitops/monitoring/logging/dashboards/falco-official.json` and provisioned by the
`monitoring-logging` Kustomization as `ConfigMap/monitoring/falco-dashboard` (label
`grafana_dashboard: "1"`). Grafana's sidecar loads it into the **Security** folder: open
**Dashboards → Security → Falco** at `https://grafana.jokelab.dev`. Edit the JSON in Git for
persistent changes; provenance and update steps are in
`gitops/monitoring/logging/dashboards/SOURCE.md`.

> **Do not import Grafana dashboard 11914.** It was built for the deprecated
> `falco-exporter` (`falco_events`, `falco_rules_count`, `k8s_pod_name` labels) and shows
> "No data" on every panel against Falco's built-in endpoint, which exposes
> `falcosecurity_*` metrics (§4). That mismatch was the cause of the empty dashboard when
> Falco was first deployed.

### Dashboard Layout (18 visualizations, plus section headers)

#### Row 1: Events (3 pie charts + 3 time series)
| Panel | Type | Query |
|-------|------|-------|
| **Rules** | Pie chart | `sum by(rule_name) ((increase_pure(m[$__range]) unless last_over_time(m[1h] offset $__range)) or increase(m[$__range]))` with `m` = `falcosecurity_falco_rules_matches_total` (instant) |
| **Sources** | Pie chart | Same expression, `sum by(source)` (instant) |
| **Priorities** | Pie chart | Same expression, `sum by(priority)` (instant), numeric priority renamed to its name |
| **by Priority over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `priority` |
| **by Source over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `source` |
| **by Rule over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `rule_name` |

`increase_pure()` (MetricsQL) is used because a rule's counter only appears after its first match: plain `increase()` in VictoriaMetrics can discard a large first value. The pie charts apply it only to series born inside the range and use plain `increase()` for series that have samples in the hour before it, so a scrape gap at the window start does not replay a lifetime total. The drop panels in row 2 use it for the same reason: a new Falco pod is a new series, and `increase()` hides 10 or more drops that happened before its first scrape (over-time panels also use `[$__interval]`, minimum 1 minute, so that every drop is counted in exactly one point). The trade-off is that a bar equal to a pod's whole running total can appear when the selected range starts before the stored data (14-day retention) or when the scrape labels change without a Falco restart. Falco exports `priority` as a number (`0` emergency, `1` alert, `2` critical, `3` error, `4` warning, `5` notice, `6` informational, `7` debug); the Priorities panels rename it.

#### Row 2: Performances (10 time series)
| Panel | Type | Primary Query |
|-------|------|------|
| **Scap events/s by instance** | Time series | `sum by(pod) (rate(falcosecurity_scap_n_evts_total[...]))` |
| **Memory RSS** | Time series | `avg by(pod) (falcosecurity_falco_memory_rss_bytes)` |
| **Memory VSZ** | Time series | `avg by(pod) (falcosecurity_falco_memory_vsz_bytes)` |
| **CPU** | Time series | `sum by(pod) (rate(container_cpu_usage_seconds_total{container="falco",metrics_path="/metrics/cadvisor"}[...]))` (cAdvisor, share of one core) |
| **Scap Drops total** | Time series | `sum by(pod) (increase_pure(falcosecurity_scap_n_drops_total[$__interval]))` |
| **Queue Drops** | Time series | `sum by(pod) (increase_pure(falcosecurity_falco_outputs_queue_num_drops_total[$__interval]))` |
| **Scap Drops Buffer** | Time series | `sum by(pod, drop) (increase_pure(falcosecurity_scap_n_drops_buffer_total{dir="exit"}[$__interval]))`, all exit categories |
| **Scap Drops Auxmap Pool Full** | Time series | `sum by(pod) (increase_pure(falcosecurity_scap_n_drops_auxmap_pool_full_total[$__interval]))` |
| **Scap Drops Full Threadtable** | Time series | `sum by(pod) (increase_pure(falcosecurity_scap_n_drops_full_threadtable_total[$__interval]))` |
| **Scap Drops Scratch Map** | Time series | `sum by(pod) (increase_pure(falcosecurity_scap_n_drops_scratch_map_total[$__interval]))` |

The upstream "Scap Drops Buffer Enter" panel was removed: Falco 0.45 exports only the exit categories and emits the `dir="enter"` series as constant zeros for compatibility. The driver (libs 0.26.0) still counts drops of the open and connect enter events (TOCTOU mitigation) in `falcosecurity_scap_n_drops_total`, but Falco's exporter discards those counters, so Scap Drops total can exceed the sum of the categories.

#### Row 3: Fleet (2 pie charts)
| Panel | Type | Primary Query |
|-------|------|------|
| **Versions** | Pie chart | `count by(version) (falcosecurity_falco_version_info)` (instant: the pods reporting at the end of the range) |
| **Engines** | Pie chart | `count by(engine_name) (falcosecurity_scap_engine_name_info)` (instant) |

### Dashboard Variables
The dashboard defines five template variables that become dropdown filters at the top. Namespace and pod select the Falco DaemonSet pods that export the metrics, not the namespace of each detected workload:

| Variable | Definition | Source |
|----------|-----------|--------|
| `$datasource` | Prometheus | Grafana datasource (defaults to VictoriaMetrics) |
| `$namespace` | `label_values(falcosecurity_falco_cpu_usage_ratio, namespace)` | Namespaces of the Falco pods |
| `$source` | `label_values(falcosecurity_falco_rules_matches_total{namespace=~"$namespace", pod=~"$pod"}, source)` | Event sources seen by the selected Falco pods |
| `$priority` | Custom list `emergency : 0` … `debug : 7` | Falco priorities by name (the metric label is the number) |
| `$pod` | `label_values(falcosecurity_falco_cpu_usage_ratio{namespace=~"$namespace"}, pod)` | Falco pods |

---

## 4. Complete Metrics Reference

These are the **actual** metrics that Falco 0.45.2 (chart 9.2.2, modern eBPF driver) exposes on the `/metrics` endpoint. Use these names in PromQL queries, alerting rules (`VMRules`), or custom Grafana panels.

### Alert & Rule Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_falco_rules_matches_total` | Counter | `pod`, `rule_name`, `source`, `priority`, `tag_*` | Number of times each rule has matched. **Primary metric** for alert-rate dashboards. A series only appears after the rule's first match. |
| `falcosecurity_falco_outputs_queue_num_drops_total` | Counter | `pod` | Number of events dropped from the outputs queue (alert delivery failures). |

### Performance & Resource Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_falco_cpu_usage_ratio` | Gauge | `pod` | CPU time as a ratio of one core (0.5 = half a core), averaged since the Falco process started, like `ps` %CPU. Not current usage; the dashboard uses cAdvisor instead. |
| `falcosecurity_falco_memory_rss_bytes` | Gauge | `pod` | Resident Set Size (physical RAM) of the Falco process. Always bytes on `/metrics`, whatever `convert_memory_to_mb` says. |
| `falcosecurity_falco_memory_vsz_bytes` | Gauge | `pod` | Virtual Memory Size of the Falco process. |

### Scap Engine Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_scap_n_evts_total` | Counter | `pod` | Total kernel events captured by the scap engine. |
| `falcosecurity_scap_n_drops_total` | Counter | `pod` | Total number of events dropped. |
| `falcosecurity_scap_n_drops_buffer_total` | Counter | `pod`, `dir` (enter/exit), `drop` (category) | Buffer drops by category (clone_fork, execve, connect, open, dir_file, close, proc, other_interest) on `dir="exit"`. The `dir="enter"` series are constant zeros kept for compatibility; enter-event drops are counted only in `falcosecurity_scap_n_drops_total`. |
| `falcosecurity_scap_n_drops_auxmap_pool_full_total` | Counter | `pod` | Modern eBPF auxiliary-map pool exhaustion drops. |
| `falcosecurity_scap_n_drops_cpu_total` | Counter | `pod`, `cpu` | Per-CPU drops; only exported with `kernel_event_counters_per_cpu_enabled` (off by default, so not available here). |
| `falcosecurity_scap_n_drops_full_threadtable_total` | Counter | `pod` | Threads that could not be added to the thread table because it was full (see `thread_table_size`); their events are still processed but lack process and container context. |
| `falcosecurity_scap_n_drops_scratch_map_total` | Counter | `pod` | With modern eBPF: events dropped because they exceeded the maximum event size. |

### Info Metrics (constant values, useful for fleet overview)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_falco_version_info` | Gauge | `version` | Falco version label (value is always 1). |
| `falcosecurity_scap_engine_name_info` | Gauge | `engine_name` | Scap engine name — should be `modern_bpf` (value is always 1). |

### Label Reference

| Label | Description | Example |
|-------|-------------|---------|
| `rule_name` | Name of the Falco rule that triggered | `Terminal shell in container` |
| `source` | Event source | `syscall` |
| `priority` | Severity level as a number: `0` emergency, `1` alert, `2` critical, `3` error, `4` warning, `5` notice, `6` informational, `7` debug | `5` |
| `pod` | Falco pod identity (added by the scrape) | `falco-abc123` |
| `namespace` | Namespace of the Falco pod (added by the scrape), not of the offending container | `falco` |
| `dir` | Buffer drop direction (`enter` is always 0) | `exit` |
| `drop` | Buffer drop category | `clone_fork`, `execve`, `connect`, `open`, `dir_file`, `close`, `proc`, `other_interest` |
| `engine_name` | Scap engine type | `modern_bpf` |
| `version` | Falco semantic version | `0.45.2` |

---

## 5. Verification & Testing Cheatsheet

### Force Flux to sync changes
```bash
flux reconcile kustomization falco --with-source
flux reconcile kustomization monitoring-app --with-source
flux reconcile kustomization monitoring-logging --with-source   # Falco dashboard ConfigMap
```

### Check Falco logs
```bash
# Check Falco's system call detections
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=100

# Check Falcosidekick's PolicyReport generation
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=100
```

### Verify metrics are being scraped
```bash
# Port-forward to a Falco pod and inspect raw metrics
kubectl port-forward -n falco pod/falco-xxxxx 8765 &
curl -s localhost:8765 | head -30

# Or query VictoriaMetrics (VMSingle) directly through a port-forward
kubectl -n monitoring port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428:8428 &
curl -s 'http://localhost:8428/vmsingle/api/v1/query?query=falcosecurity_falco_rules_matches_total'
```

### Trigger a safe, successful security alert
```bash
# Runs a temporary Alpine container, writes below /usr/bin, sleeps for 5s, and auto-deletes.
# The image must carry an explicit tag: Kyverno's disallow-latest-tag policy denies untagged images.
kubectl run falco-test --image=alpine:3.24.4 --restart=Never -i --rm -- sh -c "touch /usr/bin/falco-test-trigger && sleep 5"
```

### Check created PolicyReport custom resources
```bash
kubectl get policyreports -n default
kubectl get policyreports -n taskflow

# View details of a specific report
kubectl get policyreport <name> -n <namespace> -o yaml
```

### Grafana dashboard verification
1. Open **`https://grafana.jokelab.dev`**
2. Open **Dashboards → Security → Falco** (provisioned from Git)
3. Set the time range to **Last 15 minutes**
4. The **Rules** pie chart should show at least one rule (e.g. `Terminal shell in container`)
5. The **Sources** pie chart should show `syscall`
6. The **Priorities** chart may show `notice` or `warning`
7. Performance panels (Memory, CPU, Scap events) should show non-zero data immediately, even without triggering alerts
