# Falco Runtime Security: GitOps & Monitoring Guide

This document covers the installation, architecture, Kubernetes-native integration, and monitoring configuration for **Falco** in the TaskFlow homelab cluster. It includes the full root-cause analysis of the Grafana dashboard compatibility issue resolved in this session.

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
                                  +---------+---------+
                                            | (Internal gRPC)
                                            v
                                  +-------------------+
                                  |   Falcosidekick   | (Routes alerts)
                                  +----+-----------+--+
                                       |           |
       (Directly writes wgpolicyk8s.io |           | (Prometheus Scrape: Port 8765)
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
Falco pods require high privileges to inspect kernel syscalls. We exempt the namespace from any restrictive Pod Security Admissions:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

### Helm Repository (`gitops/infrastructure/controllers/falco/repository.yaml`)
Defines the official Falco Helm chart repository source:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: falco
  namespace: falco
spec:
  interval: 24h
  url: https://falcosecurity.github.io/charts
```

### Helm Release (`gitops/infrastructure/controllers/falco/release.yaml`)
Configures the Falco DaemonSet and Falcosidekick with custom homelab-specific values:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: falco
  namespace: falco
spec:
  interval: 30m
  chart:
    spec:
      chart: falco
      version: 9.2.1
      sourceRef:
        kind: HelmRepository
        name: falco
        namespace: falco
      interval: 12h
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
      config:
        policyreport:
          enabled: true
          minimumpriority: "notice"
```

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

> **Why `jobLabel: app.kubernetes.io/name` matters:** Without it, VictoriaMetrics auto-generates the `job` label as `namespace/name` of the scrape resource (e.g. `monitoring/falco-metrics`). The provisioned dashboard selects Falco's metrics by name and does not filter on `job`, but a stable `job="falco"` keeps ad-hoc and alert queries such as `up{job="falco"}` predictable. This was fixed in commit `8fb3fc2`.

---

## 3. Dashboard Compatibility: Root Cause Analysis

This section documents the "no data" problem diagnosed in this session.

### The Symptom
After deploying Falco with `metrics.enabled: true` and confirming that VictoriaMetrics was scraping the `/metrics` endpoint successfully (metrics appeared in VM UI), Grafana Dashboard **11914** showed **all panels empty** — "No data" on every query.

### The Investigation

**Step 1 — Verify scraping works:**
```promql
# This query returned results, proving metrics arrive in VictoriaMetrics
{job="falco"}
```

**Step 2 — Check what metrics Falco actually exposes:**
```bash
# Port-forward to a Falco pod and inspect the metrics endpoint
kubectl port-forward -n falco pod/falco-xxxxx 8765 &
curl -s localhost:8765 | grep -oP '^[^#]\S+' | head -20
```
This revealed that **Falco v0.44.1's built-in Prometheus endpoint** exposes metrics with the **`falcosecurity_`** prefix:
```
falcosecurity_falco_cpu_usage_ratio
falcosecurity_falco_memory_rss_bytes
falcosecurity_falco_memory_vsz_bytes
falcosecurity_falco_n_evts_total
falcosecurity_falco_outputs_queue_num_drops_total
falcosecurity_falco_rules_matches_total
falcosecurity_falco_version_info
falcosecurity_scap_engine_name_info
falcosecurity_scap_n_drops_buffer_total
falcosecurity_scap_n_drops_cpu_total
falcosecurity_scap_n_drops_full_threadtable_total
falcosecurity_scap_n_drops_scratch_map_total
falcosecurity_scap_n_drops_total
falcosecurity_scap_n_evts_total
```

**Step 3 — Check what Dashboard 11914 queries:**
Dashboard 11914 was built for **`falco-exporter`**, a separate (now deprecated) component that:
- Exposed metrics like `falco_events`, `falco_events_rate`, `falco_rules_count` — using the **`falco_`** prefix at the top level (no `falcosecurity_` namespace)
- Used different label structures (e.g. `k8s_pod_name` instead of `pod`, `k8s_ns_name` instead of `namespace`)

### Root Cause
**Grafana Dashboard ID 11914 queries metric names that do not exist in Falco's built-in Prometheus endpoint.** The dashboard was specifically designed for the deprecated `falco-exporter` sidecar, not for the native metrics that Falco 0.38+ ships by default. Since those metric names (`falco_events`, `falco_events_rate`, etc.) are never produced, every panel returns "No data."

### The Fix
The Falco Helm chart ships with a native Grafana dashboard that queries the correct `falcosecurity_*` metric names. The source JSON is located in the upstream chart at:

```
https://raw.githubusercontent.com/falcosecurity/charts/master/charts/falco/dashboards/falco-dashboard.json
```

A homelab-adapted copy is saved at **`gitops/monitoring/logging/dashboards/falco-official.json`** and provisioned through the `monitoring-logging` Flux Kustomization. It defaults to VictoriaMetrics, preserves the existing Falco dashboard UID, and uses native metrics available with the modern eBPF driver. See [Section 4](#4-importing-the-correct-grafana-dashboard) for access and optional manual-import instructions.

---

## 4. Importing the Correct Grafana Dashboard

### Step 1: Log in to Grafana
Navigate to **`https://grafana.jokelab.dev`** and log in.

### Step 2: Remove the Incompatible Dashboard
1. Go to **Dashboards → Browse**.
2. Find the imported dashboard (it may be named "Falco Hints" or "Falco Dashboard 11914").
3. Click it, then click **Dashboard settings (gear icon) → Remove Dashboard**.

### Step 3: Open the Provisioned Dashboard
The dashboard is generated as `ConfigMap/monitoring/falco-dashboard` with the
`grafana_dashboard: "1"` label and is placed in the **Security** Grafana folder.
After the GitOps changes are deployed, Grafana's
sidecar loads it automatically; open **Dashboards → Security → Falco**. Edit its JSON in Git
for persistent changes. The existing UID is retained to adopt the earlier
manual import instead of creating another Falco dashboard.

For a separate Grafana installation without this provisioning, manual import is
still possible:
1. Click **Dashboards → New → Import**.
2. Select **Upload dashboard JSON file** and pick `gitops/monitoring/logging/dashboards/falco-official.json` from this repository.
3. In the **Prometheus / VictoriaMetrics** drop-down, select the default **VictoriaMetrics** datasource.
4. Click **Import**.

### Dashboard Layout (18 visualizations, plus section headers)

#### Row 1: Events (3 pie charts + 3 time series)
| Panel | Type | Query |
|-------|------|-------|
| **Rules** | Pie chart | `sum by(rule_name) (increase_pure(falcosecurity_falco_rules_matches_total[$__range]))` (instant) |
| **Sources** | Pie chart | `sum by(source) (increase_pure(falcosecurity_falco_rules_matches_total[$__range]))` (instant) |
| **Priorities** | Pie chart | `sum by(priority) (increase_pure(falcosecurity_falco_rules_matches_total[$__range]))` (instant), numeric priority renamed to its name |
| **by Priority over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `priority` |
| **by Source over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `source` |
| **by Rule over time** | Time series | Same metric, `increase_pure(...[$__interval])`, grouped by `rule_name` |

`increase_pure()` (MetricsQL) is used because a rule's counter only appears after its first match: plain `increase()` in VictoriaMetrics can discard a large first value. The drop panels in row 2 use it for the same reason: a new Falco pod is a new series, and `increase()` hides 10 or more drops that happened before its first scrape (over-time panels also use `[$__interval]`, minimum 1 minute, so that every drop is counted in exactly one point). The trade-off is that a bar equal to a pod's whole running total can appear when the selected range starts before the stored data (14-day retention) or when the scrape labels change without a Falco restart. Falco exports `priority` as a number (`0` emergency, `1` alert, `2` critical, `3` error, `4` warning, `5` notice, `6` informational, `7` debug); the Priorities panels rename it.

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
The dashboard defines five template variables that become dropdown filters at the top. Namespace and pod select the Falco exporter deployment, not the namespace of each detected workload:

| Variable | Definition | Source |
|----------|-----------|--------|
| `$datasource` | Prometheus | Grafana datasource (defaults to VictoriaMetrics) |
| `$namespace` | `label_values(falcosecurity_falco_cpu_usage_ratio, namespace)` | Falco exporter namespaces |
| `$source` | `label_values(falcosecurity_falco_rules_matches_total, source)` | All event sources |
| `$priority` | Custom list `emergency : 0` … `debug : 7` | Falco priorities by name (the metric label is the number) |
| `$pod` | `label_values(falcosecurity_falco_cpu_usage_ratio{namespace=~"$namespace"}, pod)` | Falco exporter pods |

---

## 5. Complete Metrics Reference

These are the **actual** metrics that Falco 0.45.1 (chart 9.2.1, modern eBPF driver) exposes on the `/metrics` endpoint. Use these names in PromQL queries, alerting rules (`VMRules`), or custom Grafana panels.

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
| `version` | Falco semantic version | `0.45.1` |

---

## 6. Verification & Testing Cheatsheet

### Force Flux to sync changes
```bash
flux reconcile kustomization infra-controllers --with-source
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
# Runs a temporary Alpine container, writes below /usr/bin, sleeps for 5s, and auto-deletes
kubectl run falco-test --image=alpine --restart=Never -i --rm -- sh -c "touch /usr/bin/falco-test-trigger && sleep 5"
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

---

## 7. Git History (This Session)

| Commit | Description |
|--------|-------------|
| `9bdf97d` | feat: install Falco runtime security agent via Flux (modern eBPF) |
| `b544a7f` | feat: integrate Falco with Policy Reporter UI via Falcosidekick |
| `d6700a9` | fix: correct Falcosidekick webhook configuration path in Helm values |
| `71f8949` | refactor: switch Falco integration to native PolicyReport CRDs |
| `bfa2fc4` | docs: document Falco GitOps architecture & Grafana monitoring guide |
| `019c9e3` | fix: align VictoriaMetrics scrape config with Falco's service port 8765 |
| `8fb3fc2` | fix: set jobLabel: app.kubernetes.io/name on Falco scrape to match Grafana dashboard |

For the full diff of this session, run:
```bash
git log --oneline 9bdf97d..8fb3fc2
```
