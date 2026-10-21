# Custom Grafana dashboards (app layer)

Provisioning model:

- `kustomization.yaml` generates one ConfigMap per dashboard from the JSON file
  next to it (`configMapGenerator`, `disableNameSuffixHash: true`).
- The Grafana sidecar discovers ConfigMaps labeled `grafana_dashboard: "1"` in
  the `monitoring` namespace and reloads Grafana after changes
  (`sidecar.dashboards` in `gitops/monitoring/platform/release.yaml`).
- The `grafana_folder` annotation places each dashboard in a Grafana folder
  (sidecar `folderAnnotation` + `provider.foldersFromFilesStructure`).
- ConfigMap names and dashboard UIDs are stable on purpose: the sidecar adopts
  the existing dashboard instead of creating a duplicate. Do not rename a
  ConfigMap or change a dashboard `uid` without a migration plan.
- Datasource references use template variables (`datasource` for
  VictoriaMetrics, `lokiDatasource` for Loki) so UIDs stay portable.
- Navigation tag, shared crosshair, annotations and drill-down links are
  described in `gitops/monitoring/logging/dashboards/SOURCE.md` ("Conventions
  shared by all dashboards"); they apply to the dashboards in this directory too.

| File | ConfigMap | Dashboard UID | Folder | Source |
|---|---|---|---|---|
| `abuseipdb-security.json` | `abuseipdb-security-dashboard` | `abuseipdb-security` | Security | In-repo original; see `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`. |
| `blocked-sources.json` | `blocked-sources-dashboard` | `blocked-sources` | Security | In-repo original; see below and `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`. |
| `taskflow-performance.json` | `taskflow-performance-dashboard` | `taskflow-performance` | Taskflow | In-repo original (backend JVM/HTTP/Hikari/PostgreSQL/Redis + pod/node/disk metrics). HTTP p95 needs `management.metrics.distribution.percentiles-histogram.http.server.requests=true` in the backend; the panel's mean and max series work without it. Backend CPU is shown against its request (no CPU limit since PERF-02). |
| `cert-manager.json` | `cert-manager-dashboard` | `cert-manager` | Platform | In-repo original (certificate expiry/readiness/renewal, ACME requests, controller sync errors). Metric names and labels checked against cert-manager v1.21.2 (`pkg/metrics`, `internal/collectors`). ACME latency is a summary metric (no histogram buckets), so the dashboard shows the mean per ACME action. A certificate that was never issued reports expiry 0; the expiry panels leave it out and the Not ready panels show it. |
| `kyverno.json` | `kyverno-dashboard` | `kyverno` | Security | In-repo original (policy results, admission requests/latency, rule readiness, controller health and resource use). Metric names and labels checked against Kyverno v1.19.1 (`pkg/metrics`, chart `metricsExposure`). Rule-info and policy-change metrics are exported by both the admission and background controllers, so those panels deduplicate (`max by (policy_type, policy_name, rule_name)`, `job="admission-controller"`). The chart's `metricsExposure` keys `kyverno_policy_results_total` and `kyverno_admission_requests_total` do not match Kyverno's instrument names (no `_total`), so `kyverno_policy_results_total` keeps `policy_namespace` and `resource_namespace`, and `kyverno_admission_requests_total` keeps `resource_namespace` (it has no `policy_namespace`); `kyverno_policy_execution_duration_seconds` keeps `policy_namespace` because the chart drops only `resource_namespace` and `resource_request_operation` from it. The controllers have no CPU limit; CPU is shown against the request. Policy Reporter's per-resource violations are not included: its metric names could not be verified offline. |

## Blocked Sources scope

Per-IP view of traffic rejected at the two enforcement layers:

- Cloudflare edge blocks come from the `firewallEventsAdaptive` collector in
  `abuseipdb-sync` (Loki `job=cloudflare-firewall`). Security Events API
  retention depends on the Cloudflare plan (see `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`)
  and only limits backfill; the panels read what was collected into Loki.
- Cilium drops come from the Hubble flow export shipped by Alloy (Loki
  `job=hubble-flows`). `reserved:ingress` has no BPF policy map, so the
  direct-to-origin denylist is enforced by the Gateway's Envoy and shows up only
  as `DROPPED` flows with no `drop_reason_desc`, source identity 8, the client
  address as source IP and the backend as destination. `POLICY_DENIED` flows
  involving identity 8 are datapath default-deny drops, typically the Gateway's
  connection to a backend, never the denylist. Reasonless flows cannot be
  attributed to a specific policy. The top source-IP table lists flows towards
  identity 8 plus reasonless flows from it, so Envoy-denied clients appear and
  the gateway's own address does not.
- Cloudflare numbers are lower bounds: `firewallEventsAdaptive` is adaptively
  sampled and the collector reads at most `CLOUDFLARE_FIREWALL_LIMIT` rows per
  window; the "Cloudflare capped windows" tile shows capped windows.

Per-IP values are parsed at query time; they are never Prometheus labels.

Block/drop volume uses neutral stat colours; collector freshness and errors retain
health thresholds. Sparse event charts use bars without connecting missing
intervals. Sampled user agents wrap with a capped row height and a cell inspector;
their counts still describe sampled groups, not an exact user-agent ranking.

Updating a dashboard:

1. Edit the JSON file (keep the `uid` and the datasource template variables).
2. Run the dashboard validation:
   `ruby gitops/images/taskflow-caddy-coraza/tests/validate-dashboards.rb gitops/monitoring/logging/dashboards/*.json gitops/monitoring/app/dashboards/*.json`
   (add `LOKI_URL=...` for LogQL parsing) or the full suite
   `gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh`
   (requires docker, helm, ruby, python3 and kubectl). The suite also renders both
   Kustomizations with `kubectl kustomize` and fails if a JSON file is not
   provisioned by their `configMapGenerator`s, drifts from its rendered
   ConfigMap, lacks the `grafana_dashboard` label, or has no valid relative
   `grafana_folder` annotation. Run it after adding a dashboard file or
   editing a `kustomization.yaml`.
3. Commit; Flux applies the updated ConfigMap and the sidecar reloads Grafana.
4. After Flux has reconciled, check the live cluster:
   `python3 gitops/monitoring/tests/verify-dashboards-live.py --grafana`
   (needs kubectl; opens temporary port-forwards). It runs every dashboard
   query against VMSingle and Loki with the default variables (ERROR fails,
   EMPTY is reported as "No data right now"), checks the label sources and
   counts the dashboards rely on, and confirms Grafana serves the repo JSON.
   `--spoof-url https://<site>` additionally sends one request with a fake
   WAF `Messages` header and checks that it is not counted as a detection.

For dashboards imported from elsewhere, record the upstream URL/ID and the local
adaptations in this file.
