# TaskFlow bootstrap checklist

This is the end-to-end path from a fresh Proxmox VM to the current TaskFlow
GitOps state.

## 0. Prereqs

- The workstation tools and Proxmox access listed in the root `README.md` (`mise install`)
- A remote Git repository containing this tree
- The SOPS age private key present locally, with `SOPS_AGE_KEY_FILE` pointing at it (`docs/SOPS.md` §2)

## 1. Provision the VM and fetch kubeconfig

Fill in `terraform.tfvars` first (root `README.md`, step 1).

```bash
make init
make apply   # VM + kubeconfig fetch in one plan (make provision / make kubeconfig are debug-only)
export KUBECONFIG=$PWD/kubeconfig.yaml
```

If the fetch fails or the file is damaged, copy it by hand (umask keeps it private) and check
it:

```bash
(umask 077 && ssh ubuntu@192.168.50.55 "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed 's#https://127.0.0.1:6443#https://192.168.50.55:6443#' > ./kubeconfig.yaml)
kubectl --kubeconfig ./kubeconfig.yaml get nodes
```

`yaml: found character that cannot start any token` (stray code fences, tabs) or
`tls: failed to find any PEM data` (truncated base64 certificate data) mean the file was
copied through a browser or chat; fetch it again over SSH as above.

## 2. Bootstrap the pre-Flux foundation (Gateway API CRDs, Cilium, CoreDNS, Flux Operator)

The VM boots k3s without a CNI, kube-proxy or CoreDNS (`flannel-backend: none`,
`disable-kube-proxy: true` and `coredns` in `disable:`, in `/etc/rancher/k3s/config.yaml`).
Two deadlocks occur if you try to run bare `cilium install` or install Flux directly on a
fresh node:

1. Without `kube-proxy`, `cilium-agent` needs `kubeProxyReplacement: true` +
   `k8sServiceHost: ${NODE_IP}` (`6443`), `ipam.mode: kubernetes`, and the
   Gateway API CRDs (`gatewayAPI.enabled: true`) — bare `cilium install` sets
   none of those (`cluster-pool` IPAM, dials `10.43.0.1:443`, hangs).
2. Without CoreDNS on `10.43.0.10:53`, `flux-operator` (pulling `flux-manifests`
   from `ghcr.io`) and `source-controller` (cloning `github.com` and pulling OCI
   charts) fail in-pod DNS lookups before Flux can ever reconcile `coredns`.

`make bootstrap-foundation` (`scripts/bootstrap-foundation.sh`) applies the
Gateway API CRDs (`--server-side`) and installs `cilium`, `coredns`, and
`flux-operator` from the **exact** pinned OCI chart versions and `cluster-vars`-
substituted `.spec.values` in `gitops/infrastructure/controllers/`. After the
first Flux sync, the matching `HelmRelease`s adopt all three releases in place:

```bash
make bootstrap-foundation
```

## 3. Seed the Git, SOPS and GHCR secrets

The `FluxInstance` syncs over HTTPS with the `flux-system` basic-auth Secret; the
token needs write access because image automation pushes digest pins (see §6.1).
Flux decrypts `*-secrets.yaml` via the `sops-age` Secret. Create `ghcr-pull-secret`
in `taskflow` as well (`trivy-operator` also reads `taskflow/ghcr-pull-secret` via
`privateRegistryScanSecretsNames`). Seed all three **before** applying `FluxInstance`:

```bash
kubectl -n flux-system create secret generic flux-system \
  --from-literal=username=<github-user> \
  --from-literal=password=<PAT with contents:write>

kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey="$SOPS_AGE_KEY_FILE"

kubectl create namespace taskflow --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry ghcr-pull-secret -n taskflow \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<read-packages-token>
```

New environment with your own age key: the committed `*-secrets.yaml` only decrypt with the
original key, so write your own values and re-encrypt them first (`docs/SOPS.md` §4).

## 4. Apply the FluxInstance and reconcile layers

The operator deploys all six Flux controllers and creates the `flux-system`
`GitRepository` + `Kustomization` that sync `gitops/clusters/taskflow`.

> **TLS / HTTP-01 note:** `taskflow-app` (`wait: true`) includes `Certificate/taskflow-jokelab-cert`
> (`letsencrypt-http01-production` across all 5 SANs). Public DNS and WAN 80/443
> port-forwarding to `GATEWAY_IP` must be reachable so the HTTP-01 challenge completes.

```bash
kubectl apply -f gitops/infrastructure/flux-instance/flux-instance.yaml
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
flux get kustomization flux-system

flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization falco -n flux-system
flux reconcile kustomization abuseipdb -n flux-system
flux reconcile kustomization trivy-operator -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
flux reconcile kustomization reloader -n flux-system
flux reconcile kustomization monitoring -n flux-system
flux reconcile kustomization monitoring-app -n flux-system
flux reconcile kustomization kyverno-policies -n flux-system
flux reconcile kustomization policy-reporter -n flux-system
flux reconcile kustomization hubble-ui -n flux-system
flux reconcile kustomization renovate -n flux-system
flux reconcile kustomization renovate-job -n flux-system
flux reconcile kustomization monitoring-logging -n flux-system
```

## 5. Verify

```bash
kubectl get pods -A
kubectl get gateway,httproute -A
kubectl get secret -n taskflow db-secret backend-secret redis-secret taskflow-jwt-keys cloudflare-secret
```

## 6. Image automation (`:latest` digest pinning) — critical gotchas

TaskFlow's backend/frontend run the mutable `:latest` tag. Flux pins the
current digest and commits `repo:latest@sha256:<digest>` to Git so every rollout
is auditable and automatic when a new `:latest` is pushed to ghcr. This is wired
in `gitops/clusters/taskflow/image-automation/` (ImageRepository +
ImagePolicy + ImageUpdateAutomation) and the `# {"$imagepolicy": ...}` markers in
`gitops/apps/taskflow/backend.yaml` and `frontend.yaml`. Two requirements are easy
to break:

### 6.1 The Git source MUST be writable

Flux only needs read access to pull, but `ImageUpdateAutomation` **pushes** the
digest-pin commits with the same `flux-system` credential. A read-only credential
fails with `GitOperationFailed` (`failed to push to remote`, or "key … marked as read
only" for an SSH deploy key):

```bash
kubectl -n flux-system events --for imageupdateautomation/taskflow-images | tail -10
```

**Fix:** use a GitHub PAT with `contents:write` in the basic-auth `flux-system` Secret
(§3) and keep `spec.sync.url` in `gitops/infrastructure/flux-instance/flux-instance.yaml`
on HTTPS. To replace the token:

```bash
kubectl -n flux-system create secret generic flux-system \
  --from-literal=username=<github-user> --from-literal=password=<PAT> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system annotate imageupdateautomation taskflow-images \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

> ⚠️ Treat any PAT pasted into chat or shell history as compromised and rotate it.

### 6.2 Use the *basic* marker on Deployment `image:` lines (not `:digest`)

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
Flux then emits `ghcr.io/stefanf81/taskflow-backend:latest@sha256:<digest>`. The
`:name`/`:tag`/`:digest` markers are only for Helm values that keep those as
separate fields.

### 6.3 Troubleshooting: image automation stuck or controllers missing

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
Existing `ImageRepository`/`ImagePolicy`/
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

# Root Kustomization (`flux-system`) owns `./gitops/clusters/taskflow/image-automation`
kubectl -n flux-system annotate kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

Once the controllers are back, run §6.4 to push a cycle through.

### 6.4 Quick reference: force an immediate image update cycle

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

# 4. Pull the new commit and roll out to the cluster
flux reconcile source git flux-system
kubectl -n flux-system annotate kustomization/taskflow-app \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

# 5. Watch pods restart
kubectl -n taskflow get pods -w
```

### 6.5 Verify the pipeline end-to-end

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

## 7. Existing node: hand CoreDNS over to Flux

CoreDNS is managed by Flux (`gitops/infrastructure/controllers/coredns/`), including the
LAN hairpin-NAT `hosts` overrides for the public hostnames. Never patch the live CoreDNS
ConfigMap; change the HelmRelease and commit.

New nodes get `coredns` in the k3s `disable:` list from cloud-init. A node installed
before that still runs the packaged addon; migrate it in a maintenance window. Keep the
existing settings in `/etc/rancher/k3s/config.yaml` and make the single `disable:` list
name every disabled component, as `modules/proxmox/main.tf` writes it. `--disable` flags
still on the unit's `ExecStart` replace the YAML list entirely, so move them into
`config.yaml` first (`docs/reports/REMEDIATION_PLAN_2026-10.md` REL-00):

```yaml
disable:
  - servicelb
  - traefik
  - coredns
  - metrics-server
  - local-storage
```

Then restart k3s and let Flux take ownership at once:

```bash
sudoedit /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
flux reconcile kustomization infra-controllers -n flux-system
kubectl -n kube-system rollout status deployment/coredns --timeout=5m
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslice -l k8s-app=kube-dns
```
