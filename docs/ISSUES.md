# TaskFlow — Open Issues

A scanned list of easy, high-value fixes. **Everything except the items below has
been resolved** — see the [Summary Table](#summary-table) for the full history
(CORS, Jaeger exposure, insecure-TLS defaults, SSH host-key checks, Postgres
backups, TLS enablement, network isolation, HTTPS redirect, etc. are all ✅ done).
This file now tracks only what is still *open* or was *retracted*.

---

## 🟡 Medium Priority (Resilience / Best Practice)

### 6. No PodDisruptionBudgets anywhere
With single replicas, a node drain or k3s upgrade takes the whole stack down. Not
strictly "low-hanging," but at minimum PostgreSQL (stateful, slow to come back)
deserves a PDB + comment explaining why it's single-replica.
**Fix:** Add `PodDisruptionBudget` for `postgres-db` (`minAvailable: 1`) and note
the single-replica tradeoff in a comment. (✅ **Resolved**: Added `PodDisruptionBudget` with `minAvailable: 1` directly to `postgres-db.yaml`)

### 15. ~~Frontend probes hit `/` rather than a health endpoint~~
**File:** `gitops/apps/taskflow/frontend.yaml`
All three probes now use the concrete `/index.html` asset instead of `/`. This
avoids treating a client-side SPA fallback response as proof that nginx is
serving the expected application bundle. **Status:** Resolved.

---

## ⚠️ Retracted

### 5. ~~cert-manager namespace exists but is never installed~~ — RETRACTED
Correction: `gitops/infrastructure/controllers/cert-manager/` contains a full
`namespace.yaml` + `repository.yaml` (jetstack) + `release.yaml` (cert-manager
v1.21.1), and it *is* referenced by the controllers Kustomization. cert-manager
installs correctly. The original gap (no `Certificate`/ClusterIssuer wired) was
later resolved — see #19 in the table.

---

## Summary Table

| # | Issue | Severity | Effort | File | Status |
|---|-------|----------|--------|------|--------|
| 1 | CORS origin hardcoded to localhost | 🔴 High | Trivial | configmap.yaml | ✅ Fixed |
| 2 | Jaeger UI unauthenticated exposure | 🔴 High | Small | jaeger.yaml, httproute.yaml | ✅ Fixed |
| 3 | Proxmox insecure TLS default | 🔴 High | Trivial | variables.tf, terraform.tfvars.example | ✅ Documented |
| 4 | SSH host-key check disabled | 🔴 High | Small | k3s-kubeconfig/main.tf | ✅ Documented |
| 5 | ~~cert-manager scaffolding dead~~ | — | — | — | ⚠️ Retracted (was wrong) |
| 6 | No PodDisruptionBudgets | 🟡 Med | Small | postgres-db.yaml | ✅ Fixed |
| 7 | Frontend UID 101 inconsistent | 🟡 Med | Trivial | frontend.yaml | ✅ Commented |
| 8 | PostgreSQL UID 70 undocumented | 🟡 Med | Trivial | postgres-db.yaml | ✅ Commented |
| 9 | Redis missing startupProbe | 🟡 Med | Trivial | redis.yaml | ✅ Fixed |
| 10 | Init container not digest-pinned | 🟡 Med | Trivial | backend.yaml | ✅ Commented |
| 11 | OpenTofu/Terraform naming mix | 🟢 Low | Trivial | Makefile | ✅ Resolved |
| 12 | diagnose.sh hardcoded macOS path | 🟢 Low | Trivial | diagnose.sh | ✅ Fixed |
| 13 | No namespace LimitRange/Quota | 🟢 Low | Small | namespace.yaml | ✅ Fixed |
| 14 | Unused TLSRoute CRD | 🟢 Low | Trivial | gateway-api | ✅ Resolved (HTTPS listener & cert active) |
| 15 | Frontend probes on `/` | 🟡 Med | Small | frontend.yaml | ✅ Fixed |
| 16 | SOPS key rotation undocumented | 🟢 Low | Trivial | .sops.yaml | ✅ Fixed |
| 17 | No PostgreSQL backup | 🟢 Low | Medium | postgres-*.yaml | ✅ Resolved via Proxmox CSI |
| 18 | Ubuntu 26.04 image URL unverified | 🟢 Low | Trivial | proxmox/main.tf | ✅ Verified |
| 19 | TLS not actually used (cert-manager idle) | 🟡 Med | Medium | gateway.yaml, cert-manager | ✅ Resolved |
| 20 | Grafana redirects to root domain | 🔴 High | Small | routes.yaml | ✅ Fixed |
| 21 | restrict-* policies no-ops (no default-deny) | 🔴 High | Small | default-deny.yaml, network-policy.yaml, redis.yaml, jaeger.yaml | ✅ Fixed |
| 22 | Plaintext HTTP (:80) served, no HTTPS redirect | 🟡 Med | Small | http-redirect.yaml, httproute.yaml, routes.yaml | ✅ Fixed |

---

## 🚀 Future Roadmap & Platform Enhancements

The following high-value architecture, security, and performance enhancements are proposed for future iterations of the TaskFlow platform:

### 1. Stateful Resilience & Backups
* **Daily Logical PostgreSQL Backups (`CronJob`):** Create a lightweight Kubernetes `CronJob` that performs a daily `pg_dump`, gzips the database, and pushes it to an off-site S3-compatible bucket, local NAS, or MinIO. This adds logical point-in-time recovery on top of the block-level Proxmox CSI snapshots.
* **Persistent Redis Cache:** Transition the Redis `/data` mount from an ephemeral `emptyDir` to a dedicated Proxmox CSI PVC (e.g., 2Gi) and enable Append-Only File (`appendonly yes`). This prevents cache stampedes on database servers when Redis pods restart or during node drains.

### 2. Deployment Safeguards & CI/CD
* **Automated Pull Request Validation (GitHub Actions):** Build a `.github/workflows/validate.yml` pipeline that triggers on any push or PR to run OpenTofu formatting (`tofu fmt -check`), configuration validation (`tofu validate`), and dry-run Kustomize templates (`kubectl kustomize gitops/apps/taskflow` and `gitops/monitoring/...`). This prevents syntactically broken configurations from breaking FluxCD reconciliation.

### 3. Edge Gateway & Multiplexing
* **HTTP/2 Protocol on Cilium Gateway:** Configure `HTTP/2` protocol support on your HTTPS listener in `gateway.yaml` to enable native multiplexing of API requests and SPA chunks, reducing page-load latency.

### 4. Consolidated Observability Logs
* **Centralized Log Aggregation:** Deploy a lightweight logging agent (e.g., Grafana Loki or VictoriaLogs with Fluent Bit) to scrape container console logs and feed them directly into your existing Grafana dashboard alongside VictoriaMetrics and Jaeger, completing the observability triad.
