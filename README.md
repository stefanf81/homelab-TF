# Homelab OpenTofu

Single-root OpenTofu project for provisioning a Proxmox VM and bootstrapping k3s.
Cluster add-ons are now scaffolded for GitOps under `gitops/` rather than being
managed directly by Terraform.

## Layout

- `modules/proxmox` – provisions the VM; cloud-init installs k3s at boot (no SSH provisioner needed for this part, per [Terraform's own guidance](https://developer.hashicorp.com/terraform/language/post-apply-operations) to prefer cloud-init over provisioners)
- `modules/k3s-kubeconfig` – waits for cloud-init's k3s install to finish, then fetches `kubeconfig.yaml` over SSH
- `modules/flux-bootstrap` – future GitHub-ready Flux bootstrap module template (prepared but not wired in yet)
- `gitops/` – Flux-style GitOps layout for MetalLB, Longhorn, and cert-manager

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
* **Modern Kubernetes Gateway API:** Deployed the standard Gateway API CRDs (`gateway-api-crds`) and enabled Cilium's built-in Gateway API controller. Traffic is routed using standard, modern `Gateway` and `HTTPRoute` resources rather than legacy Ingress.
* **Consolidated Hostname Routing:** The TaskFlow app is exposed securely on port `80` under the hostname **`taskflow.local`**. The single gateway routes `/` to the Frontend, `/api` to the Backend, and `/jaeger` to the Jaeger telemetry UI, leaving Services as secure `ClusterIP` resources.
* **ServiceLB Deconfliction:** K3s's built-in, low-performance `ServiceLB` is disabled (`--disable servicelb`), and **MetalLB** handles IP pool allocations matching your homelab subnet (`192.168.50.200 - 192.168.50.250`).

### 3. Storage Resiliency & Performance
* **Resilient Distributed Storage Class:** The PostgreSQL Database (`postgres-pvc.yaml`) volume mapping is scaled from a restrictive `1Gi` to **`10Gi`** and explicitly bound to the **Longhorn** replica-replicated storage engine (`storageClassName: longhorn`).
* **Longhorn Single-Node Efficiency:** The Longhorn configuration (`gitops/infrastructure/controllers/longhorn/release.yaml`) has been optimized to limit standard replica counts to 1 (`defaultClassReplicaCount: 1`), keeping volumes healthy on a single-node homelab without warning indicators.

### 4. Database Engine Performance Tuning
* **PostgreSQL Engine RAM Tuning:** The database deployment (`postgres-db.yaml`) has been injected with optimized database startup arguments to utilize its 1536Mi RAM container limit effectively, replacing standard, extremely conservative container defaults:
  * `shared_buffers = 256MB` (optimizes memory-resident caching)
  * `effective_cache_size = 768MB` (improves query planning calculations)
  * `work_mem = 8MB` (faster complex sorting/aggregation; kept modest to bound concurrent memory use)
  * `maintenance_work_mem = 64MB` (faster index rebuilds/VACUUM)
  * `max_connections = 30` (prevents connection overhead bloat; sized for a single-node homelab backend)
* **Redis Cache Memory Guard:** The Redis deployment (`redis.yaml`) runs with `--maxmemory 384mb` and `--maxmemory-policy allkeys-lru`, capping memory well under its 512Mi container limit so the cache evicts LRU keys under pressure instead of being OOM-killed (which would drop the whole cache and stampede PostgreSQL). Redis is an ephemeral L2 cache on an `emptyDir`; no RDB/AOF persistence is configured.
* **JVM Heap & GC Tuning:** The backend (`backend.yaml`) sets `JAVA_TOOL_OPTIONS` to a fixed 1.5 GB heap (`-Xms1536m -Xmx1536m`), the G1 garbage collector, fail-fast on OOM (`-XX:+ExitOnOutOfMemoryError`), and `-XX:+UseStringDeduplication` to shrink heap for string-heavy workloads. Off-heap caps (metaspace/direct memory) are intentionally left uncapped pending metrics.

### 5. GitOps Secrets Protection
* **SOPS Integration Ready:** A standard `.sops.yaml` configuration is located at the root of the project to facilitate secure, encrypted secrets workflow in Flux. This allows encrypting `gitops/apps/taskflow/taskflow-secrets.yaml` natively.

## Preflight checklist

Before your first real deploy, verify these three items:

1. Create a remote Git repository and wire Flux bootstrap to it.
2. Replace or verify the MetalLB IP range in `gitops/infrastructure/configs/metallb/ipaddresspool.yaml` (pre-configured for your 192.168.50.x network).
3. Run a test deploy of the Proxmox + cloud-init bootstrap path and confirm:
   - VM boots successfully
   - k3s installs on boot
   - `kubeconfig.yaml` is fetched successfully
   - SSH access works

## Notes

- The kubeconfig is written to `kubeconfig_path` (default `./kubeconfig.yaml`).
- `k3s_token` and `docker_hub_mirror` are consumed by `modules/proxmox` and
  baked into the VM's cloud-init user-data.
- The `gitops/` directory is local scaffolding for now. Once you create a remote
  Git repository, push that directory there and then wire in
  `modules/flux-bootstrap` to install Flux against it.
- See `gitops/FUTURE_FLUX_BOOTSTRAP.md` and `modules/flux-bootstrap/README.md`
  for the exact future GitHub + PAT bootstrap wiring.
