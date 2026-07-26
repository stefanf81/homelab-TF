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
cilium install --version 1.19.6
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
image: ghcr.io/stefanf81/taskflow-enterprise/taskflow-backend:latest # {"$imagepolicy": "flux-system:taskflow-backend"}
# gitops/apps/taskflow/frontend.yaml
image: ghcr.io/stefanf81/taskflow-enterprise/taskflow-frontend:latest # {"$imagepolicy": "flux-system:taskflow-frontend"}
```
Flux then emits `ghcr.io/stefanf81/taskflow-enterprise/taskflow-backend:latest@sha256:<digest>`.

**Correct form for HelmRelease** (separate fields) is the only place `:digest`
belongs:
```yaml
image:
  repository: ghcr.io/stefanf81/podinfo # {"$imagepolicy": "flux-system:policy:name"}
  tag: latest                           # {"$imagepolicy": "flux-system:policy:tag"}
  digest: sha256:…                      # {"$imagepolicy": "flux-system:policy:digest"}
```

### 7.4 Troubleshooting: image automation stuck or controllers missing

**Symptom:** A new `:latest` is pushed to ghcr.io but the cluster never rolls out.
The `ImageUpdateAutomation` shows `GitOperationFailed`, or the controller pods
don't exist:

```bash
kubectl -n flux-system get pods -l app.kubernetes.io/component=image-reflector-controller
# No resources found
```

**Root cause:** The image automation controllers (`image-reflector-controller` and
`image-automation-controller`) are **not** installed by `flux bootstrap` — they
require the `--components-extra` flag. If someone re-bootstraps Flux or the
controllers are otherwise removed, the automation breaks silently. Existing
`ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` resources can also get
stuck in a terminating state with finalizers (`DeletionTimestamp` set) because
the missing controllers can never process the finalizer cleanup.

**Full diagnostic checklist:**

```bash
# 1. Are the controller pods running?
kubectl -n flux-system get pods -l app.kubernetes.io/component=image-reflector-controller
kubectl -n flux-system get pods -l app.kubernetes.io/component=image-automation-controller

# 2. Are the image CRDs installed?
kubectl api-resources --api-group=image.toolkit.fluxcd.io

# 3. Are resources stuck terminating?
kubectl -n flux-system get imagerepository,imagepolicy,imageupdateautomation \
  -o jsonpath='{range .items[*]}{.metadata.name}{" deletionTimestamp="}{.metadata.deletionTimestamp}{"\n"}{end}'

# 4. Does the ImageRepository scan succeed?
kubectl -n flux-system get imagerepository taskflow-backend \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'

# 5. Does the ImageUpdateAutomation push succeed?
kubectl -n flux-system get imageupdateautomation taskflow-images \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq .

# 6. Is the Git credential valid?
kubectl -n flux-system get gitrepository flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq .
```

**Fix — install missing controllers:**

```bash
# Extract only the image-controller manifests from a full Flux install export:
flux install \
  --components-extra=image-reflector-controller,image-automation-controller \
  --export > /tmp/flux-image-controllers.yaml

# Filter to just the image-reflector and image-automation resources
python3 -c "
import yaml
with open('/tmp/flux-image-controllers.yaml') as f:
    docs = list(yaml.safe_load_all(f))
keep = [d for d in docs if d and ('image-reflector' in yaml.dump(d) or 'image-automation' in yaml.dump(d))]
with open('/tmp/flux-image-only.yaml', 'w') as f:
    yaml.dump_all(keep, f)
"

kubectl apply -f /tmp/flux-image-only.yaml
```

**Fix — unstick terminating resources (only needed if resources have
`deletionTimestamp` set):**

```bash
# Patch away the finalizer so the resource can be garbage-collected
kubectl -n flux-system patch <resource-type>/<resource-name> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# Flux Kustomization will recreate it from Git
kubectl -n flux-system annotate kustomization/taskflow-app \
  fluxcd.io/reconcileAt=$(date +%Y-%m-%dT%H:%M:%S%z) --overwrite
```

**Fix — force a full end-to-end cycle after controllers are up:**

```bash
# 1. Force the app kustomization to recreate automation resources
kubectl -n flux-system annotate kustomization/taskflow-app \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 2. Wait for ImageRepository then force an immediate ghcr.io scan
kubectl -n flux-system wait --for=condition=Ready imagerepository/taskflow-backend --timeout=60s
kubectl -n flux-system annotate imagerepository/taskflow-backend \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite
kubectl -n flux-system annotate imagerepository/taskflow-frontend \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 3. Check what digest the ImagePolicy resolved
kubectl -n flux-system get imagepolicy taskflow-backend \
  -o jsonpath='{.status.latestImage}'

# 4. Force the ImageUpdateAutomation to commit the new digest to Git
kubectl -n flux-system annotate imageupdateautomation/taskflow-images \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 5. Check that the commit succeeded
kubectl -n flux-system describe imageupdateautomation taskflow-images

# 6. Force the app kustomization to pull the new Git commit and roll out pods
kubectl -n flux-system annotate kustomization/taskflow-app \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 7. Watch the new pods start
kubectl -n taskflow get pods -w
```

### 7.5 Quick reference: force an immediate image update cycle

In normal operation the automation runs every 10 minutes. When you've just
pushed a new `:latest` to ghcr.io and don't want to wait, run these:

```bash
# 1. Force scan ghcr.io for new digests
kubectl -n flux-system annotate imagerepository/taskflow-backend \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite
kubectl -n flux-system annotate imagerepository/taskflow-frontend \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 2. Check if a new digest was found
kubectl -n flux-system get imagepolicy taskflow-backend \
  -o jsonpath='{.status.latestImage}'
kubectl -n flux-system get imagepolicy taskflow-frontend \
  -o jsonpath='{.status.latestImage}'

# 3. Commit the new digest to Git
kubectl -n flux-system annotate imageupdateautomation/taskflow-images \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 4. Roll out the new commit to the cluster
kubectl -n flux-system annotate kustomization/taskflow-app \
  fluxcd.io/reconcileAt="$(date +%Y-%m-%dT%H:%M:%S%z)" --overwrite

# 5. Watch pods restart
kubectl -n taskflow get pods -w
```

### 7.6 Verify the pipeline end-to-end

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
`ghcr.io/stefanf81/taskflow-enterprise/taskflow-backend:latest@sha256:…`, and a `fluxcdbot` commit
(`chore: automated TaskFlow image update`) appears on `main`.
