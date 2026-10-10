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
| `falco-official.json` | `falco-dashboard` | `ddwe2ug4nfi0wb` | Security | [Falco chart dashboard](https://raw.githubusercontent.com/falcosecurity/charts/master/charts/falco/dashboards/falco-dashboard.json), locally adapted: VictoriaMetrics datasource variable with default `VictoriaMetrics`, existing UID retained; see `docs/FALCO_RUNTIME_SECURITY.md`. |
| `trivy.json` | `trivy-dashboard` | `trivy-operator` | Security | Based on Aqua's Grafana dashboard [17813](https://grafana.com/grafana/dashboards/17813/), locally adapted to the Trivy Operator metric set and VictoriaMetrics. |
| `taskflow-waf.json` | `taskflow-waf-dashboard` | `taskflow-waf` | Taskflow | In-repo original (WAF detections, identity, upstream health). |
| `taskflow-access-logs.json` | `taskflow-access-logs-dashboard` | `taskflow-access-logs` | Taskflow | In-repo original (request/status analytics over Loki access logs). |
| `taskflow-rate-limits.json` | `taskflow-rate-limits-dashboard` | `taskflow-rate-limits` | Taskflow | In-repo original (rate-limit rejections by zone). |

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
