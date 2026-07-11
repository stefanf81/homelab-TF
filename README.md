# Homelab OpenTofu

Single-root OpenTofu project for provisioning a Proxmox VM and bootstrapping k3s.
Cluster add-ons are now scaffolded for GitOps under `gitops/` rather than being
managed directly by Terraform.

## Layout

- `modules/proxmox` – provisions the VM; cloud-init installs k3s at boot (no SSH provisioner needed for this part, per [Terraform's own guidance](https://developer.hashicorp.com/terraform/language/post-apply-operations) to prefer cloud-init over provisioners)
- `modules/k3s-kubeconfig` – waits for cloud-init's k3s install to finish, then fetches `kubeconfig.yaml` over SSH
- `modules/flux-bootstrap` – **planned, not yet created**; a future GitHub-ready Flux bootstrap module (see `gitops/FUTURE_FLUX_BOOTSTRAP.md` for the manual steps)
- `gitops/` – Flux-style GitOps layout for Cilium L2 announcements, Proxmox CSI, and cert-manager

## Workflow

Use the Makefile to enforce the correct sequence:

```bash
make init
make apply
```

If you want to run phases manually:

```bash
make provision   # create the VM (k3s installs itself via cloud-init)
make kubeconfig  # wait for k3s + fetch kubeconfig.yaml
```

## Fresh Proxmox → current cluster bootstrap

This is the intended bring-up order for a brand-new Proxmox VM and a fresh k3s
cluster that ends in the current GitOps layout.

### 1) Provision the VM and fetch kubeconfig

```bash
make init
make provision
make kubeconfig
```

### 2) Install the Cilium CLI on your workstation

macOS example:

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=arm64
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}
shasum -a 256 -c cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-darwin-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}
```

### 3) Install Cilium on the k3s cluster

This repo disables k3s Flannel, so Cilium is installed on top of a CNI-free
cluster:

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
cilium install --version 1.16.1
cilium status --wait
```

If the node is still NotReady or Cilium stalls, check the Cilium pods/logs and
fix networking before continuing.

### 4) Seed the Flux SOPS age key once

Flux decrypts `*-secrets.yaml` using the `sops-age` secret in `flux-system`.
Seed it once before first reconciliation:

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt
```

### 5) Bootstrap Flux and reconcile

`gotk-components.yaml` / `gotk-sync.yaml` already live under
`gitops/clusters/taskflow/flux-system/`.

```bash
kubectl apply -k gitops/clusters/taskflow/flux-system
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
```

### 6) Verify the app stack

```bash
kubectl get pods -A
kubectl get gateway,httproute -n taskflow
kubectl get secret -n taskflow db-secret backend-secret
```

## Why it's still phased

k3s installation no longer needs an SSH provisioner — it happens automatically
at boot via cloud-init, same as the rest of the OS tuning. The kubeconfig file still only exists once cloud-init has finished
running on the VM. So `modules/k3s-kubeconfig` remains as a small bridge that
waits for that file and downloads it — everything else is boot-time, not
apply-time-scripted.

## Built-in Enterprise Optimizations

To ensure production-grade security, resiliency, and performance on your single-node Homelab, several key optimizations are pre-baked into this project:

### 1. Control Plane & Provisioning Stability
* **Reconstruction-Aware Kubeconfig Sync:** The `fetch_kubeconfig` module is linked to the Proxmox VM instance ID trigger. If you destroy or rebuild the VM, OpenTofu detects the change in VM ID and automatically triggers a re-fetch of the kubeconfig, avoiding stale certificate errors.
* **Syntax-Safe Cloud-Init Snippets:** Cloud-init user-data heredocs are defined from column 0 of line 1 to prevent silent whitespace parsing errors, securing predictable boot-time system configurations.

### 2. Cilium CNI, Network Security & Gateway API (Consolidated)
* **High-Performance CNI (Cilium):** Disabled K3s's default flannel CNI (`--flannel-backend=none`) and default network policies (`--disable-network-policy`) inside `modules/proxmox/main.tf` to let **Cilium v1.16.1** serve as the single, high-performance CNI and security engine.
* **Modern Kubernetes Gateway API:** Deployed the standard Gateway API CRDs (`gateway-api`) and enabled Cilium's built-in Gateway API controller. Traffic is routed using standard, modern `Gateway` and `HTTPRoute` resources rather than legacy Ingress.
* **Consolidated Hostname & Wildcard IP Routing:** The TaskFlow app and monitoring stack are exposed securely on port `80`. Because they are wildcard-routed, they can be accessed directly via your Gateway's External IP (e.g. `http://<EXTERNAL-IP>/` or `http://<EXTERNAL-IP>/grafana`) or via zero-config wildcard public DNS (e.g. `<EXTERNAL-IP>.nip.io`) without altering `/etc/hosts`. See [Gateway Access Guide](docs/GATEWAY_ACCESS_GUIDE.md) for full instructions. (Jaeger UI is **intentionally not** exposed through the Gateway — reach it via `kubectl port-forward`, see ISSUES.md #2.)
* **ServiceLB Deconfliction:** K3s's built-in, low-performance `ServiceLB` is disabled (`--disable servicelb`), and **Cilium L2 announcements** (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`) handle IP pool allocations matching your homelab subnet (`192.168.50.200 - 192.168.50.250`).

### 3. Storage Resiliency & Performance
* **Proxmox CSI Volume Storage:** The PostgreSQL Database (`postgres-pvc.yaml`) volume mapping is scaled from a restrictive `1Gi` to **`10Gi`** and explicitly bound to the **Proxmox CSI** storage class (`storageClassName: proxmox-csi`). Volume lifecycle, sizing, and disk attachments are dynamically provisioned on your Proxmox node, with backing snapshots and backups handled natively at the hypervisor layer.

### 4. Database Engine Performance Tuning
* **PostgreSQL Engine RAM Tuning:** The database deployment (`postgres-db.yaml`) has been injected with optimized database startup arguments to utilize its 1024Mi RAM container limit effectively, replacing standard, extremely conservative container defaults:
  * `shared_buffers = 384MB` (optimizes memory-resident caching; matches the container's 1024Mi cap)
  * `effective_cache_size = 700MB` (planner hint for cached data; was overstated at 1152MB — see docs/PERFORMANCE.md #2.1)
  * `work_mem = 8MB` (faster complex sorting/aggregation; kept modest to bound concurrent memory use)
  * `maintenance_work_mem = 64MB` (faster index rebuilds/VACUUM)
  * `max_connections = 30` (prevents connection overhead bloat; sized for a single-node homelab backend)
* **Redis Cache Memory Guard:** The Redis deployment (`redis.yaml`) runs with `--maxmemory 384mb` and `--maxmemory-policy allkeys-lru`, capping memory well under its 512Mi container limit so the cache evicts LRU keys under pressure instead of being OOM-killed (which would drop the whole cache and stampede PostgreSQL). Redis is an ephemeral L2 cache on an `emptyDir`; no RDB/AOF persistence is configured.
* **JVM Heap & GC Tuning:** The backend (`backend.yaml`) sets `JAVA_TOOL_OPTIONS` to a fixed 1 GB heap (`-Xms1024m -Xmx1024m`), the G1 garbage collector, fail-fast on OOM (`-XX:+ExitOnOutOfMemoryError`), `-XX:+UseStringDeduplication`, and **bounded off-heap** (`-XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=512m`) so a benign native-memory spike can't trip `ExitOnOutOfMemoryError` and restart the pod (see docs/PERFORMANCE.md #1.1). The pod runs as **Guaranteed QoS** (`requests == limits = 2Gi` CPU/memory) so the full budget is reserved and CPU is never throttled.

### 5. GitOps Secrets Protection
* **SOPS Integration Ready:** A standard `.sops.yaml` configuration is located at the root of the project to facilitate secure, encrypted secrets workflow in Flux. This allows encrypting `gitops/apps/taskflow/taskflow-secrets.yaml` natively.

## Preflight checklist

Before your first real deploy, verify these three items:

1. Create a remote Git repository and wire Flux bootstrap to it.
2. Replace or verify the Cilium IP pool range in `gitops/infrastructure/configs/cilium/ippool.yaml` (pre-configured for your 192.168.50.x network).
3. Run a test deploy of the Proxmox + cloud-init bootstrap path and confirm:
   - VM boots successfully
   - k3s installs on boot
   - `kubeconfig.yaml` is fetched successfully
   - SSH access works

## Provider Plugin Cache

To avoid re-downloading provider binaries (the `bpg/proxmox` provider alone is
tens of MB, and they can reach hundreds of MB) on every `init`/`plan`/`apply`/
`destroy`, this project points OpenTofu at a shared, project-local plugin cache
via `TF_PLUGIN_CACHE_DIR` (set in the `Makefile`).

- Cache location: `$(ROOT)/.terraform/providers-cache` (under `.terraform/`, so
  it is already excluded from version control).
- OpenTofu populates and reuses the cache automatically — the first `tofu init`
  downloads into the cache, subsequent runs link from it (instant).
- The directory is created for you by the `ensure-cache` step that every `tofu`
  target depends on, so you never have to create it manually.

### Useful targets

```bash
make cache        # show cache path and current on-disk size
make cache-clean  # wipe cached provider binaries (re-downloaded on next init)
```

### Using the cache outside `make`

The cache is only wired in for `make` targets. To get the same behavior when
running `tofu` directly, either export the variable in your shell:

```bash
export TF_PLUGIN_CACHE_DIR="$PWD/.terraform/providers-cache"
```

…or create a project-local CLI config file (e.g. `tofu.tfrc`) with:

```hcl
plugin_cache_dir = ".terraform/providers-cache"
```

and point OpenTofu at it:

```bash
export TF_CLI_CONFIG_FILE="$PWD/tofu.tfrc"
```

> Note: the cache directory must not be one of OpenTofu's implied filesystem
> mirror directories (`terraform.d/plugins`); `.terraform/providers-cache` is safe.

## Notes

- The kubeconfig is written to `kubeconfig_path` (default `./kubeconfig.yaml`).
- `k3s_token` and `docker_hub_mirror` are consumed by `modules/proxmox` and
  baked into the VM's cloud-init user-data.
- The `gitops/` directory is local scaffolding for now. Once you create a remote
  Git repository, push that directory there and then bootstrap Flux against it
  manually — the `modules/flux-bootstrap` Terraform module is **planned but not yet
  created** (see `gitops/FUTURE_FLUX_BOOTSTRAP.md` for the exact steps).
