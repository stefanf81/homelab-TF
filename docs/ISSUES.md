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
the single-replica tradeoff in a comment.

### 14. `TLSRoute` CRD installed but unused
**File:** `gitops/infrastructure/controllers/gateway-api/tlsroute-crd.yaml`
Installed "for future TLS support" but there's no HTTPS listener on the Gateway yet.
Harmless, but dead config.
**Fix:** Either add an HTTPS listener + cert-manager `Certificate`, or remove the
TLSRoute CRD until needed.

### 15. Frontend probes hit `/` rather than a health endpoint
**File:** `gitops/apps/taskflow/frontend.yaml`
All three probes use `path: /`. If the SPA ever returns 200 for a 404 page (common
with client-side routing), the pod looks "ready" even when broken.
**Fix:** Probe a real health path (e.g. `/healthz` or a static asset that 404s
correctly) or rely on nginx's `/nginx_status`.

---

## ⚠️ Retracted

### 5. ~~cert-manager namespace exists but is never installed~~ — RETRACTED
Correction: `gitops/infrastructure/controllers/cert-manager/` contains a full
`namespace.yaml` + `repository.yaml` (jetstack) + `release.yaml` (cert-manager
v1.21.0), and it *is* referenced by the controllers Kustomization. cert-manager
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
| 6 | No PodDisruptionBudgets | 🟡 Med | Small | (new files) | ⬜ Open |
| 7 | Frontend UID 101 inconsistent | 🟡 Med | Trivial | frontend.yaml | ✅ Commented |
| 8 | PostgreSQL UID 70 undocumented | 🟡 Med | Trivial | postgres-db.yaml | ✅ Commented |
| 9 | Redis missing startupProbe | 🟡 Med | Trivial | redis.yaml | ✅ Fixed |
| 10 | Init container not digest-pinned | 🟡 Med | Trivial | backend.yaml | ✅ Commented |
| 11 | OpenTofu/Terraform naming mix | 🟢 Low | Trivial | Makefile | ✅ Resolved |
| 12 | diagnose.sh hardcoded macOS path | 🟢 Low | Trivial | diagnose.sh | ✅ Fixed |
| 13 | No namespace LimitRange/Quota | 🟢 Low | Small | namespace.yaml | ✅ Fixed |
| 14 | Unused TLSRoute CRD | 🟢 Low | Trivial | gateway-api | ⬜ Open |
| 15 | Frontend probes on `/` | 🟢 Low | Small | frontend.yaml | ⬜ Open |
| 16 | SOPS key rotation undocumented | 🟢 Low | Trivial | .sops.yaml | ✅ Fixed |
| 17 | No PostgreSQL backup | 🟢 Low | Medium | postgres-*.yaml | ✅ Resolved via Proxmox CSI |
| 18 | Ubuntu 26.04 image URL unverified | 🟢 Low | Trivial | proxmox/main.tf | ✅ Verified |
| 19 | TLS not actually used (cert-manager idle) | 🟡 Med | Medium | gateway.yaml, cert-manager | ✅ Resolved |
| 20 | Grafana redirects to root domain | 🔴 High | Small | routes.yaml | ✅ Fixed |
| 21 | restrict-* policies no-ops (no default-deny) | 🔴 High | Small | default-deny.yaml, network-policy.yaml, redis.yaml, jaeger.yaml | ✅ Fixed |
| 22 | Plaintext HTTP (:80) served, no HTTPS redirect | 🟡 Med | Small | http-redirect.yaml, httproute.yaml, routes.yaml | ✅ Fixed |
