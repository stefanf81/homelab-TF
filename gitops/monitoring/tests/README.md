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
ruby gitops/monitoring/tests/validate-dashboards-test.rb
```

The `validate-waf-dashboard-metrics.py`, `validate-alloy-metrics.sh` and Loki query checks start
disposable containers and need Docker. `verify-dashboards-live.py` queries a running cluster.
