# TaskFlow Homelab — OpenTofu & Flux CD

Single-root OpenTofu project for provisioning a Proxmox VE VM and bootstrapping k3s.
Cluster workloads and platform controllers are managed declaratively through GitOps (`gitops/`) using Flux CD v2.

---

## 🛠 Prerequisites

Before starting bring-up from scratch, ensure the following CLI tools are installed on your workstation:

- **IaC & Automation:** [OpenTofu](https://opentofu.org/) (≥ 1.8.0), `make`
- **Kubernetes Management:** `kubectl`, [Flux CLI](https://fluxcd.io/flux/cmd/) (≥ 2.x), [Cilium CLI](https://github.com/cilium/cilium-cli)
- **Secrets Management:** [SOPS](https://github.com/getsops/sops) (≥ v3.9), [age](https://github.com/FiloSottile/age)

You also need access to a **Proxmox VE 8.x** host with an API token (with VM creation, Datastore, and Network privileges).

---

## 📁 Repository Layout

- `modules/proxmox` – Provisions the Ubuntu 26.04 VM; cloud-init installs k3s at boot (no SSH provisioners, per OpenTofu best practice).
- `modules/k3s-kubeconfig` – SSHs into the node once cloud-init finishes, fetches `/etc/rancher/k3s/k3s.yaml`, and writes a local `kubeconfig.yaml`.
- `gitops/` – Declarative Flux v2 manifests:
  - `gitops/infrastructure/controllers` – Cilium v1.19.6, cert-manager, Proxmox CSI, Kyverno, Falco, Policy Reporter, Trivy Operator.
  - `gitops/infrastructure/configs` – Cilium L2 announcement policy (`192.168.50.200-250`), `GatewayClass`.
  - `gitops/apps/taskflow` – Spring Boot 3.5.3 backend, Angular 22 frontend, PostgreSQL 18, Redis 8.8, Jaeger.
  - `gitops/monitoring` – VictoriaMetrics TSDB + Grafana operator stack + metrics-server.
  - `gitops/clusters/taskflow` – Cluster root Kustomizations.

---

## 🚀 Bring-Up Workflow (Fresh Proxmox → Production Cluster)

Follow these exact steps to provision the VM and bootstrap the entire GitOps stack from scratch.

### 1️⃣ Configure Infrastructure Variables (`terraform.tfvars`)

Copy the example configuration and fill in your Proxmox credentials, networking, and SSH keys:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
proxmox_endpoint  = "https://192.168.50.50:8006/"
proxmox_api_token = "root@pam!token_id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_node      = "homelab"
datastore_id      = "local-lvm"
network_bridge    = "vmbr0"
ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
ip_address        = "192.168.50.55/24"
gateway           = "192.168.50.1"
k3s_token         = "a-secure-cluster-token-here"
```

### 2️⃣ Provision the Proxmox VM & Fetch `kubeconfig`

Initialize OpenTofu (utilizes project-local plugin caching in `.terraform/providers-cache`) and apply the configuration:

```bash
make init
make apply
```

*Or run manually step-by-step:*
```bash
make provision   # Provisions VM; cloud-init installs k3s on boot
make kubeconfig  # Waits for k3s boot to finish and fetches kubeconfig.yaml
```

Export `KUBECONFIG` for the session:
```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

### 3️⃣ Bootstrap Cilium CNI (v1.19.6)

Because k3s is installed with `--flannel-backend=none` (CNI-free), the node remains `NotReady` until Cilium is installed:

```bash
# Install Cilium CLI if not already installed (macOS example)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-arm64.tar.gz"{,.sha256sum}
shasum -a 256 -c cilium-darwin-arm64.tar.gz.sha256sum
sudo tar xzvfC cilium-darwin-arm64.tar.gz /usr/local/bin
rm cilium-darwin-arm64.tar.gz{,.sha256sum}

# Bootstrap Cilium onto the cluster
cilium install --version 1.19.6
cilium status --wait
```

### 4️⃣ Seed SOPS Age Private Key in Cluster

Flux decrypts age-encrypted secret files (`*-secrets.yaml`) using a Kubernetes secret named `sops-age` in the `flux-system` namespace.

If using the existing repository key (`key.txt` in project root):
```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt
```

> **Note for new environments:** If generating your own age key (`age-keygen -o key.txt`), update the public recipient key in `.sops.yaml` and re-encrypt all `*-secrets.yaml` files via `sops -e -i <file>` before committing to your remote Git repository.

### 5️⃣ Bootstrap Flux CD & Reconcile All Layers

Apply the Flux sync manifests and force initial reconciliation across all platform layers:

```bash
# Apply Flux CRDs and Git sync components
kubectl apply -k gitops/clusters/taskflow/flux-system

# Reconcile Git repository source
flux reconcile source git flux-system

# Reconcile platform and application layers
flux reconcile kustomization flux-system
flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
flux reconcile kustomization monitoring -n flux-system
flux reconcile kustomization monitoring-app -n flux-system
flux reconcile kustomization kyverno-policies -n flux-system
flux reconcile kustomization policy-reporter -n flux-system
flux reconcile kustomization trivy-operator -n flux-system
```

### 6️⃣ (Optional) Configure CoreDNS Local Override (Hairpin NAT Workaround)

If your home router blocks LAN hairpin NAT (sending requests to public IP `jokelab.dev` from inside the LAN), patch k3s CoreDNS so `cert-manager` self-checks and local clients resolve domains directly to the Gateway IP (`192.168.50.201`):

```bash
kubectl -n kube-system patch configmap coredns --type merge -p '{"data":{"Corefile":".:53 {\n    errors\n    health\n    hosts {\n        192.168.50.201 jokelab.dev www.jokelab.dev grafana.jokelab.dev kyverno.jokelab.dev\n        fallthrough\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n        pods insecure\n        fallthrough in-addr.arpa ip6.arpa\n    }\n    prometheus :9153\n    forward . /etc/resolv.conf\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}'
kubectl -n kube-system rollout restart deploy/coredns
```

### 7️⃣ Verify Cluster & Application Health

```bash
# Check all pods across the cluster
kubectl get pods -A

# Check Gateway and HTTPRoute status
kubectl get gateway,httproute -A

# Verify application secrets are decrypted
kubectl get secret -n taskflow db-secret taskflow-secrets
```

Access services via Cilium Gateway:
- **TaskFlow Web App:** `https://www.jokelab.dev/`
- **Grafana Observability:** `https://grafana.jokelab.dev/`
- **Policy Reporter UI:** `https://kyverno.jokelab.dev/`

---

## 🛡 Built-in Enterprise Architecture & Optimizations

To ensure production-grade security, resiliency, and performance on a single-node homelab, several optimizations are built into this repository:

### 1. Control Plane & Provisioning Stability
* **Reconstruction-Aware Kubeconfig Sync:** The `fetch_kubeconfig` module is linked to the Proxmox VM instance ID. Rebuilding the VM automatically re-fetches the `kubeconfig.yaml`, avoiding stale SSH/TLS certificate errors.
* **Syntax-Safe Cloud-Init:** Heredocs in `modules/proxmox/main.tf` start at column 0 to prevent YAML whitespace parsing failures.

### 2. Cilium CNI, Network Security & Gateway API
* **High-Performance eBPF CNI:** Flannel and k3s network policies are disabled (`--flannel-backend=none --disable-network-policy`) to let **Cilium v1.19.6** handle eBPF routing, SNAT masquerading, and network security policies.
* **Kubernetes Gateway API:** Deployed standard Gateway API CRDs (`gateway-api`) and enabled Cilium's Gateway API controller (`gatewayAPI.enabled = true`).
* **ServiceLB Deconfliction & L2 Announcements:** K3s ServiceLB is disabled (`--disable servicelb`). Cilium L2 announcements (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`) advertise gateway IP `192.168.50.201`.
* **Zero-Trust Network Policies:** Ingress to database/cache tiers (`postgres-db`, `redis`, `jaeger`) is restricted strictly to backend pods.

### 3. Storage Resiliency & Database Performance
* **Proxmox CSI Storage:** PostgreSQL PVC (`postgres-pvc.yaml`) uses **10Gi** storage on the `proxmox-csi` StorageClass, enabling dynamic disk attachments and hypervisor-level backups.
* **PostgreSQL RAM Tuning:** `shared_buffers = 384MB`, `effective_cache_size = 700MB`, `work_mem = 8MB`, `maintenance_work_mem = 64MB`, `max_connections = 30`.
* **Redis Cache Protection:** Ephemeral L2 cache running with `--maxmemory 384mb` and `--maxmemory-policy allkeys-lru`.
* **JVM Heap & Off-Heap Guard:** Spring Boot backend uses `MaxRAMPercentage=50.0` (1 GiB heap at 2 GiB limit) with bounded off-heap (`MaxMetaspaceSize=256m`) and Guaranteed QoS (`requests == limits = 2Gi`).

### 4. Provider Plugin Cache
OpenTofu is configured via `Makefile` to use project-local plugin caching (`.terraform/providers-cache`), avoiding re-downloading large provider binaries (`bpg/proxmox`) on every run.

```bash
make cache        # Show cache size
make cache-clean  # Wipe cached provider binaries
```
