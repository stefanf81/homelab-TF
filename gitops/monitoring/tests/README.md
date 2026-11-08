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

`validate-alloy-metrics.sh` also feeds synthetic platform logs through the shipped
Alloy pipeline. Only the exact legacy Kyverno client-go INFO warnings are dropped
in the four controller streams; unrelated warnings/errors, changed messages,
other namespaces/applications/containers and retained ANSI bodies must survive.
Fixtures preserve Kubernetes-style LF/CRLF terminators through a JSON decoding
wrapper; testing only file tails would miss their newline-handling difference.

`python3 gitops/monitoring/tests/validate-nginx-dns-startup.py` renders the pinned Trivy
and Loki charts, checks the application namespace allowlist and unchanged scanner
budgets, and starts the pinned frontend and chart-selected nginx gateway images with
`--network none`. Negative controls check that the old configs fail on DNS lookup;
the revised configs must serve `/index.html` and `/livez` without DNS or a backend.
This checks startup resilience, not runtime DNS recovery or upstream access. The
render checks also ensure both literal resolver IPs match the CoreDNS Service IP.
Docker needs read access to the pinned private frontend image in GHCR; CI logs in
with its existing package-read credential. No Kubernetes resources are created.

`python3 gitops/monitoring/tests/validate-alloy-discovery.py` evaluates the shipped
discovery/relabel rules in the real Alloy image with synthetic Kubernetes metadata
(no cluster access). It checks legacy `app` and standard label routing, standard-name
precedence, backend multiline isolation, and that WAF logs cannot bypass their own
pipeline. Trivy operator/server diagnostics are kept, but scanner/collector job
report payloads and Loki gateway access logs are dropped. It also renders the pinned
Alloy chart to check namespace-scoped pod-log RBAC and the Trivy bootstrap dependency.
