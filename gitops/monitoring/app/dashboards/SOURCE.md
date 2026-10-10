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

| File | ConfigMap | Dashboard UID | Folder | Source |
|---|---|---|---|---|
| `abuseipdb-security.json` | `abuseipdb-security-dashboard` | `abuseipdb-security` | Security | In-repo original; see `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`. |
| `blocked-sources.json` | `blocked-sources-dashboard` | `blocked-sources` | Security | In-repo original; see below and `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`. |
| `taskflow-performance.json` | `taskflow-performance-dashboard` | `taskflow-performance` | Taskflow | In-repo original (backend JVM/HTTP/Hikari/PostgreSQL/Redis + pod/node/disk metrics). |

## Blocked Sources scope

Per-IP view of traffic rejected at the two enforcement layers:

- Cloudflare edge blocks come from the `firewallEventsAdaptive` collector in
  `abuseipdb-sync` (Loki `job=cloudflare-firewall`). Free-plan Security Events
  retention is 24h, so short ranges are the most meaningful.
- Cilium drops come from the Hubble flow export shipped by Alloy (Loki
  `job=hubble-flows`); the direct-to-origin denylist shows up as
  `POLICY_DENIED` / reasonless `DROPPED` flows at `reserved:ingress`
  (identity 8). Reasonless flows cannot be attributed to a specific policy from
  this export.

Per-IP values are parsed at query time; they are never Prometheus labels.

Updating a dashboard:

1. Edit the JSON file (keep the `uid` and the datasource template variables).
2. Run the dashboard validation:
   `ruby gitops/images/taskflow-caddy-coraza/tests/validate-dashboards.rb gitops/monitoring/logging/dashboards/*.json gitops/monitoring/app/dashboards/*.json`
   (add `LOKI_URL=...` for LogQL parsing) or the full suite
   `gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh`
   (requires docker, ruby, and kubectl). The suite also renders both
   Kustomizations with `kubectl kustomize` and fails if a JSON file is not
   provisioned by their `configMapGenerator`s, drifts from its rendered
   ConfigMap, lacks the `grafana_dashboard` label, or has no valid relative
   `grafana_folder` annotation. Run it after adding a dashboard file or
   editing a `kustomization.yaml`.
3. Commit; Flux applies the updated ConfigMap and the sidecar reloads Grafana.

For dashboards imported from elsewhere, record the upstream URL/ID and the local
adaptations in this file.
