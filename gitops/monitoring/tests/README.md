# Monitoring tests

Offline checks for the Grafana dashboards, the Alloy/Loki/VictoriaMetrics configuration and the
WAF-derived metrics. They are orchestrated by
`gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh` (CI: `validate-waf-config.yaml`),
which also validates the WAF ConfigMaps.

Run without Docker (Ruby, Helm and Kustomize/kubectl only):

```sh
ruby gitops/monitoring/tests/validate-dashboards.rb gitops/monitoring/*/dashboards/*.json
ruby gitops/monitoring/tests/validate-dashboard-provisioning.rb "$PWD"
ruby gitops/monitoring/tests/validate-monitoring-configs.rb
ruby gitops/monitoring/tests/validate-startup-scope.rb
ruby gitops/monitoring/tests/validate-dashboards-test.rb
```

The `validate-waf-dashboard-metrics.py`, `validate-alloy-metrics.sh` and Loki query checks start
disposable containers and need Docker. `verify-dashboards-live.py` queries a running cluster.

`python3 gitops/monitoring/tests/validate-nginx-dns-startup.py` renders the pinned Trivy
and Loki charts, checks the application namespace allowlist and unchanged scanner
budgets, and starts the pinned frontend and chart-selected nginx gateway images with
`--network none`. Negative controls check that the old configs fail on DNS lookup;
the revised configs must serve `/index.html` and `/livez` without DNS or a backend.
This checks startup resilience, not runtime DNS recovery or upstream access. The
render checks also ensure both literal resolver IPs match the CoreDNS Service IP.
Docker needs read access to the pinned private frontend image in GHCR; CI logs in
with its existing package-read credential. No Kubernetes resources are created.
