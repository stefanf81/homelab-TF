# Documentation Index

## Living documents (kept current with the cluster)

| Document | Purpose |
|---|---|
| `ARCHITECTURE.md` | System overview, known limitations |
| `PERFORMANCE.md` | Resource sizing, RPO/RTO notes |
| `GATEWAY_ACCESS_GUIDE.md`, `HUBBLE_SETUP.md` | Access and networking |
| `KYVERNO_POLICY_ENGINE.md`, `FALCO_RUNTIME_SECURITY.md`, `TRIVY_SECURITY_SCANNING.md` | Security tooling |
| `ABUSEIPDB_CILIUM_BLOCKLIST.md`, `CORAZA_CONFIGURATION.md`, `TASKFLOW_WAF_ARCHITECTURE.md`, `TASKFLOW_WAF_RUNBOOK.md` | Edge protection |
| `SOPS_TUTORIAL.md`, `FLUX_SOPS_RECONCILIATION_TROUBLESHOOTING.md`, `K3s_kubeconfig_troubleshooting_cheatsheet.md` | Runbooks |
| `BACKEND_INTEGRATION_CONTEXT.md` | Application contract |

## Point-in-time reports (dated snapshots, not updated)

Referenced from manifest comments for their rationale; read them as history, and
check the living documents for current state.

| Document | Snapshot |
|---|---|
| `SOTA_HOMELAB_2026.md` | September 2026 gap analysis |
| `BACKLOG_2026.md` | September 2026 backlog (item status is updated as work lands) |
| `CLUSTER_AUDIT_2026-10.md` | October 2026 platform audit |
| `REMEDIATION_PLAN_2026-10.md` | Issue-by-issue follow-up to the audit |
| `PERF_DEEP_DIVE_2026-10.md` | Measurements behind PERF-02/03/04 |
| `POD_SPEC_REVIEW_2026-10.md` | Pod-spec feature review |

`archive/` holds superseded migration guides.

## Validation

`scripts/validate-gitops.sh` renders every path Flux reconciles and schema-checks
it (CI: `.github/workflows/validate-gitops.yaml`, which also runs `tofu fmt` and
`tofu validate`).
