# Flux + SOPS Troubleshooting: `ReconciliationFailed` / `no matches for kind "ENC[…]"`

A practical, incident-driven guide for debugging Flux `kustomize-controller` failures
caused by SOPS-encrypted secrets, plus the related HelmRepository "no chart name
found" gotcha we hit alongside it.

> Companion to [`SOPS_TUTORIAL.md`](./SOPS_TUTORIAL.md) (how secrets are
> encrypted/decrypted in this repo). This file is about **diagnosing and fixing
> the reconcile failure** when that pipeline breaks.

---

## 1. Symptom

A Flux `Kustomization` shows a warning like:

```
Warning  ReconciliationFailed  7s (x27 over 12h)  kustomize-controller
  ENC[...]/ENC[...]/ENC[...] dry-run failed: no matches for kind
  "ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]"
  in version "ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]"
```

Key tells:
- `x27 over 12h` → it has been retrying on its reconcile interval for hours. It is a
  **dry-run failure**, so **nothing was applied and nothing was corrupted** — just a
  blocked reconcile.
- The literal string `ENC[AES256_GCM,…]` is **SOPS ciphertext**. It belongs inside
  secret *values*, never in a field a cluster must parse.

---

## 2. What the error actually means

`ENC[AES256_GCM,data:…,iv:…,tag:…,type:str]` is the format SOPS writes for an
**encrypted value**.

How SOPS encryption works in this repo (see `.sops.yaml`): by default SOPS encrypts
the **values** of a YAML document, leaving the **keys** (`apiVersion:`, `kind:`,
`metadata:`, etc.) as plain text. So a secret like:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: proxmox-csi-config
```

becomes (values encrypted, keys intact):

```yaml
apiVersion: ENC[AES256_GCM,…]
kind: ENC[AES256_GCM,…]
metadata:
  name: ENC[AES256_GCM,…]
```

That is **normal and expected**. The manifest is only valid **after Flux decrypts it**
(restore `kind: Secret`, etc.) and applies it.

> ⚠️ The earlier sibling doc states structural fields "remain in plain text". More
> precisely: the **key names** remain plain text, but their **values** are ciphertext.
> That distinction is exactly why a *missing decryption step* produces this error: Flux
> applies the file **as-is**, so `kind: ENC[…]` reaches the API server, which replies
> `no matches for kind "ENC[…]"`.

**Conclusion:** the encrypted file was applied **without being decrypted first**.
Two things must both be true for Flux to decrypt:
1. The `Kustomization` declares `spec.decryption`.
2. A Secret containing the age private key (`sops-age`) exists in the
   Kustomization's namespace.

If either is missing, ciphertext flows straight into the dry-run → this error.

---

## 3. Root cause (two parts) + a related gotcha

| # | Cause | Fix section |
|---|-------|-------------|
| A | `Kustomization.spec.decryption` is **absent** → Flux never decrypts | §5 |
| B | The `sops-age` Secret is **missing** in the Kustomization's namespace → even with decryption enabled, no key to decrypt with | §5 |
| C | *(unrelated, often surfaces right after A/B is fixed)* A `HelmRepository` points at a repo that does **not contain the chart**, or the `HelmRelease` pins a **non-existent version** → `no chart name found` | §6 |

In our incident, commit `e6f5b6d` introduced an encrypted `proxmox-csi-secrets.yaml`
under `gitops/infrastructure/controllers`. Neither the decryption block nor the
`sops-age` secret existed, so the Kustomization failed. The same commit also added a
Proxmox CSI `HelmRepository`/`HelmRelease` with a wrong repo URL **and** a version pin
that does not exist — so once decryption was fixed, a second, separate error appeared.

---

## 4. Step-by-step diagnosis

> Run these from a machine that can reach the cluster (kubectl configured for the
> right context). Replace `<…>` placeholders with real values — do **not** pass literal
> angle brackets to the shell.

### 4.1 Confirm you are on the right cluster
```bash
kubectl config current-context
kubectl get pods -n flux-system
```
If `current-context` is unexpected or the pods are missing, switch contexts:
```bash
kubectl config get-contexts
kubectl config use-context <context-name>
```

### 4.2 Find the failing Kustomization
```bash
kubectl get kustomizations -A
kubectl get kustomization <NAME> -n <NAMESPACE> -o yaml
```
Look at `spec`:
```yaml
spec:
  path: ./gitops/infrastructure/controllers
  sourceRef:
    kind: GitRepository
    name: flux-system
  # ← if there is no `decryption:` key here, that is cause A
```

### 4.3 Locate the encrypted file in the repo and verify the recipient
On your local checkout, find the file whose ciphertext matches the warning and inspect
its SOPS metadata:
```bash
grep -rl "ENC\[AES256_GCM" gitops/
```
Read the trailing `sops:` block of the offending file:
```yaml
sops:
  age:
    - enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        …
        -----END AGE ENCRYPTED FILE-----
      recipient: age14tnw8z266962s0guenumuyqht55kt68grrx204wsle8u8ph9vscxnm22
```
The `recipient:` must match the **public** key derived from your private key:
```bash
age-keygen -y ~/.config/sops/age/keys.txt
# → must equal the `recipient:` above, otherwise you have the wrong key
```

### 4.4 Check the decryption secret exists
```bash
kubectl -n <NAMESPACE> get secret sops-age -o name
# NotFound → cause B
```

---

## 5. The fix (SOPS decryption)

### 5.1 Create the `sops-age` secret from your age private key
```bash
kubectl -n <NAMESPACE> create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```
The secret **must live in the same namespace as the Kustomization** that references it.

### 5.2 Enable decryption on the Kustomization
```bash
kubectl -n <NAMESPACE> patch kustomization <NAME> --type=merge \
  -p '{"spec":{"decryption":{"provider":"sops","secretRef":{"name":"sops-age"}}}}'
```

### 5.3 Force a reconcile and watch
```bash
kubectl -n <NAMESPACE> annotate kustomization <NAME> \
  --overwrite reconcile.fluxcd.io/requestedAt="$(date +%s)"

kubectl -n <NAMESPACE> get kustomization <NAME>
```
Expected: `Ready` flips to `True` and the warning stops. (`Ready: Unknown` /
`Reconciliation in progress` for a minute or two is normal if the Kustomization has
`wait: true` and is waiting on dependent resources to become healthy.)

### 5.4 Verify the secret actually decrypted
```bash
kubectl -n <SECRET_NS> get secret <SECRET_NAME> \
  -o jsonpath='{.data.config\.yaml}' | base64 -d | head -5
```
You should see **real values** (e.g. a Proxmox URL + token), **not** `ENC[…]`.

---

## 6. Related gotcha: HelmRepository `no chart name found`

Once decryption works, the reconcile proceeds and may immediately fail on a
`HelmRelease` with:

```
HelmChart '…/…' is not ready: invalid chart reference:
failed to get chart version for remote reference: no chart name found
```

### 6.1 Cause
The `HelmRepository` either (a) points at an HTTP repo that **does not contain the
chart**, or (b) the `HelmRelease` pins a **version that does not exist** in that repo.

### 6.2 Find the real chart location
Many charts (e.g. Proxmox CSI) are published only as **OCI registry** charts, not in
a traditional HTTP `index.yaml` repo. Verify what actually exists before editing:

```bash
# Does an HTTP index contain the chart?
curl -s <HELM_REPO_URL>/index.yaml | grep -i <chart-name> || echo "not in this HTTP repo"

# For OCI registries, list the published tags:
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:<user>/<repo>/<chart>:pull" \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/<user>/<repo>/<chart>/tags/list" | tr ',' '\n'
```
Confirm the **version you pinned is in that tag list**. If it is not, pick an existing
one or a semver range (e.g. `">=0.3.0"`).

### 6.3 Fix the manifests
For an OCI chart, the `HelmRepository` needs `type: oci`:

```yaml
# repository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: proxmox-csi
  namespace: csi-proxmox
spec:
  type: oci                       # ← was missing; default is HTTP
  interval: 24h
  url: oci://ghcr.io/sergelogvinov/charts   # ← OCI registry, not github.io/helm-charts
```
```yaml
# release.yaml
spec:
  chart:
    spec:
      chart: proxmox-csi-plugin
      version: 0.3.18           # ← upgraded successfully to the latest valid OCI chart version (0.3.18)
      sourceRef:
        kind: HelmRepository
        name: proxmox-csi
        namespace: csi-proxmox
```
Commit & push; Flux reconciles and source-controller pulls the chart from the OCI
registry.

---

## 7. Prevention: the *other* encrypted files

A single commit often adds several encrypted secrets at once. Each owning
`Kustomization` needs **both** the `sops-age` secret (in its namespace) **and** a
`spec.decryption` block. Find every encrypted file and its recipient:

```bash
grep -rl "ENC\[AES256_GCM" gitops/            # every encrypted manifest
grep -rn "recipient:" gitops/                 # every SOPS recipient (confirm one key)
kubectl get kustomizations -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PATH:.spec.path
```
For each Kustomization whose `PATH` contains an encrypted file:
1. `kubectl -n <NS> create secret generic sops-age --from-file=age.agekey=$HOME/.config/sops/age/keys.txt`
2. Patch `spec.decryption` onto it (§5.2).
3. Reconcile and verify (§5.3–5.4).

If all encrypted files share one recipient (typical), one age key covers them all — you
just need the secret present in **each** Kustomization's namespace.

---

## 8. Quick command cheat sheet

```bash
# Diagnose
kubectl config current-context
kubectl get kustomizations -A
kubectl get kustomization <NAME> -n <NS> -o yaml | grep -A4 'decryption:'
grep -rl "ENC\[AES256_GCM" gitops/
age-keygen -y ~/.config/sops/age/keys.txt
kubectl -n <NS> get secret sops-age -o name

# Fix (SOPS)
kubectl -n <NS> create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
kubectl -n <NS> patch kustomization <NAME> --type=merge \
  -p '{"spec":{"decryption":{"provider":"sops","secretRef":{"name":"sops-age"}}}}'
kubectl -n <NS> annotate kustomization <NAME> \
  --overwrite reconcile.fluxcd.io/requestedAt="$(date +%s)"

# Verify
kubectl -n <NS> get kustomization <NAME>
kubectl -n <SECRET_NS> get secret <SECRET_NAME> \
  -o jsonpath='{.data.config\.yaml}' | base64 -d | head -5
```

---

## 9. Reference: files involved in this repo's incident

| File | Role | What was wrong |
|------|------|----------------|
| `.sops.yaml` | SOPS encryption rules (`path_regex: .*-secrets\.yaml$`, age recipient) | — (correct) |
| `gitops/infrastructure/controllers/proxmox-csi/proxmox-csi-secrets.yaml` | Encrypted `Secret` | Decryption never run (causes A + B) |
| `gitops/infrastructure/controllers/proxmox-csi/repository.yaml` | `HelmRepository` for Proxmox CSI | Was HTTP GitHub Pages repo without the chart → changed to `type: oci`, `url: oci://ghcr.io/sergelogvinov/charts` |
| `gitops/infrastructure/controllers/proxmox-csi/release.yaml` | `HelmRelease` for Proxmox CSI | Pinned `version: 0.3.18` (Note: 0.3.18 is the latest valid OCI chart version in the registry, which successfully deploys the Proxmox CSI plugin) |
