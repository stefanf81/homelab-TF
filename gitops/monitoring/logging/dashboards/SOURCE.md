# Custom Grafana dashboards (logging)

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

| File | ConfigMap | Dashboard UID | Folder | Source |
|---|---|---|---|---|
| `falco-official.json` | `falco-dashboard` | `ddwe2ug4nfi0wb` | Security | [Falco chart dashboard](https://raw.githubusercontent.com/falcosecurity/charts/master/charts/falco/dashboards/falco-dashboard.json), locally adapted for Falco 0.45.0 (chart 9.2.0, modern eBPF): VictoriaMetrics datasource variable with default `VictoriaMetrics`, existing UID retained; priority names mapped to Falco's numeric scale (0 emergency … 7 debug; upstream's mapping was inverted); rule-match pies are instant `increase_pure(...[$__range])` and the over-time bars `increase_pure(...[$__interval])` (rule counters appear at their first match); CPU panel reads cAdvisor `container_cpu_usage_seconds_total{container="falco"}` as `percentunit` of one core (`falcosecurity_falco_cpu_usage_ratio` is an average since process start); the "Scap Drops Buffer Enter" panel is removed (Falco 0.45 exports `dir="enter"` as constant zeros) and the exit panel groups by `drop` (adds `close`, `proc`); `raw_name` removed from the memory panels (no such label); unit `ops` on "Scap events/s"; descriptions on the drop and queue panels; the `homelab` tag and the navigation dropdown link; see `docs/FALCO_RUNTIME_SECURITY.md`. |
| `trivy.json` | `trivy-dashboard` | `trivy-operator` | Security | Based on Aqua's Grafana dashboard [17813](https://grafana.com/grafana/dashboards/17813/), locally adapted to the Trivy Operator v0.35.0 (chart 0.37.0) metric set and VictoriaMetrics: `topk_max` on the top-15 namespace panels, `max by` on the per-image table (Trivy writes one report per workload container), compliance panels per framework (`title` is the framework title), and a scrape with `honorLabels: true` so the findings keep their own `namespace` label. |
| `taskflow-waf.json` | `taskflow-waf-dashboard` | `taskflow-waf` | Taskflow | In-repo original (WAF detections, identity, upstream health). |
| `taskflow-access-logs.json` | `taskflow-access-logs-dashboard` | `taskflow-access-logs` | Taskflow | In-repo original (request/status analytics over Loki access logs). |
| `taskflow-rate-limits.json` | `taskflow-rate-limits-dashboard` | `taskflow-rate-limits` | Taskflow | In-repo original (rate-limit rejections by zone). |
| `logging-pipeline.json` | `logging-pipeline-dashboard` | `logging-pipeline` | Platform | In-repo original (Alloy to Loki delivery, discarded and dropped logs, Loki streams/storage/latency, Alloy resources). Metric names checked against Loki 3.7.8 and Alloy v1.21.0. Loki discard counters use `increase_pure()` (they appear at the first discard). |

## Metrics derived from logs

The overview panels of `taskflow-waf.json` and `taskflow-rate-limits.json` read `loki_process_custom_taskflow_waf_*` metrics instead of scanning Loki. They are produced by the metrics-only `loki.process` components `waf_requests` (requests, duration histogram and rate-limit rejections from one parse), `waf_audit` and `waf_rules` in `alloy-release.yaml`, scraped from Alloy by the `alloy` VMServiceScrape. They cover all clients and honor only the Application filter; the Client IP filtered versions stay in Loki (collapsed rows). `tests/validate-alloy-metrics.sh` runs the real Alloy image (v1.21.0, the app version of chart 1.14.0, with `--stability.level=experimental` like the release) over fixture logs and checks every counter and the duration histogram, so change the pipeline and the dashboards together. Detections, rule IDs, rule messages, paranoia tags and inspection latency are read only from Coraza-written parts of an audit record: the top-level `},"messages":[{` array (Coraza `%q`-quotes its own `[id \"N\"]`/`[tag \"…\"]` values, while client data is escaped twice) and `"stopwatch":"…"`. Coraza lowercases request header names into the record, so a bare `"messages"` needle would count a client header `Messages: …` as a detection and let it inject `rule_id` labels; the fixtures include such header-key spoofs.

- **Counter semantics:** These counters are created at their first event and start from zero. Use VictoriaMetrics' `increase_pure()` before summing, not `increase()` (which can discard a large initial value) or `last_over_time()` (a cumulative value, not a window count). Request rates divide the same increase by `$__rate_interval_ms / 1000`. This is MetricsQL-specific, not portable PromQL; do not apply it indiscriminately to counters first scraped midway through their lifetime. Events before collection or during scrape gaps cannot be reconstructed exactly.
- **Coverage:** Metrics started on 2026-10-18 at 13:34 UTC. A range spanning that point can have larger Loki totals than metric totals. The overview row headings state coverage and filter scope explicitly.
- **Missing series:** A zero fallback must be derived from request counters, grouped by application when appropriate. Keep the fallback on the Caddy side of the upstream-429 subtraction: upstream 429s can exist before the first Caddy rejection. Metric panels are gated by a successful Alloy scrape at the evaluation time, so scrape failures are gaps rather than healthy zeros. This does not detect a stalled log source; check pipeline health too. Empty rule panels report no matching detections, not proof of healthy ingestion.
- **Regression tests:** `python3 gitops/images/taskflow-caddy-coraza/tests/validate-waf-dashboard-metrics.py` runs the actual dashboard expressions against a disposable VictoriaMetrics container (Docker required, no cluster writes). Its image is pinned to the deployed stack 0.96.0's VMSingle version; update `VM_IMAGE` when testing another version. Fixtures cover first bursts, resets, window boundaries, upstream-only 429s, quiet applications and scrape failures. The config-validation CI runs it alongside the Loki tests.

## Conventions shared by all dashboards

- **Navigation:** every dashboard carries the tag `homelab` and a first link of type `dashboards` (tag `homelab`, shown as the "Dashboards" dropdown). A new dashboard without the tag is missing from every dropdown, so add both. Other tags describe the topic.
- **Shared crosshair:** `graphTooltip: 1`, so hovering one chart marks the same time on all charts.
- **Annotations:** the Taskflow dashboards with a VictoriaMetrics datasource (`taskflow-performance`, `taskflow-waf`, `taskflow-rate-limits`) mark Deployment rollouts (`kube_deployment_status_observed_generation` changes) and container restarts (`kube_pod_container_status_restarts_total` increases) in the `taskflow` namespace. Annotation queries use the literal datasource uid `VictoriaMetrics`: the `${datasource}` variable did not resolve in annotation queries on Grafana 13.2.3.
- **IP drill-down:** Client IP columns link to the other Taskflow dashboards with `var-client_ip` filled in and to an AbuseIPDB lookup (opens in a new tab on click). Cloudflare and Cilium drops happen before the WAF, so the Blocked Sources tables link only to the lookup.
- **Refresh:** dashboards that scan Loki refresh every 5 minutes (Blocked Sources: 1 minute, measured at 0.8 MB scanned per load over 24h on lab data); metrics-only dashboards refresh every 30 seconds to 1 minute.

Updating a dashboard:

1. Edit the JSON file (keep the `uid` and the datasource template variables).
2. Run the dashboard validation:
   `LOKI_URL=... ruby gitops/images/taskflow-caddy-coraza/tests/validate-dashboards.rb gitops/monitoring/logging/dashboards/*.json gitops/monitoring/app/dashboards/*.json`
   or the full suite `gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh`
   (requires docker, ruby, and kubectl). The suite also renders both
   Kustomizations with `kubectl kustomize` and fails if a JSON file is not
   provisioned by their `configMapGenerator`s, drifts from its rendered
   ConfigMap, lacks the `grafana_dashboard` label, or has no valid relative
   `grafana_folder` annotation. Run it after adding a dashboard file or
   editing a `kustomization.yaml`.
3. Commit; Flux applies the updated ConfigMap and the sidecar reloads Grafana.

For dashboards imported from elsewhere, record the upstream URL/ID and the local
adaptations in this file.
