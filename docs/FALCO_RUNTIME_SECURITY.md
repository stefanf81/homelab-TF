# Falco Runtime Security: GitOps & Monitoring Guide

This document covers the installation, architecture, Kubernetes-native integration, and monitoring configuration for **Falco** in the TaskFlow homelab cluster. It includes the full root-cause analysis of the Grafana dashboard compatibility issue resolved in this session.

---

## 1. Architecture Overview

In this cluster, Falco is deployed as a cluster-wide runtime security system using a zero-overhead, highly integrated **GitOps and Kubernetes-Native design**:

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
      version: 9.1.0
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

    # Guard resource usage on a single-node homelab VM
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
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

> **Why `jobLabel: app.kubernetes.io/name` matters:** Without it, VictoriaMetrics auto-generates the `job` label as `namespace/name` of the scrape resource (e.g. `monitoring/falco-metrics`). The official Grafana dashboard's template variable `$pod` filters on `job="falco"`, so without this fix the dashboard would not find any time series. This was fixed in commit `8fb3fc2`.

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

A local copy is saved in this repository at **`docs/dashboards/falco-official.json`**. See [Section 4](#4-importing-the-correct-grafana-dashboard) for import instructions.

---

## 4. Importing the Correct Grafana Dashboard

### Step 1: Log in to Grafana
Navigate to **`https://grafana.jokelab.dev`** and log in.

### Step 2: Remove the Incompatible Dashboard
1. Go to **Dashboards → Browse**.
2. Find the imported dashboard (it may be named "Falco Hints" or "Falco Dashboard 11914").
3. Click it, then click **Dashboard settings (gear icon) → Remove Dashboard**.

### Step 3: Import the Official Dashboard
1. Click **Dashboards → New → Import**.
2. Select **Upload dashboard JSON file** and pick `docs/dashboards/falco-official.json` from this repository.
3. In the **Prometheus / VictoriaMetrics** drop-down, select the default **VictoriaMetrics** datasource.
4. Click **Import**.

### Dashboard Layout (18 panels, 3 rows)

#### Row 1: Events (3 pie charts + 3 time series)
| Panel | Type | Query |
|-------|------|-------|
| **Rules** | Pie chart | `sum by(rule_name) (increase(falcosecurity_falco_rules_matches_total[...]))` |
| **Sources** | Pie chart | `sum by(source) (increase(falcosecurity_falco_rules_matches_total[...]))` |
| **Priorities** | Pie chart | `sum by(priority) (increase(falcosecurity_falco_rules_matches_total[...]))` |
| **by Priority over time** | Time series | Same metric, grouped by `priority` over time |
| **by Source over time** | Time series | Same metric, grouped by `source` over time |
| **by Rule over time** | Time series | Same metric, grouped by `rule_name` over time |

#### Row 2: Performances (8 time series)
| Panel | Type | Primary Query |
|-------|------|------|
| **Scap events by instance over time** | Time series | `sum by(pod) (increase(falcosecurity_scap_n_evts_total[...]))` |
| **Memory RSS** | Time series | `avg by(pod) (falcosecurity_falco_memory_rss_bytes)` |
| **Memory VSZ** | Time series | `avg by(pod) (falcosecurity_falco_memory_vsz_bytes)` |
| **CPU** | Time series | `avg by(pod) (falcosecurity_falco_cpu_usage_ratio)` |
| **Scap Drops total** | Time series | `sum by(pod) (increase(falcosecurity_scap_n_drops_total[...]))` |
| **Queue Drops** | Time series | `sum by(pod) (increase(falcosecurity_falco_outputs_queue_num_drops_total[...]))` |
| **Scap Drops Buffer Enter** | Time series | Buffer drops by category (clone_fork, connect, dir_file, execve, open, other_interest) on enter path |
| **Scap Drops Buffer Exit** | Time series | Same categories on exit path |

#### Row 3: Fleet (5 panels)
| Panel | Type | Primary Query |
|-------|------|------|
| **Scap Drops CPU** | Time series | `sum by(pod) (increase(falcosecurity_scap_n_drops_cpu_total[...]))` |
| **Scap Drops Full Threadtable** | Time series | `sum by(pod) (increase(falcosecurity_scap_n_drops_full_threadtable_total[...]))` |
| **Scap Drops Scratch Map** | Time series | `sum by(pod) (increase(falcosecurity_scap_n_drops_scratch_map_total[...]))` |
| **Versions** | Pie chart | `count by(version) (falcosecurity_falco_version_info)` |
| **Engines** | Pie chart | `count by(engine_name) (falcosecurity_scap_engine_name_info)` |

### Dashboard Variables
The dashboard defines four template variables that become dropdown filters at the top:

| Variable | Definition | Source |
|----------|-----------|--------|
| `$datasource` | Prometheus | Grafana datasource (set to VictoriaMetrics on import) |
| `$source` | `label_values(falcosecurity_falco_rules_matches_total, source)` | All event sources |
| `$priority` | `label_values(falcosecurity_falco_rules_matches_total, priority)` | All alert priorities |
| `$pod` | `label_values(up{job="falco"}, instance)` | All Falco pod instances |

---

## 5. Complete Metrics Reference

These are the **actual** metrics that Falco 0.44.x exposes on the `/metrics` endpoint. Use these names in PromQL queries, alerting rules (`VMRules`), or custom Grafana panels.

### Alert & Rule Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_falco_rules_matches_total` | Counter | `rule_name`, `source`, `priority`, `pod`, `namespace`, `container_id` | Number of times each rule has matched. **Primary metric** for alert-rate dashboards. |
| `falcosecurity_falco_outputs_queue_num_drops_total` | Counter | `pod` | Number of events dropped from the outputs queue (alert delivery failures). |

### Performance & Resource Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_falco_n_evts_total` | Counter | `pod` | Total events processed internally by the Falco engine (before scap layer). |
| `falcosecurity_falco_cpu_usage_ratio` | Gauge | `pod` | CPU usage as a ratio of a core (0.5 = half a core). |
| `falcosecurity_falco_memory_rss_bytes` | Gauge | `pod`, `raw_name` | Resident Set Size (physical RAM) of the Falco process. |
| `falcosecurity_falco_memory_vsz_bytes` | Gauge | `pod`, `raw_name` | Virtual Memory Size of the Falco process. |

### Scap Engine Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `falcosecurity_scap_n_evts_total` | Counter | `pod` | Total kernel events captured by the scap engine. |
| `falcosecurity_scap_n_drops_total` | Counter | `pod` | Total number of events dropped. |
| `falcosecurity_scap_n_drops_buffer_total` | Counter | `pod`, `dir` (enter/exit), `drop` (category) | Buffer drops broken down by direction and category (clone_fork, connect, dir_file, execve, open, other_interest). |
| `falcosecurity_scap_n_drops_cpu_total` | Counter | `pod` | Events dropped due to CPU overloading. |
| `falcosecurity_scap_n_drops_full_threadtable_total` | Counter | `pod` | Events dropped because thread table is full. |
| `falcosecurity_scap_n_drops_scratch_map_total` | Counter | `pod` | Events dropped because scratch map is full. |

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
| `priority` | Severity level | `Warning`, `Notice`, `Error`, `Critical`, `Emergency` |
| `pod` | Falco pod identity | `falco-abc123` |
| `namespace` | Kubernetes namespace of the offending container | `taskflow` |
| `container_id` | Container that triggered the event | `abcdef123456` |
| `dir` | Buffer drop direction | `enter`, `exit` |
| `drop` | Buffer drop category | `clone_fork`, `connect`, `execve`, `open`, `dir_file`, `other_interest` |
| `engine_name` | Scap engine type | `modern_bpf` |
| `version` | Falco semantic version | `0.44.1` |

---

## 6. Verification & Testing Cheatsheet

### Force Flux to sync changes
```bash
flux reconcile kustomization infra-controllers --with-source
flux reconcile kustomization monitoring-app --with-source
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

# Or query VictoriaMetrics directly (replace with your VM select URL)
# From inside the cluster:
curl http://victoria-metrics-select.monitoring:8481/select/0/prometheus/api/v1/query?query=falcosecurity_falco_rules_matches_total
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
2. Navigate to the imported Falco dashboard
3. Set the time range to **Last 15 minutes**
4. The **Rules** pie chart should show at least one rule (e.g. `Terminal shell in container`)
5. The **Sources** pie chart should show `syscall`
6. The **Priorities** chart may show `Notice` or `Warning`
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
