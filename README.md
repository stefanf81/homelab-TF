# TaskFlow Homelab — OpenTofu & Flux CD

Single-root OpenTofu project for provisioning a Proxmox VE VM and bootstrapping k3s.
Cluster workloads and platform controllers are managed declaratively through GitOps (`gitops/`) using Flux CD v2.

---

## 🛠 Prerequisites

Before starting bring-up from scratch, ensure the following CLI tools are installed on your workstation:

- **IaC & Automation:** [OpenTofu](https://opentofu.org/) (≥ 1.8.0), `make`, `ruby`
- **Kubernetes Management:** `kubectl`, `helm`, [Flux CLI](https://fluxcd.io/flux/cmd/) 2.10.x (same minor as the `FluxInstance`; `scripts/check-tool-versions.sh` enforces it) (optional: [Cilium CLI](https://github.com/cilium/cilium-cli) for ad-hoc `cilium`/`hubble` inspection)
- **Secrets Management:** [SOPS](https://github.com/getsops/sops) (≥ v3.9), [age](https://github.com/FiloSottile/age)

`mise install` (see `mise.toml`) installs pinned versions of OpenTofu, kubectl, Kustomize, Helm, kubeconform, tflint, Flux, SOPS and age; `make lint` (tflint) and `make validate-gitops` (render and schema-check every Flux path) run the same checks as the matching CI steps.

You also need access to a **Proxmox VE 9.x** host (8.x is end of life) with an API token (with VM creation, Datastore, and Network privileges) and SSH agent access (`root@<proxmox>`) for cloud-init snippet uploads (`providers.tf`).

---

## 📁 Repository Layout

- `modules/proxmox` – Provisions the pinned Ubuntu 26.04 VM; cloud-init installs k3s `v1.37.2+k3s1` at boot (no SSH provisioning; the only SSH use is the one-shot kubeconfig fetch in `modules/k3s-kubeconfig`).
- `modules/k3s-kubeconfig` – SSHs into the node once cloud-init finishes, fetches `/etc/rancher/k3s/k3s.yaml`, and writes a local `kubeconfig.yaml`.
- `gitops/` – Declarative Flux v2 manifests:
  - `gitops/infrastructure/controllers` – Gateway API CRDs (`v1.6.3`), Cilium v1.20.5, cert-manager, CoreDNS, Proxmox CSI, Kyverno, Falco, Trivy Operator, Reloader, Flux Operator.
  - `gitops/infrastructure/configs` – Cilium LB IP pool (`192.168.50.200-250`) and L2 announcement policy, `GatewayClass`, Let's Encrypt ClusterIssuers, `PriorityClass/taskflow-critical`, Hubble pod-network isolation, and the AbuseIPDB ingress deny policy.
  - `gitops/platform` – Policy Reporter + `oauth2-proxy`, Hubble UI `oauth2-proxy`, AbuseIPDB synchronizer, Renovate Operator + scheduled job.
  - `gitops/apps/taskflow` – Spring Boot 4.1.1 backend, Angular 22 frontend, Caddy+Coraza WAFs, PostgreSQL 19, Redis 8.10, Jaeger.
  - `gitops/apps/kyverno-policies` – CEL `ValidatingPolicy` admission rules (`Deny`, fail-open) and `ImageValidatingPolicy` signature/attestation checks for the TaskFlow images.
  - `gitops/monitoring` – VictoriaMetrics TSDB + Grafana stack + metrics-server + Loki/Alloy + 13 custom/vendored dashboards (Taskflow WAF/Access Logs/Rate Limits/Performance, Blocked Sources, AbuseIPDB, Cilium Agent, Hubble Flows, Falco, Trivy, Kyverno, cert-manager, Logging pipeline).
  - `gitops/images` – Custom image sources: TaskFlow Caddy+Coraza WAF and `abuseipdb-sync`.
  - `gitops/clusters/taskflow` – Cluster root Kustomizations and `cluster-vars`.

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
k3s_version       = "v1.37.2+k3s1"
```

### 2️⃣ Provision the Proxmox VM & Fetch `kubeconfig`

Initialize OpenTofu (providers are cached in `~/.cache/opentofu/plugins`, override with `TF_PLUGIN_CACHE_DIR`), run a non-mutating preview, then apply the configuration:

```bash
make init
make plan    # Pure dry-run; does not provision the VM or fetch kubeconfig
make apply
```

`make apply` is one `tofu apply` over both modules, so a rebuilt VM always gets a
freshly fetched kubeconfig. For debugging, the two halves can run on their own:
```bash
make provision   # Provisions VM; cloud-init installs k3s on boot
make kubeconfig  # Waits for k3s boot to finish and fetches kubeconfig.yaml
```

Export `KUBECONFIG` for the session:
```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

### 3️⃣ Bootstrap the Cluster

Follow [`gitops/FLUX_BOOTSTRAP.md`](gitops/FLUX_BOOTSTRAP.md) §2–5, the single source for
these steps:

1. `make bootstrap-foundation`: Gateway API CRDs, Cilium, CoreDNS and the Flux Operator from
   the pinned GitOps charts (the node has no CNI, kube-proxy or CoreDNS until then).
2. Seed the `flux-system` Git credential (PAT with `contents:write`), the `sops-age` key and
   `taskflow/ghcr-pull-secret`.
3. Apply `gitops/infrastructure/flux-instance/flux-instance.yaml` and reconcile the layers in
   dependency order (needs public DNS and WAN 80/443 for the HTTP-01 certificate).
4. Verify.

Once it is up:
- **TaskFlow:** `https://www.jokelab.dev/`
- **Grafana:** `https://grafana.jokelab.dev/`
- **Policy Reporter UI:** `https://kyverno.jokelab.dev/`
- **Hubble UI:** `https://hubble.jokelab.dev/`

Routing and access details: `docs/ARCHITECTURE.md` §5.9.

---

## 📚 Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): how the pieces fit, what to edit for a change, known limitations.
- [`docs/BACKLOG.md`](docs/BACKLOG.md): open work, verified against the code.
- [`docs/README.md`](docs/README.md): index of every runbook and reference.

---

## 🛠 Make Targets

```bash
make init         # tofu init (providers cached in ~/.cache/opentofu/plugins; override TF_PLUGIN_CACHE_DIR)
make plan         # Non-mutating preview
make apply        # VM + kubeconfig fetch in one plan
make bootstrap-foundation  # Pre-Flux foundation (see gitops/FLUX_BOOTSTRAP.md §2)
make fmt          # Fail on formatting drift (`tofu fmt -recursive` fixes it)
make validate     # Static validation of the root and child modules (after `make init`)
make lint         # tflint
make validate-gitops  # Render and schema-check every path Flux reconciles
make cache        # Show the provider cache size
make cache-clean  # Wipe cached provider binaries
make destroy      # Refused while modules/proxmox sets prevent_destroy
```

The provider cache lives outside `.terraform/`, so a fresh `init` (after deleting
`.terraform/`, or in a second checkout) links the large `bpg/proxmox` binary instead of
downloading it again.
