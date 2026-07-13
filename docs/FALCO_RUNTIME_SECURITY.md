# Falco Runtime Security: GitOps & Monitoring Guide

This document covers the installation, architecture, Kubernetes-native integration, and monitoring configuration for **Falco** in the TaskFlow homelab cluster.

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
       (Directly writes wgpolicyk8s.io |           | (Prometheus Scrape: Port 14223)
        PolicyReport Custom Resources) |           |
                                       v           v
                          +------------+---+   +---+------------+
                          |  Kubernetes API|   | VictoriaMetrics| (via VMServiceScrape)
                          +------------+---+   +---+------------+
                                       |           |
                                       v           v
                          +------------+---+   +---+------------+
                          |Policy Reporter |   |  Grafana UI    | (Exposed subdomains)
                          |  Dashboard     |   |                |
                          +----------------+   +----------------+
```

### Key Integrations
1. **Runtime Protection:** Falco hooks into the Linux kernel using a **modern eBPF probe** to capture security-relevant system calls.
2. **Kubernetes-Native Audit (Policy Reporter):** When an alert triggers, **Falcosidekick** generates a standard CNCF `PolicyReport` (wgpolicyk8s.io) directly in the Kubernetes API. The **Policy Reporter UI** observes these reports dynamically and renders them under `https://kyverno.jokelab.dev`.
3. **Time-Series Monitoring (Grafana):** Falco exposes Prometheus metrics on port `14223`. **VictoriaMetrics** scrapes them using a custom `VMServiceScrape` and routes them to **Grafana** (`https://grafana.jokelab.dev`).

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

    # Expose Prometheus metrics (Port 14223)
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

---

## 3. Visualizing Falco in Grafana

Since we have enabled Falco metrics and deployed a matching `VMServiceScrape` resource, all runtime security statistics are automatically archived inside VictoriaMetrics. You can build charts or import official dashboards.

### Step 1: Log in to your Grafana Dashboard
Navigate to **`https://grafana.jokelab.dev`** and log in.
*(Admin credentials can be recovered from your SOPS-encrypted `grafana-secrets.yaml` or your Grafana instance administrator account).*

### Step 2: Import the Official Falco Dashboard
1. On the left sidebar, click the **Plus (+)** or **Dashboards** icon, and click **Import**.
2. Under **Import via grafana.com**, enter the official dashboard ID: **`11914`** (or **`13019`**).
3. Click **Load**.
4. In the **Prometheus / VictoriaMetrics** drop-down, select the default **VictoriaMetrics** datasource.
5. Click **Import**.

### What you will see:
* **Alert Feed & Severity:** Charts categorizing incidents by priority (Notice, Warning, Critical, Emergency).
* **Rules Triggered:** Panels displaying the most active rules (e.g., `Terminal shell in container`, `Write below binary dir`).
* **Source Attribution:** See which Namespaces, Pods, Containers, and Nodes are triggering the security alerts.
* **Operational Performance:** Graphs displaying CPU, memory footprint, and system call drop rates inside Falco's ring buffers.

---

## 4. Key Metrics Reference

You can use the following raw Prometheus metrics in your custom Grafana dashboards or VictoriaMetrics alerting rules (`VMRules`):

* `falco_alerts_total`: The total cumulative number of alerts triggered, partitioned by priority, rule, and host.
* `falco_events_total`: General count of all kernel syscall events processed by the Falco engine.
* `falco_watch_events_total`: Real-time system call event rates.
* `falco_cpu_usage_ratio`: CPU consumption of the Falco container.
* `falco_memory_usage_bytes`: RAM footprint of the Falco daemon.

---

## 5. Verification & Testing Cheatsheet

### Force Flux to sync changes
```bash
flux reconcile kustomization infra-controllers --with-source
```

### Check logs
```bash
# Check Falco's system call detections
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=100

# Check Falcosidekick's PolicyReport generation
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=100
```

### Trigger a safe, successful security alert
```bash
# Runs a temporary Alpine container, writes below /usr/bin, sleeps for 5s, and auto-deletes
kubectl run falco-test --image=alpine --restart=Never -i --rm -- sh -c "touch /usr/bin/falco-test-trigger && sleep 5"
```

### Check created Custom Resources inside Kubernetes
```bash
kubectl get policyreports -n default
kubectl get policyreports -n taskflow
```
