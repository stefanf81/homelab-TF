# Trivy Security Scanning (Flux GitOps)

This document describes how the Trivy Operator is installed and configured in this
repository via Flux CD, what scanners and compliance checks are enabled, and how the
results are surfaced in Grafana and the Policy Reporter dashboard.

- **Trivy Operator** — a Kubernetes operator that continuously scans workloads for
  vulnerabilities and misconfigurations, producing `aquasecurity.github.io` CRDs.
- **Policy Reporter** — the Trivy results are surfaced in `https://kyverno.jokelab.dev`
  through the `trivy-operator-polr-adapter` (see §6 and `docs/KYVERNO_POLICY_ENGINE.md`).
- **Grafana** — operator and scan metrics are scraped by VictoriaMetrics and shown on the
  `Trivy Operator` dashboard (see §7).

Everything is managed through Git; nothing is applied imperatively.

---

## 1. Architecture in this repo (file map)

```
gitops/
├── infrastructure/controllers/
│   ├── trivy-operator/               # Trivy Operator (own cluster Kustomization)
│   │   ├── namespace.yaml            # trivy-system ns
│   │   ├── repository.yaml           # HelmRepository aqua @ https://aquasecurity.github.io/helm-charts
│   │   ├── release.yaml             # HelmRelease trivy-operator v0.36.0, scanners + compliance (own kustomization)
│   │   └── kustomization.yaml
│   └── policy-reporter/              # Policy Reporter + adapter (see docs/KYVERNO_POLICY_ENGINE.md)
│       ├── trivy-adapter-repository.yaml  # HelmRepository trivy-operator-polr-adapter
│       ├── trivy-adapter-release.yaml     # HelmRelease trivy-operator-polr-adapter v0.11.5
│       └── ...
└── monitoring/
    ├── app/vmservicescrapes.yaml     # VMServiceScrape trivy-operator (metrics → VictoriaMetrics)
    └── logging/trivy-dashboard.yaml  # Grafana "Trivy Operator" dashboard (ConfigMap)
```

- `trivy-operator/` is reconciled by its **own** cluster Kustomization (`trivy-operator`)
  that `dependsOn: infra-controllers` (so the Flux `HelmRelease` machinery and namespace
  exist first). It is **not** part of `infrastructure/controllers/kustomization.yaml`.
- The adapter lives under `policy-reporter/` and is reconciled by the `policy-reporter`
  Kustomization.

---

## 2. Chart & version

- Chart: `aqua/trivy-operator` from `https://aquasecurity.github.io/helm-charts`
- Pinned: **0.36.0**
- `install.crds: CreateReplace` / `upgrade.crds: CreateReplace` — the chart **owns** the
  Trivy CRDs (they are not provided by Kyverno).

---

## 3. Enabled scanners

All scanners run as short-lived Kubernetes Jobs triggered by the operator watching
workloads (and on a schedule for compliance). The `targetNamespaces` is empty = **all
namespaces**.

| Scanner                        | Value in `operator.*`                | Report CR(s) produced |
|--------------------------------|--------------------------------------|------------------------|
| Vulnerability (image CVEs)     | `vulnerabilityScannerEnabled: true`   | `VulnerabilityReport`/`ClusterVulnerabilityReport` (namespaced per‑image) |
| SBOM generation               | `sbomGenerationEnabled: true`         | `SBOMReport` |
| Config audit (misconfiguration) | `configAuditScannerEnabled: true` (+ `configAuditScannerScanOnlyCurrentRevisions: true`) | `ConfigAuditReport`/`ClusterConfigAuditReport` |
| RBAC assessment               | `rbacAssessmentScannerEnabled: true`  | `RbacAssessmentReport`/`ClusterRbacAssessmentReport` |
| Infra assessment              | `infraAssessmentScannerEnabled: true` | `InfraAssessmentReport`/`ClusterInfraAssessmentReport` |
| Exposed secrets               | `exposedSecretScannerEnabled: true`   | `ExposedSecretReport`/`ClusterExposedSecretReport` |
| Cluster compliance            | `clusterComplianceEnabled: true`      | `ClusterComplianceReport` (per spec, on a cron) |

Additional operator values:

- `builtInTrivyServer: true` — the operator runs an in‑cluster Trivy server (StatefulSet
  `trivy-server`) so scan jobs share one cache/DB instead of each downloading it.
- `reportRecordFailedChecksOnly: true` — only **failing** checks are written to reports
  (passes are dropped), keeping the report CRs small.
- Scan concurrency is deliberately capped for the single‑node homelab:
  `scanJobsConcurrentLimit: 1`, `concurrentScanJobsLimit: 1`, `scanNodeCollectorLimit: 1`,
  `scanJobTimeout: 5m`.

---

## 4. Compliance reports

Cluster compliance targets are defined under `compliance:` in the HelmRelease:

- `reportType: all` — generate both the summary and the per‑check **detail** in each
  `ClusterComplianceReport`. **This must stay `all`** for the Policy Reporter adapter to
  create reports from it (a `summary` report has no per‑check results to adapt). If you
  switch back to `summary`, compliance silently disappears from Policy Reporter.
- `cron: "0 */6 * * *"` — recomputes every 6 hours.
- `failEntriesLimit: 10` — at most 10 failing entries recorded per check.
- `specs` (all enabled):

  | Spec | Description |
  |------|-------------|
  | `k8s-nsa-1.0` | NSA Kubernetes Hardening Guide |
  | `k8s-cis-1.23` | CIS Kubernetes Benchmark v1.23 |
  | `k8s-pss-baseline-0.1` | Pod Security Standards baseline |
  | `k8s-pss-restricted-0.1` | Pod Security Standards restricted |

Each spec becomes a `ClusterComplianceReport` (e.g. `k8s-cis-1.23`) that the operator
recomputes on the cron; the `ClusterComplianceReport` CRDs are owned by the Helm release
and appear under the release's owned resources.

---

## 5. Metrics & Grafana dashboard

### Scraping (VictoriaMetrics)

A `VMServiceScrape` in `gitops/monitoring/app/vmservicescrapes.yaml` scrapes the operator's
`/metrics` endpoint:

```yaml
# (name: trivy-operator, namespace: monitoring)
spec:
  jobLabel: app.kubernetes.io/name          # job="trivy-operator" (not monitoring/trivy-operator)
  namespaceSelector:
    matchNames: [ trivy-system ]
  selector:
    matchLabels:
      app.kubernetes.io/instance: trivy-operator
      app.kubernetes.io/name: trivy-operator
  endpoints:
    - port: metrics
      path: /metrics
      interval: 60s
      scheme: http
```

The `jobLabel: app.kubernetes.io/name` is **critical** — it sets `job="trivy-operator"`
instead of the auto-generated `namespace/name`, so the dashboard's PromQL that references
`trivy_image_vulnerabilities` etc. works without a `job` filter (same pattern as the Falco
scrape).

The exported metrics include (main ones):

- `trivy_image_vulnerabilities{severity, repository, tag, image_digest, namespace, ...}`
- `trivy_resource_configaudits{severity, success, ...}`
- `trivy_role_rbacassessments` / `trivy_clusterrole_clusterrbacassessments`
- `trivy_image_exposedsecrets{severity, ...}`
- `trivy_resource_infraassessments{missing, severity, success, ...}`
- `trivy_cluster_compliance{status="Pass|Fail", ...}` (from `ClusterComplianceReport`s)

### Dashboard (Grafana)

`gitops/monitoring/logging/trivy-dashboard.yaml` deploys the **"Trivy Operator"**
dashboard (ConfigMap `trivy-dashboard`, label `grafana_dashboard: "1"` → Grafana via
Grafana Sidecar). It is based on Aqua's public dashboard **17813** but rewritten with the
`VictoriaMetrics` datasource UID and a `$namespace` template variable (`label_values(
trivy_image_vulnerabilities, namespace)`).

Panels (top to bottom):

1. **Security Issues by Type** (stat) — vulnerabilities, misconfiguration, RBAC, exposed
   secrets, infra‑assessment counts.
2. **Vulnerabilities by Severity** (timeseries, `sum by (severity)`).
3. **Vulnerabilities by Namespace** (top‑15).
4. **Vulnerabilities by Image** (table, grouped by `image_repository`, `image_tag`,
   `namespace`, `severity`).
5. **Misconfiguration by Severity** (`sum by (severity)` over `trivy_resource_configaudits`).
6. Misconfiguration by namespace, RBAC severities, exposed‑secret by namespace,
   compliance Pass/Fail (from `trivy_cluster_compliance`), plus operator health panels
   (reconcile errors, `workqueue_*`/`controller_runtime_*` based).

Open it in Grafana under **Dashboards → Trivy Operator**. (Datasource UID in the JSON is
`VictoriaMetrics` — matches the provisioned stack.)

---

## 6. Policy Reporter integration (Trivy → `PolicyReport`)

Trivy does **not** natively write `wgpolicyk8s.io` `PolicyReport`/`ClusterPolicyReport`
objects; the Policy Reporter UI reads those to build its report list. The
**`trivy-operator-polr-adapter`** bridges the gap:

- Chart `trivy-operator-polr-adapter` v0.11.5 (`https://fjogeleit.github.io/trivy-operator-polr-adapter`,
  HelmRelease `trivy-operator-polr-adapter` in `policy-reporter` namespace).
- `useWatchList: true`, and the `crds.install: false` gate keeps the `wgpolicyk8s.io` CRDs
  owned by Kyverno (which already installs them).
- All source adapters enabled: `vulnerabilityReports`, `configAuditReports`,
  `rbacAssessmentReports`, `exposedSecretReports`, `complianceReports`,
  `infraAssessmentReports`, `clusterInfraAssessmentReports`, `clusterVulnerabilityReports`.

The adapter writes named reports (e.g. `trivy-nginx` in each namespace, or cluster-level
`trivy-<name>`) carrying `trivy-operator.source` labels (e.g.
`trivy-operator.source=VulnerabilityReport`) so the UI can group them under its configured
**sources**.

Policy Reporter's own HelmRelease (`policy-reporter`, v3.10.0) additionally has:

- `plugin.trivy.enabled: true` — lets Policy Reporter enrich the reports / metrics with
  severity data (so the `policy_report_info`/`policy_report_result` metrics and the
  `Trivy …` UI sources get meaningful colors & filtering).
- `ui.sources` lists six Trivy sources (each `type: severity`, excluding `pass`/`skip`):

  | Source name | Maps to adapter‑produced report |
  |-------------|-------------------------------|
  | `Trivy Vulnerability` | `VulnerabilityReport` |
  | `Trivy ConfigAudit` | `ClusterConfigAuditReport` / `ConfigAuditReport` |
  | `Trivy RbacAssessment` | `RbacAssessmentReport` |
  | `Trivy ExposedSecrets` | `ExposedSecretReport` |
  | `Trivy Compliance` | `ClusterComplianceReport` (needs `compliance.reportType: all`) |
  | `Trivy InfraAssessment` | `InfraAssessmentReport` |

So in the dashboard UI (`https://kyverno.jokelab.dev`) you get both the standard **Kyverno**
and **Falco** lists and the **Trivy** ones, all under their own source tabs.

---

## 7. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| No `VulnerabilityReport` for a workload | Trivy uses **sbom scanning** (`sbomGenerationEnabled`) + `vulnerabilityScannerScanOnlyCurrentRevisions: true` for current revision only; images are scanned when a workload appears or on each `interval`. Check `kubectl get jobs -A` for pending scans, or the `trivy-operator` operator logs. |
| ScanJobs / cluster-node collector stuck | Single node + scans capped; `scanJobsConcurrentLimit` and `concurrentScanJobsLimit` are both `1`, and `scanNodeCollectorLimit: 1`. Scale down if slow or bump limits, then watch `kubectl -n trivy-system get pods`. |
| Compliance report created but `ClusterComplianceReport` status shows `summary` / no detail | Check `trivy-operator` HelmRelease `compliance.reportType`: must be **`all`** for the adapter to work (see §4). Only reports with `reportType: all` carry per‑check results. |
| No `trivy_*` metrics in VictoriaMetrics | Verify the `VMServiceScrape` (see `monitoring/app/vmservicescrapes.yaml`) matches the operator's labels, that `jobLabel` is `app.kubernetes.io/name`, and that `job="trivy-operator"` shows healthy in vmsingle/VMAggregator. |
| Grafana dashboard empty | Check the dashboard's datasource is the VictoriaMetrics `UID` (`VictoriaMetrics`) and the `$namespace` template variable resolves; the metrics only appear for namespaces with scans (the `trivy_*` metrics are emitted lazily by the operator, not continuously). |
| `trivy-operator-polr-adapter` pods crash-loop | Adapter needs the `wgpolicyk8s.io` CRDs installed (Kyverno provides them). Ensure `infra-controllers`/`kyverno` is healthy before the `policy-reporter` Kustomization. |
| Compliance reports appear in Grafana but not in Policy Reporter | Again typically `reportType: summary`. Flip to `all` in `compliance:` and re-reconcile; existing `ClusterComplianceReport`s will regenerate on next cron slot. |

---

## 8. Useful commands

```bash
# Helm release / reconciled state
kubectl -n trivy-system get helmrelease trivy-operator
kubectl -n trivy-system get pods

# Reports
kubectl get vulnerabilityreports,configauditreports,rbacassessmentreports,exposedsecretreports -A
kubectl get clustercompliancereport

# Adapter-produced PolicyReports for Trivy sources
kubectl get clusterpolicyreports --all-namespaces | grep trivy

# Scan jobs (created in the workload's namespace, not trivy-system)
kubectl get jobs -A
```

Scaling/limits: requests 100m/128Mi, limits 500m/512Mi for the operator pod; the scan jobs
run at `250m/512Mi` request / `1/2Gi` limit; the Trivy server StatefulSet also runs limited.
