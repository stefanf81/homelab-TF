# Documentation Index

Start with the root [`README.md`](../README.md) (provisioning) and
[`gitops/FLUX_BOOTSTRAP.md`](../gitops/FLUX_BOOTSTRAP.md) (cluster bootstrap), then
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Living documents (kept current with the code)

| Document | Purpose |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | System overview: layers, Flux dependency graph, workloads, request path, security posture, what to edit for a change, known limitations |
| [`BACKLOG.md`](BACKLOG.md) | All open work, verified against the code, and the decisions taken against an item |
| [`PERFORMANCE.md`](PERFORMANCE.md) | Resource sizing and tuning decisions (JVM, PostgreSQL, Redis, monitoring) and the evidence |
| [`NODE_HOST_TUNING.md`](NODE_HOST_TUNING.md) | Ubuntu node and Proxmox host tuning runbook (commands, risks, evidence) |
| [`SOPS.md`](SOPS.md) | Encrypted secrets: setup, operations, key rotation, Flux decryption troubleshooting |
| [`HUBBLE_SETUP.md`](HUBBLE_SETUP.md) | Hubble UI behind oauth2-proxy, CLI access, flow export |
| [`KYVERNO_POLICY_ENGINE.md`](KYVERNO_POLICY_ENGINE.md), [`FALCO_RUNTIME_SECURITY.md`](FALCO_RUNTIME_SECURITY.md), [`TRIVY_SECURITY_SCANNING.md`](TRIVY_SECURITY_SCANNING.md) | Security tooling |
| [`ABUSEIPDB_CILIUM_BLOCKLIST.md`](ABUSEIPDB_CILIUM_BLOCKLIST.md) | IP reputation denylist (Cloudflare edge + Cilium) |
| [`TASKFLOW_WAF_ARCHITECTURE.md`](TASKFLOW_WAF_ARCHITECTURE.md) | WAF and logging design (Caddy, Coraza, rate limits, Alloy/Loki, dashboards) |
| [`TASKFLOW_WAF_RUNBOOK.md`](TASKFLOW_WAF_RUNBOOK.md) | WAF operations: build and pin the image, rate-limit verification, tests, rollback, troubleshooting |
| [`CORAZA_CONFIGURATION.md`](CORAZA_CONFIGURATION.md) | Coraza/CRS directive and tuning reference |
| [`BACKEND_INTEGRATION_CONTEXT.md`](BACKEND_INTEGRATION_CONTEXT.md) | What the backend repository must provide (deployment and metrics contract) |

Next to the code: [`gitops/README.md`](../gitops/README.md) (GitOps layout),
[`gitops/RENOVATE.md`](../gitops/RENOVATE.md), and the `README.md`/`SOURCE.md` files under
`gitops/monitoring/` (monitoring safety, dashboard provenance, tests).

## Point-in-time reports (`reports/`: dated, not maintained)

The research and rationale behind many settings; manifest comments cite their sections.
Their open/done statements are frozen at their date: current status is in
[`BACKLOG.md`](BACKLOG.md).

| Document | Snapshot |
|---|---|
| `reports/CLUSTER_AUDIT_2026-10.md` | October 2026 platform audit against five community homelab repos |
| `reports/REMEDIATION_PLAN_2026-10.md` | Issue-by-issue options, configuration, verification and rollback for the audit (the REL/SEC/PERF IDs) |
| `reports/PERF_DEEP_DIVE_2026-10.md` | Measurements and design behind PERF-02/03/04 |
| `reports/CILIUM_REVIEW_2026-10.md` | Cilium settings vs. the Cilium 1.20 tuning guide and home-operations repos |
| `reports/NETWORK_REVIEW_2026-10.md` | Edge-to-pod network settings (timeouts per hop, CoreDNS, node sysctls) |

## Validation

`scripts/validate-gitops.sh` renders every path Flux reconciles and schema-checks
it (CI: `.github/workflows/validate-gitops.yaml`, which also runs
`scripts/bootstrap-foundation.sh --dry-run`, `ruby scripts/check-observability-config.rb`,
`ruby scripts/check-sops-secrets.rb` and `scripts/check-tool-versions.sh`;
`.github/workflows/validate-opentofu.yaml` runs `tofu fmt`, `tofu validate` and `tflint`,
and `.github/workflows/validate-renovate.yaml` runs `renovate-config-validator --strict`).
`.github/workflows/validate-waf-config.yaml` additionally runs
`gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh` across the WAF
ConfigMaps, all 13 Grafana dashboards, pinned Helm renders, and disposable
Alloy/Loki/VictoriaMetrics containers; `.github/workflows/validate-waf-behaviour.yaml`
runs the WAF test suite against the pinned images. Locally: `make validate-gitops`,
`make lint`.
