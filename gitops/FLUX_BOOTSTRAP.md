# TaskFlow bootstrap checklist

This is the end-to-end path from a fresh Proxmox VM to the current TaskFlow
GitOps state.

## 0. Prereqs

- A remote Git repository containing this tree
- `tofu`, `kubectl`, `flux`, and the Cilium CLI on your workstation
- `key.txt` present locally for the SOPS age secret

## 1. Provision the VM and fetch kubeconfig

```bash
make init
make provision
make kubeconfig
```

## 2. Install Cilium on the k3s cluster

The VM boots k3s without Flannel, so Cilium must be installed on top.

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
cilium install --version 1.19.5
cilium status --wait
```

If the node stays NotReady, fix Cilium before moving on.

## 3. Seed the Flux SOPS key once

Flux decrypts `*-secrets.yaml` via the `sops-age` Secret in `flux-system`.

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt
```

## 4. Bootstrap Flux

The bootstrap manifests already live in `gitops/clusters/taskflow/flux-system/`.

```bash
kubectl apply -k gitops/clusters/taskflow/flux-system
flux reconcile source git flux-system
flux reconcile kustomization flux-system -n flux-system
```

## 5. Reconcile the platform and app layers

```bash
flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
```

## 6. Verify

```bash
kubectl get pods -A
kubectl get gateway,httproute -n taskflow
kubectl get secret -n taskflow db-secret backend-secret
```

## 7. Image automation (`:latest` digest pinning) — critical gotchas

TaskFlow's backend/frontend run the mutable `:latest` tag. Flux pins the
current digest and commits `repo:latest@sha256:<digest>` to Git so every rollout
is auditable and automatic when a new `:latest` is pushed to ghcr. This is wired
in `gitops/clusters/taskflow/image-automation.yaml` (ImageRepository +
ImagePolicy + ImageUpdateAutomation) and the `# {"$imagepolicy": ...}` markers in
`gitops/apps/taskflow/backend.yaml` and `frontend.yaml`.

A fresh `flux bootstrap` will silently re-break this in **two** ways. Both were
hit and fixed; document them so they aren't hit again.

### 7.1 The Git source MUST be writable

`flux bootstrap` creates a **read-only** SSH deploy key by default. Flux only
needs read access to *pull* manifests, but `ImageUpdateAutomation` must **push**
the digest-pin commits back. A read-only key fails like this:

```
ImageUpdateAutomation/taskflow-images  GitOperationFailed
  failed to push to remote: unknown error: ERROR: The key you are
  authenticating with has been marked as read only.
```

**Detection:**
```bash
kubectl -n flux-system events --for imageupdateautomation/taskflow-images | tail -10
```

**Fix (PAT — the robust route used here):**
1. Create a GitHub PAT with `repo` / `contents:write` on the repo.
2. Replace the SSH secret with a basic-auth secret:
   ```bash
   kubectl -n flux-system delete secret flux-system
   kubectl -n flux-system create secret generic flux-system \
     --from-literal=username=<github-user> \
     --from-literal=password=<PAT>
   ```
3. Point the GitRepository at HTTPS in `gitops/clusters/taskflow/flux-system/gotk-sync.yaml`:
   ```yaml
   url: https://github.com/stefanf81/homelab-TF.git   # was ssh://git@github.com/...
   ```
   (`secretRef: name: flux-system` stays the same.)
4. Apply and force a reconcile:
   ```bash
   kubectl -n flux-system apply -f gitops/clusters/taskflow/flux-system/gotk-sync.yaml
   kubectl -n flux-system annotate imageupdateautomation taskflow-images \
     reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```

**Alternative:** re-add the GitHub deploy key with **✅ Allow write access**
(Settings → Deploy keys → delete the read-only one → Add deploy key → check the
box). Note GitHub does **not** let you *edit* an existing key to add write
access — you must delete and re-add it, pasting the public half of the cluster's
`flux-system` SSH secret.

> ⚠️ Treat any PAT committed to chat/shell history as compromised and rotate it
> after use.

### 7.2 Use the *basic* marker on Deployment `image:` lines (not `:digest`)

The `:digest` marker variant is for **HelmRelease** charts where `repository`,
`tag`, and `digest` are separate values. On a single Deployment `image:` line it
writes **only the digest** — a bare `sha256:…` with no registry/repo, which is an
invalid pull reference:

```
pod/taskflow-backend-xxxxx  Failed
  failed to resolve reference "docker.io/library/sha256:...": not found
```
```bash
kubectl -n taskflow get deployment taskflow-backend \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# -> sha256:c552b5d7...   (WRONG: no ghcr.io/... prefix)
```

**Fix — basic marker (correct for Deployments):**
```yaml
# gitops/apps/taskflow/backend.yaml
image: ghcr.io/stefanf81/taskflow-backend:latest # {"$imagepolicy": "flux-system:taskflow-backend"}
# gitops/apps/taskflow/frontend.yaml
image: ghcr.io/stefanf81/taskflow-frontend:latest # {"$imagepolicy": "flux-system:taskflow-frontend"}
```
Flux then emits `ghcr.io/stefanf81/taskflow-backend:latest@sha256:<digest>`.

**Correct form for HelmRelease** (separate fields) is the only place `:digest`
belongs:
```yaml
image:
  repository: ghcr.io/stefanf81/podinfo # {"$imagepolicy": "flux-system:policy:name"}
  tag: latest                           # {"$imagepolicy": "flux-system:policy:tag"}
  digest: sha256:…                      # {"$imagepolicy": "flux-system:policy:digest"}
```

### 7.3 Verify the pipeline end-to-end

```bash
# 1. Automation succeeds (no GitOperationFailed)
kubectl -n flux-system get imageupdateautomation taskflow-images -o yaml | grep -A4 "conditions:"

# 2. Deployment image is a VALID repo:tag@sha256 reference
kubectl -n taskflow get deployment taskflow-backend taskflow-frontend \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'

# 3. Pods are Running (not ImagePullBackOff) and old :latest pods terminate
kubectl -n taskflow get pods -l 'app in (taskflow-backend,taskflow-frontend)' -o wide
```

Expected: `conditions` shows `reason: Succeeded`, deployment images look like
`ghcr.io/stefanf81/taskflow-backend:latest@sha256:…`, and a `fluxcdbot` commit
(`chore: automated TaskFlow image update`) appears on `main`.
