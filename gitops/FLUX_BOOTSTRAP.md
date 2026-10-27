# TaskFlow bootstrap checklist

This is the end-to-end path from a fresh Proxmox VM to the current TaskFlow
GitOps state.

## 0. Prereqs

- A remote Git repository containing this tree
- `tofu`, `kubectl`, `helm`, `flux`, and the Cilium CLI on your workstation
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
cilium install --version 1.20.4
cilium status --wait
```

If the node stays NotReady, fix Cilium before moving on.

## 3. Install the Flux Operator

Flux is installed and upgraded by the Flux Operator from the `FluxInstance` in
`gitops/infrastructure/flux-instance/flux-instance.yaml` (all six controllers,
including image automation). Install the operator by hand once; after the first
sync, the `flux-operator` HelmRelease in Git adopts this release (same name and
namespace) and keeps it updated.

```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --create-namespace
```

## 4. Seed the Git, SOPS and GHCR secrets

The `FluxInstance` syncs over HTTPS with the `flux-system` basic-auth Secret; the
token needs write access because image automation pushes digest pins (see 7.1).
Flux decrypts `*-secrets.yaml` via the `sops-age` Secret. The WAF and application
images also require the manually managed GHCR pull secret before `taskflow-app`
reconciles. Create all of them before applying the `FluxInstance`.

```bash
kubectl -n flux-system create secret generic flux-system \
  --from-literal=username=<github-user> \
  --from-literal=password=<PAT with contents:write>

kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt

kubectl create namespace taskflow --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry ghcr-pull-secret -n taskflow \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<read-packages-token>
```

## 5. Apply the FluxInstance

The operator deploys the controllers and creates the `flux-system`
GitRepository + Kustomization that sync `gitops/clusters/taskflow`.

```bash
kubectl apply -f gitops/infrastructure/flux-instance/flux-instance.yaml
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
flux get kustomization flux-system
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
kubectl get secret -n taskflow db-secret backend-secret redis-secret taskflow-jwt-keys
```

## 7. Image automation (`:latest` digest pinning) — critical gotchas

TaskFlow's backend/frontend run the mutable `:latest` tag. Flux pins the
current digest and commits `repo:latest@sha256:<digest>` to Git so every rollout
is auditable and automatic when a new `:latest` is pushed to ghcr. This is wired
in `gitops/clusters/taskflow/image-automation/` (ImageRepository +
ImagePolicy + ImageUpdateAutomation) and the `# {"$imagepolicy": ...}` markers in
`gitops/apps/taskflow/backend.yaml` and `frontend.yaml`.

Two things broke this in the past (with the old `flux bootstrap` install). Both
were hit and fixed; document them so they aren't hit again.

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
3. Keep `spec.sync.url` in `gitops/infrastructure/flux-instance/flux-instance.yaml`
   on HTTPS (`pullSecret: flux-system` stays the same):
   ```yaml
   url: https://github.com/stefanf81/homelab-TF.git   # not ssh://git@github.com/...
   ```
4. Force a reconcile:
   ```bash
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

### 7.4 Troubleshooting: image automation stuck or controllers missing

**Symptom:** A new `:latest` is pushed to ghcr.io but the cluster never rolls out.
The `ImageUpdateAutomation` shows `GitOperationFailed`, or the controller pods
don't exist:

```bash
kubectl -n flux-system get pods -l app.kubernetes.io/component=image-reflector-controller
# No resources found
```

**Root cause:** The image controllers are declared in the `FluxInstance`
(`gitops/infrastructure/flux-instance/flux-instance.yaml`), so they only go
missing if the operator is down or the component was dropped from that list.
Before the operator they were applied by hand and lost on every regeneration
of the bootstrap manifests. Existing `ImageRepository`/`ImagePolicy`/
`ImageUpdateAutomation` resources can get stuck terminating with finalizers
(`DeletionTimestamp` set) while the controllers are missing.

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

**Fix — restore missing controllers:**

```bash
# Is the operator running and the instance Ready?
kubectl -n flux-system get deploy flux-operator
kubectl -n flux-system get fluxinstance flux
kubectl -n flux-system get fluxinstance flux -o jsonpath='{.spec.components}'

# Make the operator re-apply the distribution immediately
kubectl -n flux-system annotate fluxinstance/flux \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

**Fix — unstick terminating resources (only needed if resources have
`deletionTimestamp` set):**

```bash
# Patch away the finalizer so the resource can be garbage-collected
kubectl -n flux-system patch <resource-type>/<resource-name> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# Flux Kustomization will recreate it from Git
kubectl -n flux-system annotate kustomization/taskflow-app \
  reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite
```

**Fix — force a full end-to-end cycle after controllers are up:**

```bash
# 1. Force the app kustomization to recreate automation resources
kubectl -n flux-system annotate kustomization/taskflow-app \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 2. Wait for ImageRepository then force an immediate ghcr.io scan
kubectl -n flux-system wait --for=condition=Ready imagerepository/taskflow-backend --timeout=60s
kubectl -n flux-system annotate imagerepository/taskflow-backend \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system annotate imagerepository/taskflow-frontend \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 3. Check what digest the ImagePolicy resolved
kubectl -n flux-system get imagepolicy taskflow-backend \
  -o jsonpath='{.status.latestImage}'

# 4. Force the ImageUpdateAutomation to commit the new digest to Git
kubectl -n flux-system annotate imageupdateautomation/taskflow-images \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 5. Check that the commit succeeded
kubectl -n flux-system describe imageupdateautomation taskflow-images

# 6. Force the app kustomization to pull the new Git commit and roll out pods
kubectl -n flux-system annotate kustomization/taskflow-app \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 7. Watch the new pods start
kubectl -n taskflow get pods -w
```

### 7.5 Quick reference: force an immediate image update cycle

In normal operation the automation runs every 10 minutes. When you've just
pushed a new `:latest` to ghcr.io and don't want to wait, run these:

```bash
# 1. Force scan ghcr.io for new digests
kubectl -n flux-system annotate imagerepository/taskflow-backend \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system annotate imagerepository/taskflow-frontend \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 2. Check if a new digest was found
kubectl -n flux-system get imagepolicy taskflow-backend \
  -o jsonpath='{.status.latestImage}'
kubectl -n flux-system get imagepolicy taskflow-frontend \
  -o jsonpath='{.status.latestImage}'

# 3. Commit the new digest to Git
kubectl -n flux-system annotate imageupdateautomation/taskflow-images \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 4. Roll out the new commit to the cluster
kubectl -n flux-system annotate kustomization/taskflow-app \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

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
`ghcr.io/stefanf81/taskflow-backend:latest@sha256:…`, and a `fluxcdbot` commit
(`chore: automated TaskFlow image update`) appears on `main`.
