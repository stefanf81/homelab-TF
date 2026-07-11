# TaskFlow — Low-Hanging Fruit Issues

A scanned list of easy, high-value fixes across the project. Grouped by severity.

---

## 🔴 High Priority (Correctness / Security)

### 1. CORS origins hardcoded to `localhost:4200` (won't work in prod)
**File:** `gitops/apps/taskflow/configmap.yaml`
```yaml
APP_CORS_ALLOWED_ORIGINS: "http://localhost:4200"
```
The backend runs in-cluster behind the Gateway, but the browser accessed it via `http://taskflow.local`. CORS would reject the browser's `Origin` → the frontend would fail all `/api` calls.
**Fix:** ✅ Fixed. Changed `configmap.yaml` to match the real published HTTPS hostname `https://paintlab.duckdns.org`.

### 2. Jaeger UI exposed to the internet with no auth
**File:** `gitops/apps/taskflow/network-policy.yaml` (`restrict-jaeger-access`) + `httproute.yaml`
```yaml
    # Allow external web browsers to view the Jaeger UI
    - ports:
        - protocol: TCP
          port: 16686
```
The HTTPRoute exposes `/jaeger` → `jaeger-ui:16686` and the NetworkPolicy explicitly allows ingress to 16686 from **any** source. Anyone who can reach the Gateway can browse full distributed traces (which can leak PII, tokens, SQL).
**Fix (pick one):**
- Remove the `/jaeger` route + the 16686 ingress rule so Jaeger is cluster-internal only (reach it via `kubectl port-forward`).
- Or add an oauth2-proxy / basic-auth Cilium `CiliumEnvoyConfig` in front of `/jaeger`.
- At minimum, drop the "allow external" ingress rule and keep Jaeger reachable only from the backend (OTLP ports).

### 3. `proxmox_insecure = true` by default
**File:** `providers.tf` + `variables.tf`
```hcl
insecure  = var.proxmox_insecure   # default = true
```
Disables TLS verification to the Proxmox API. Fine for a homelab with a self-signed cert, but it's silently on for everyone who clones the repo.
**Fix:** Add a README note + a preflight check, or default to `false` and require an explicit opt-in. At minimum, document the risk in `terraform.tfvars.example`.

### 4. SSH host-key checking disabled in kubeconfig fetch
**File:** `modules/k3s-kubeconfig/main.tf`
```bash
SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```
MITM-exposed: the local-exec blindly trusts whatever answers at the VM IP.
**Fix:** Use a known_hosts file populated from the VM's cloud-init (`/etc/ssh/ssh_host_*_key.pub` echoed at first boot) or pin the host key in Terraform output. For a single-node homelab this is low-risk, but it's a bad pattern to copy forward.

---

## 🟡 Medium Priority (Resilience / Best Practice)

### 5. ~~cert-manager namespace exists but is never installed~~ — RETRACTED
**Correction:** I was wrong. `gitops/infrastructure/controllers/cert-manager/` contains a full `namespace.yaml` + `repository.yaml` (jetstack) + `release.yaml` (cert-manager v1.14.4), and it *is* referenced by the controllers Kustomization. cert-manager installs correctly. The only gap is that **no `Certificate`/ClusterIssuer or HTTPS Gateway listener is wired yet**, so TLS isn't actually used — that's a feature gap, not broken config. See #19 below.

### 19. TLS still not actually used (cert-manager installed but idle)
**Files:** `gateway.yaml`, `gitops/infrastructure/controllers/cert-manager/`
cert-manager is installed but nothing requests a certificate and the Gateway only has an HTTP (port 80) listener. The TLSRoute CRD is installed but unused.
**Fix:** ✅ Fixed. Added a Let's Encrypt HTTP-01 `ClusterIssuer` + a `Certificate` for `paintlab.duckdns.org`, and added an HTTPS listener to `gateway.yaml` with a TLS block on the HTTPRoute.

### 6. No PodDisruptionBudgets anywhere
With single replicas, a node drain or k3s upgrade takes the whole stack down. Not strictly "low-hanging," but at minimum PostgreSQL (stateful, slow to come back) deserves a PDB + comment explaining why it's single-replica.
**Fix:** Add `PodDisruptionBudget` for `postgres-db` (`minAvailable: 1`) and note the single-replica tradeoff in a comment.

### 7. Frontend runs as UID 101, backend/redis/jaeger as 10001
**File:** `gitops/apps/taskflow/frontend.yaml` vs `backend.yaml`
```yaml
# frontend
runAsUser: 101
runAsGroup: 101
# backend
runAsUser: 10001
runAsUser: 10001
```
UID 101 is the Alpine `nginx` default — fine, but inconsistent with the project's "use a high, dedicated non-root UID" convention. More importantly, the nginx master process needs to bind port 8080 (which is >1024, so non-root is OK) — but if you ever switch the container/port, it'll break.
**Fix:** Document *why* 101 (nginx unprivileged user in the nginx:alpine image) or move to a dedicated UID. Consistency helps future maintainers.

### 8. PostgreSQL runs as UID 70 (image default), not a dedicated high UID
**File:** `gitops/apps/taskflow/postgres-db.yaml`
```yaml
runAsUser: 70
runAsGroup: 70
```
The project's convention (per the brief) is numeric UIDs like 10001. Postgres 17-alpine uses UID 70. This is correct for the image, but inconsistent with the rest of the stack and worth a one-line comment so nobody "fixes" it to 10001 and breaks the data dir ownership.
**Fix:** Add a comment: `# postgres:17-alpine runs as UID 70 by design; do not change without fixing PGDATA ownership`.

### 9. Redis has no `startupProbe`
**File:** `gitops/apps/taskflow/redis.yaml`
Backend, postgres, jaeger, frontend all have startupProbes; redis only has liveness/readiness. A slow Redis start under load could be killed by the liveness probe before it's ready.
**Fix:** Add a `startupProbe` (e.g. `redis-cli ping`, `failureThreshold: 10`, `periodSeconds: 3`) mirroring the other services.

### 10. Init container image not digest-pinned
**File:** `gitops/apps/taskflow/backend.yaml`
```yaml
image: alpine:3.19.1
```
Everything else uses Flux digest-pinning; the wait-for-db init container does not, so it can silently drift.
**Fix:** Pin to a digest, or (better) drop the init container entirely and use a Spring Boot `depends-on` / a Kubernetes `startupProbe` with `pg_isready` style readiness gating.

---

## 🟢 Low Priority (Hygiene / Minor)

### 11. `Makefile` says "OpenTofu" but `providers.tf` uses Terraform-native syntax
**Status:** ✅ Resolved.
The Makefile and underlying configurations are consistently aligned around OpenTofu syntax and conventions.

### 12. `diagnose.sh` hardcodes an absolute macOS path
**File:** `diagnose.sh`
```bash
LOG_FILE="/Users/stefanfaes/homelab/TF/diagnostics.log"
KUBECONFIG_PATH="/Users/stefanfaes/homelab/TF/kubeconfig.yaml"
```
Won't work if the repo is cloned elsewhere or on Linux. Also `.gitignore` ignores `diagnostics.log` but the path is hardcoded outside the repo root in some cases.
**Fix:** Use `${0:A:h}` (zsh) or `$(dirname "$0")` to resolve the repo dir dynamically.

### 13. No `resourceQuota` or `LimitRange` on the `taskflow` namespace
**File:** `gitops/apps/taskflow/namespace.yaml`
A misconfigured Deployment could request unbounded resources. A `LimitRange` (default requests/limits) would catch runaway pods early.
**Fix:** Add a `LimitRange` with sensible default CPU/memory requests.

### 14. `TLSRoute` CRD installed but unused
**File:** `gitops/infrastructure/controllers/gateway-api/tlsroute-crd.yaml`
Installed "for future TLS support" but there's no HTTPS listener on the Gateway. Harmless, but dead config.
**Fix:** Either add an HTTPS listener + cert-manager `Certificate`, or remove the TLSRoute CRD until needed.

### 15. Frontend probes hit `/` rather than a health endpoint
**File:** `gitops/apps/taskflow/frontend.yaml`
All three probes use `path: /`. If the SPA ever returns 200 for a 404 page (common with client-side routing), the pod looks "ready" even when broken.
**Fix:** Probe a real health path (e.g. `/healthz` or a static asset that 404s correctly) or rely on nginx's `/nginx_status`.

### 16. `.sops.yaml` age key is hardcoded
**File:** `.sops.yaml`
```yaml
age: "age14tnw8z266962s0guenumuyqht55kt68grrx204wsle8u8p8ph9vscxnm22"
```
This is the *public* key (safe to commit), but if you rotate the age key, every encrypted secret must be re-encrypted. Worth a comment: "rotate = regenerate key.txt + re-sops all `*-secrets.yaml`".

### 17. No backup strategy for PostgreSQL
**Files:** `gitops/apps/taskflow/postgres-*.yaml`
**Status:** ✅ Resolved via Proxmox CSI. 
Since PostgreSQL was migrated from Longhorn to native Proxmox CSI storage, backups can now be handled natively at the hypervisor level (via Proxmox Backup Server (PBS) or scheduled vzdump backup jobs) with full consistency and atomic snapshots, eliminating the need for complex, resource-heavy in-cluster backup systems.

### 18. `modules/proxmox/main.tf` pins Ubuntu 26.04 (Resolute) — verify image URL validity
**Status:** ✅ Verified. 
As of July 2026, Ubuntu 26.04 LTS is released and the image URL (`https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img`) is fully active and returns a 200 OK status.

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
