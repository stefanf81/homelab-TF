# TaskFlow — Architecture & Infrastructure Documentation

## 1. Overview

TaskFlow is a **single-node homelab Kubernetes platform** running on Proxmox VE, provisioned via OpenTofu and managed through GitOps (Flux CD). The stack delivers a Spring Boot 3.5.3 / Angular 22 enterprise application with PostgreSQL, Redis caching, and Jaeger distributed tracing — all behind Cilium's Gateway API with zero-trust security hardening.

---

## 2. Infrastructure Layer (OpenTofu → Proxmox)

### 2.1 Provisioning Stack
| Component | Tool / Version | Purpose |
|-----------|---------------|---------|
| IaC Engine | OpenTofu ≥ 1.8.0 | VM provisioning & kubeconfig fetch |
| Provider | `bpg/proxmox` v0.111.1 | Proxmox VE API integration |
| Cloud Image | Ubuntu 26.04 (Resolute) cloud-init | k3s host OS |
| Orchestration | Makefile (`make init`, `make apply`) | Enforces correct provisioning sequence |

### 2.2 VM Specifications (defaults in `variables.tf`)
- **CPU**: 6 cores (host type, with vPMU + vendor string passthrough)
- **Memory**: 14 GiB (dedicated + floating)
- **Disk**: 100 GB SCSI (virtio-scsi-single, SSD + discard enabled)
- **Network**: `vmbr0` bridge, static IP via cloud-init
- **Tags**: `kubernetes`, `k3s`

### 2.3 Cloud-Init Hardening (`modules/proxmox/main.tf`)
| Category | Configuration |
|----------|--------------|
| Kernel params | `fs.inotify.max_user_instances=8192`, `vm.max_map_count=262144`, `fs.file-max=2097152`, `vm.swappiness=1` |
| Multipath | Blacklists loop, md, dm, sr, scd, sda partitions; enables user-friendly names |
| System services | iscsid (enabled/started), qemu-guest-agent (enabled/started), journald capped at 100 MB |
| k3s flags | `--flannel-backend=none --disable-network-policy --disable servicelb --disable traefik` |

### 2.4 Module Dependency Graph
```
module.proxmox ──(outputs k3s_node_ip, k3s_node_id)──▶ module.k3s_kubeconfig
                                                          │
                                                  null_resource.fetch_kubeconfig
                                                  (waits for /etc/rancher/k3s/k3s.yaml,
                                                   SSHs in, sed 127.0.0.1 → VM IP, writes kubeconfig.yaml)
```

---

## 3. Kubernetes Layer (k3s + Cilium CNI)

### 3.1 Runtime
- **Distribution**: k3s (single-node cluster)
- **CNI**: Cilium v1.19.6 with `kubeProxyReplacement: true` (eBPF-based, no kube-proxy)
- **Storage**: Proxmox CSI (dynamic VM virtual disk provisioning)

### 3.2 Cilium Configuration (`gitops/infrastructure/controllers/cilium/release.yaml`)
| Feature | Setting |
|---------|---------|
| IPAM | `kubernetes` mode |
| BPF masquerade | Enabled (offloads SNAT to eBPF) |
| Gateway API | Built-in controller enabled |
| L2 announcements | Enabled (for external IP exposure) |
| Operator replicas | 1 (single-node optimized) |

### 3.3 Cilium Network Policies (`gitops/infrastructure/configs/cilium/`)
- **IP Pool**: `CiliumLoadBalancerIPPool` — `192.168.50.200–250`
- **L2 Policy**: `CiliumL2AnnouncementPolicy` — matches interfaces `^eth[0-9]+`, `^enp[0-9]+`

### 3.4 Gateway API (`gitops/infrastructure/controllers/gateway-api/`)
- Standard Gateway API CRDs installed via `standard-install.yaml`
- TLSRoute CRD added for future TLS passthrough support

---

## 4. GitOps Layer (Flux CD v2.9.2)

### 4.1 Kustomization Dependency Chain
```
flux-system (bootstrap)
    │
    ▼
infra-controllers (HelmReleases: Cilium, cert-manager, Proxmox CSI, Gateway API)
    │
    ▼
infra-configs (Cilium IP pool + L2 policy, GatewayClass)
    │                                  │
    ▼                                  ▼
taskflow-app                     monitoring (VictoriaMetrics + Grafana operator + CRDs;
(SOPS-decrypted app manifests)    SOPS-decrypted Grafana admin secret)
    │                                  │
    │                                  ▼
    │                       monitoring-app (VMServiceScrapes for taskflow services)
    ▼
(image automation commits new digests)
```
> `monitoring` depends on `infra-controllers` (so CRDs land first); `monitoring-app`
> depends on `monitoring` (so the VMServiceScrape CRD exists before the VMServiceScrapes
> are applied). `taskflow-app` and `monitoring` are independent branches.

### 4.2 Flux Kustomizations
| Name | Path | Interval | Prune | Wait | Timeout | Depends On |
|------|------|----------|-------|------|---------|------------|
| `infra-controllers` | `./gitops/infrastructure/controllers` | 30m | ✅ | ✅ | 10m | — |
| `infra-configs` | `./gitops/infrastructure/configs` | 30m | ✅ | ✅ | 10m | infra-controllers |
| `taskflow-app` | `./gitops/apps/taskflow` | 10m | ✅ | ✅ | 5m | infra-configs |
| `monitoring` | `./gitops/monitoring/platform` | 30m | ✅ | ✅ | 10m | infra-controllers |
| `monitoring-app` | `./gitops/monitoring/app` | 30m | ✅ | ✅ | 10m | monitoring |
| `kyverno-policies` | `./gitops/apps/kyverno-policies` | 30m | ✅ | ✅ | 5m | infra-controllers |
| `policy-reporter` | `./gitops/infrastructure/controllers/policy-reporter` | 30m | ✅ | ✅ | 10m | infra-controllers, taskflow-app |
| `trivy-operator` | `./gitops/infrastructure/controllers/trivy-operator` | 30m | ✅ | ✅ | 5m | infra-controllers |

### 4.3 Image Automation (Digest Pinning)
```
ImageRepository (ghcr.io/stefanf81/taskflow-enterprise/taskflow-frontend, interval: 5m)
    │
    ▼
ImagePolicy (filter: ^latest$, digestReflectionPolicy: Always)
    │
    ▼
ImageUpdateAutomation (Setters strategy → rewrites manifests with @sha256:<digest>)
```

### 4.4 Secrets Protection
- **SOPS** v3.13.2 with age encryption (`AES256_GCM`)
- Creation rule: `.*-secrets\.yaml$` → encrypted with recipient `age14tnw8z...xnm22`
- Flux decrypts via `sops-age` Secret in `flux-system` namespace

---

## 5. Application Layer (TaskFlow)

### 5.1 Architecture Diagram
```
                    ┌──────────────┐
                    │   Gateway    │  Cilium Gateway API
                    │ taskflow-gw  │  Port: 80, Class: cilium
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              /api (10s)  Jaeger (internal   /
              │        only, not on GW) │
              │            │            │
              ┌─────────▼───┐  ┌────▼─────┐  ┌──▼──────────┐
              │   Backend   │  │  Jaeger  │  │   Frontend  │
              │ (Spring Boot│  │(all-in-1)│  │ (Angular +  │
              │  3.5.3,     │  │          │  │  nginx)     │
              │  JVM 1GiB)  │  └────┬─────┘  └─────────────┘
    └──────┬──────┘         │
           │                │
    ┌──────▼──────┐   ┌────▼─────┐
    │   Redis     │   │ Jaeger   │
    │ (384MB,     │   │ UI svc   │
    │  LRU evict) │   └──────────┘
    └──────┬──────┘
           │
     ┌──────▼──────┐
     │ PostgreSQL  │
     │ (17-alpine, │
     │  10Gi Proxmox CSI)
     └─────────────┘

                  ┌──────────────────────────────────────────────┐
                  │  Monitoring (namespace: monitoring)           │
                  │  VictoriaMetrics ──scrapes──▶ backend:8080    │
                  │  (TSDB on Proxmox CSI PVC) /actuator/prometheus│
                  │  Grafana (admin secret,   postgres-exporter   │
                  │   off public Gateway)    redis-exporter       │
                  └──────────────────────────────────────────────┘
                  (UIs reached via kubectl port-forward — see S10.9)
```

### 5.2 Backend Deployment (`gitops/apps/taskflow/backend.yaml`)
| Property | Value |
|----------|-------|
| Image | `ghcr.io/stefanf81/taskflow-enterprise/taskflow-backend:latest` (digest-pinned by Flux) |
| Replicas | 1 |
| JVM Heap | Fixed 1 GiB — owned by the **image** via `-XX:MaxRAMPercentage=50.0` (not by the deployment's `JAVA_TOOL_OPTIONS`, which sets only GC logging/caps) |
| GC | G1 with StringDedup, AlwaysPreTouch, ParallelRefProc, DisableExplicitGC |
| OOM Policy | `-XX:+ExitOnOutOfMemoryError` (fail fast) |
| Resources | CPU: 2 cores (req=limit), Memory: 2Gi (Guaranteed QoS, req==limit) |
| SecurityContext | readOnlyRootFS, runAsNonRoot UID/GID 10001, drop ALL capabilities |
| Init Container | `alpine:3.24.1` — waits for DB (port 5432) + Redis (port 6379) via nc |
| Probes | Startup: `/actuator/health/liveness`, Liveness: same, Readiness: `/actuator/health/readiness` |
| Termination Grace Period | 45s (for Spring graceful shutdown) |

### 5.3 Frontend Deployment (`gitops/apps/taskflow/frontend.yaml`)
| Property | Value |
|----------|-------|
| Image | `ghcr.io/stefanf81/taskflow-enterprise/taskflow-frontend:latest` (digest-pinned by Flux) |
| Replicas | 1 |
| Resources | CPU: 100–500 m, Memory: 128–256 MiB |
| SecurityContext | readOnlyRootFS, runAsNonRoot UID/GID 101 (nginx user), drop ALL capabilities |
| Volumes | tmp-volume (`/tmp`), var-cache-volume (`/var/cache/nginx`), var-run-volume (`/var/run`) — all emptyDir |
| Probes | All probe on `/` port 8080 |

### 5.4 PostgreSQL Deployment (`gitops/apps/taskflow/postgres-db.yaml`)
| Property | Value |
|----------|-------|
| Image | `postgres:18.4-alpine` |
| Replicas | 1 |
| Storage | 10 GiB PVC, storageClass: proxmox-csi (ReadWriteOnce) |
| SecurityContext | runAsNonRoot UID/GID 70 (postgres), drop ALL capabilities, fsGroup 70 with OnRootMismatch policy |
| Tuning | `shared_buffers=384MB`, `effective_cache_size=700MB`, `work_mem=8MB`, `maintenance_work_mem=64MB`, `max_connections=50`, `max_parallel_maintenance_workers=2` (PG18 compact-radix-tree VACUUM: up to ~20x less index memory, parallel maintenance) |
| SSD tuning | `random_page_cost=1.1`, `effective_io_concurrency=200`, `checkpoint_timeout=300s`, `wal_buffers=16MB`, `max_wal_size=2GB` |
| Resources | CPU: 500m–2 cores, Memory: 768–1024 MiB |

### 5.5 Redis Deployment (`gitops/apps/taskflow/redis.yaml`)
| Property | Value |
|----------|-------|
| Image | `redis:8.8.0-alpine` |
| Replicas | 1 |
| Storage | emptyDir (ephemeral, no persistence) |
| Memory Guard | `--maxmemory 384mb`, `allkeys-lru`, lazyfree eviction, 10 samples |
| Resources | CPU: 250m–1 core, Memory: 256–512 MiB |

### 5.6 Jaeger Deployment (`gitops/apps/taskflow/jaeger.yaml`)
| Property | Value |
|----------|-------|
| Image | `jaegertracing/jaeger:2.20.0` |
| Replicas | 1 |
| Memory Guard | `--set=extensions.jaeger_storage.backends.some_storage.memory.max_traces=5000` |
| Ports | UI: 16686, OTLP-gRPC: 4317, OTLP-HTTP: 4318 |
| Resources | CPU: 100m–500 m, Memory: 128–256 MiB |

### 5.7 Cloudflare DDNS (`gitops/apps/taskflow/cloudflare-ddns.yaml`)
Keeps the `jokelab.dev`, `www.jokelab.dev`, and `grafana.jokelab.dev` DNS A records synced to the Gateway's external IP (`192.168.50.201`). Uses the `favonia/cloudflare-ddns` image with a SOPS-encrypted Cloudflare API token.

### 5.8 Network Policies (`gitops/apps/taskflow/network-policy.yaml`)
| Target | Allowed From | Port(s) | Protocol |
|--------|-------------|---------|----------|
| postgres-db | pods with `app: taskflow-backend` | 5432 | TCP |
| redis | pods with `app: taskflow-backend` | 6379 | TCP |
| jaeger | pods with `app: taskflow-backend` | 4317, 4318 (OTLP) + 16686 (UI) | TCP |

### 5.9 Gateway & Routing (`gateway.yaml` + `httproute.yaml`)
- **Gateway**: `taskflow-gateway`, class: `cilium`, port 80/443 (HTTP/HTTPS), allowed routes restricted to approved namespaces (`taskflow`, `monitoring`)
- **HTTPRoute rules** (order matters — first match wins):
1. `/api` → backend:8080 (backendRequest timeout: 10s)
2. `/` → frontend:8080 (catch-all default)
- *Jaeger UI is intentionally NOT exposed through the Gateway (no auth in front of it); reach it via `kubectl port-forward` — see §10.6.*

### 5.10 Monitoring Stack (`gitops/monitoring/`)
| Component | Implementation |
|-----------|----------------|
| VictoriaMetrics + Grafana | `victoria-metrics-k8s-stack` HelmRelease (chart 0.87.0) in namespace `monitoring` |
| CRDs | Installed by the chart (VMServiceScrape, VMSingle, …) |
| Persistence | VictoriaMetrics TSDB on a **Proxmox CSI-backed PVC** (8Gi) via `vmsingle.storage` (StorageClass `proxmox-csi`) |
| Grafana auth | Admin credentials from a **SOPS-encrypted** secret (`grafana-secrets.yaml`); Grafana UI is routed via the Gateway API (see `routes.yaml`), secured by Grafana's login screen; VictoriaMetrics UI is kept strictly internal and accessed via port-forwarding |
| App metrics | `VMServiceScrape`s in `gitops/monitoring/app` scrape the backend (`/actuator/prometheus`), `postgres-exporter`, and `redis-exporter` |
| DB/Redis metrics | Side-car exporters (`postgres-exporter.yaml`, `redis-exporter.yaml` in `gitops/apps/taskflow`) — **no backend change required**; they reuse `db-secret` |
| Backend metrics | **Require an app-repo change** — the backend must add `micrometer-registry-prometheus` and expose `/actuator/prometheus` (see `docs/BACKEND_INTEGRATION_CONTEXT.md`). The VMServiceScrape exists but is inert until then. |

---

## 6. Security Posture

| Control | Implementation |
|---------|---------------|
| Zero-trust networking | Cilium network policies restrict all inter-service access; only backend can reach DB/Redis/Jaeger. A namespace-level default-deny (`namespace-default-deny.yaml`) blocks ALL ingress to the `taskflow` namespace by default, then selectively re-opens only the Gateway (Envoy) and monitoring scrapes |
| Pod security | All containers: `readOnlyRootFilesystem`, `allowPrivilegeEscalation=false`, drop ALL capabilities, runAsNonRoot |
| Secrets encryption | SOPS age-encrypted (`*-secrets.yaml`), decrypted by Flux at reconciliation time only |
| Image pinning | Flux image automation rewrites `:latest` to `@sha256:<digest>` — immutable references in Git |
| Grafana & VM UIs | Grafana UI is exposed securely on the Gateway at `/grafana` (secured by a login form with a strong, SOPS-encrypted admin password). VictoriaMetrics (VMSingle) is kept strictly internal to protect operational metrics, accessible privately via port-forwarding. |
| In-cluster scrape only | VictoriaMetrics scrapes taskflow services over the cluster network (plain HTTP, no auth). The backend must therefore permit `GET /actuator/prometheus` unauthenticated (see `docs/BACKEND_INTEGRATION_CONTEXT.md` §2.3). |
| SSH hardening | kubeconfig fetch uses strict host key checking disabled (homelab convenience) with known_hosts file |
| Cloud-init isolation | k3s installed via cloud-init user-data heredoc from column 0 (no whitespace parsing issues) |

---

## 7. File Structure Reference

```
TF/
├── main.tf                          # Root: proxmox + k3s-kubeconfig modules
├── providers.tf                     # bpg/proxmox v0.111.1, >= 1.8.0
├── variables.tf                     # All input vars (VM specs, SSH key, k3s token)
├── Makefile                         # OpenTofu workflow with plugin cache
├── .gitignore                       # State files, secrets, kubeconfig, keys
├── .sops.yaml                       # SOPS age encryption rules
├── kubeconfig.yaml                  # (ignored) k3s cluster access
├── key.txt                          # (ignored) SOPS age private key
│
├── modules/
│   ├── proxmox/                     # VM provisioning + cloud-init
│   │   ├── main.tf                  # Download image, create user_data snippet, provision VM
│   │   ├── providers.tf             # Proxmox provider config
│   │   └── variables.tf             # Module inputs (VM specs, network, k3s token)
│   │
│   └── k3s-kubeconfig/              # Wait + fetch kubeconfig over SSH
│       ├── main.tf                  # null_resource with local-exec provisioner
│       ├── providers.tf             # Null provider
│       └── variables.tf             # IP, VM ID, SSH user, output path
│
├── gitops/
│   ├── FLUX_BOOTSTRAP.md            # GitHub + Flux bootstrap steps
│   │
│   ├── apps/taskflow/               # Application manifests (kustomize)
│   │   ├── namespace.yaml           # taskflow namespace
│   │   ├── configmap.yaml           # SPRING_PROFILES_ACTIVE, CORS origins
│   │   ├── taskflow-secrets.yaml    # SOPS-encrypted: POSTGRES_PASSWORD, SPRING_SECURITY_PASSWORD
│   │   ├── backend.yaml             # Spring Boot deployment + ClusterIP service
│   │   ├── frontend.yaml            # Angular/nginx deployment + ClusterIP service
│   │   ├── postgres-db.yaml         # PostgreSQL 18 deployment + ClusterIP service (name: db)
│   │   ├── postgres-pvc.yaml        # 10Gi Proxmox CSI PVC
│   │   ├── redis.yaml               # Redis 8.8 deployment + ClusterIP service + NetworkPolicy
│   │   ├── jaeger.yaml              # Jaeger all-in-one + OTLP services + UI service + NetworkPolicy
│   │   ├── gateway.yaml             # Cilium Gateway (port 80/443, restricted namespace routes)
│   │   ├── httproute.yaml           # /api→backend, /*→frontend (Jaeger UI NOT exposed)
│   │   ├── http-redirect.yaml       # HTTP→HTTPS 301 redirect + apex→www redirect
│   │   ├── network-policy.yaml      # DB access restriction (backend-only ingress)
│   │   ├── default-deny.yaml        # Default-deny ingress for data tier (postgres, redis, jaeger)
│   │   ├── namespace-default-deny.yaml  # Full-namespace default-deny + Gateway/monitoring allow-lists
│   │   ├── backend-hpa.yaml         # HPA ready-to-activate (powered by metrics-server)
│   │   ├── backend-pdb.yaml         # PodDisruptionBudget (minAvailable: 1)
│   │   ├── frontend-pdb.yaml        # PodDisruptionBudget (minAvailable: 1)
│   │   ├── certificate.yaml         # Let's Encrypt TLS cert for jokelab.dev + subdomains
│   │   ├── cloudflare-ddns.yaml     # Dynamic DNS updater for Cloudflare
│   │   └── kustomization.yaml       # Resource ordering
│   │
│   ├── infrastructure/
│   │   ├── controllers/             # HelmRelease + Repository for platform add-ons
│   │   │   ├── cilium/release.yaml  # Cilium v1.19.6 (eBPF, Gateway API, L2 announcements)
│   │   │   ├── cert-manager/        # cert-manager HelmRelease (v1.21.0) with Let's Encrypt certificate automation
│   │   │   ├── proxmox-csi/         # Proxmox CSI driver (dynamic storage provisioning)
│   │   │   ├── gateway-api/         # Standard Gateway API CRDs + TLSRoute CRD
│   │   │   ├── kyverno/             # Kyverno policy engine (v3.8.2 / Kyverno v1.18.2)
│   │   │   ├── falco/               # Falco runtime security (v9.1.0 chart, modern eBPF)
│   │   │   ├── policy-reporter/     # Policy Reporter + UI dashboard
│   │   │   └── trivy-operator/      # Trivy vulnerability scanner operator
│   │   │
│   │   └── configs/                 # Cilium IP pool, L2 policy, GatewayClass
│   │       ├── cilium/ippool.yaml           # 192.168.50.200–250
│   │       ├── cilium/l2announcement-policy.yaml  # eth* + enp* interfaces
│   │       └── gatewayclass.yaml            # Cilium GatewayClass
│   │
│   └── clusters/taskflow/           # Flux Kustomizations (cluster-level)
│       ├── flux-system/             # Flux bootstrap manifests (v2.9.2, generated by bootstrap)
│       │   ├── kustomization.yaml
│       │   ├── gotk-components.yaml  # CRDs + RBAC + namespaces
│       │   └── gotk-sync.yaml        # GitRepository + Kustomization for flux-system
│       ├── kustomization.yaml       # References all layers
│       ├── infra-controllers.yaml   # HelmRelease controllers (Cilium, Proxmox CSI, etc.)
│       ├── infra-configs.yaml       # Cilium configs + GatewayClass
  │       ├── taskflow.yaml            # App layer with SOPS decryption
  │       ├── monitoring.yaml          # VictoriaMetrics + Grafana operator (SOPS-enabled)
  │       ├── monitoring-app.yaml      # App VMServiceScrapes (depends on monitoring)
  │       ├── kyverno-policies.yaml    # Kyverno ClusterPolicies (dependsOn infra-controllers)
  │       ├── policy-reporter.yaml     # Policy Reporter + UI (dependsOn infra-controllers + taskflow-app)
  │       ├── trivy-operator.yaml      # Trivy vulnerability scanner (dependsOn infra-controllers)
  │       └── image-automation.yaml    # ImageRepository + ImagePolicy + ImageUpdateAutomation
  │
  │   ├── monitoring/                  # Observability stack
  │   │   ├── platform/                # Operator + CRDs + storage + Grafana secret
  │   │   │   ├── namespace.yaml       # monitoring namespace
  │   │   │   ├── repository.yaml      # victoriametrics HelmRepository
  │   │   │   ├── grafana-secrets.yaml # SOPS-encrypted Grafana admin (age-encrypted)
  │   │   │   ├── release.yaml         # victoria-metrics-k8s-stack HelmRelease (tuned)
  │   │   │   ├── routes.yaml          # HTTPRoute for Grafana
  │   │   │   ├── metrics-server-release.yaml  # metrics-server HelmRelease
  │   │   │   ├── metrics-server-repository.yaml # metrics-server HelmRepository
  │   │   │   ├── metrics-server-rbac.yaml       # metrics-server RBAC
  │   │   │   └── kustomization.yaml
  │   │   └── app/                     # VMServiceScrapes (applied after CRDs exist)
  │   │       ├── vmservicescrapes.yaml # backend / postgres-exporter / redis-exporter
  │   │       └── kustomization.yaml
  ```

---

## 8. Operational Commands Reference

### Provisioning (OpenTofu)
```bash
make init          # Download providers into plugin cache
make apply         # Full: provision VM → wait for k3s → fetch kubeconfig
make destroy       # Tear down everything
make cache         # Show provider cache size
make cache-clean   # Wipe cached providers
```

### Cluster Diagnostics
```bash
./diagnose.sh      # Writes comprehensive diagnostics to diagnostics.log
```

### Flux Reconciliation (manual override)
```bash
flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
```

---

## 9. Known Limitations & Future Work

| Area | Current State | TODO |
|------|-------------|------|
| TLS/HTTPS | Fully configured (HTTPS on port 443) | cert-manager HelmRelease + Let's Encrypt certificates + HTTPS Gateway listener are fully active |
| Multi-node HA | Single k3s node | Add worker nodes via additional Proxmox VMs |
| GitOps remote repo | Local scaffolding only | Bootstrap Flux via `gitops/FLUX_BOOTSTRAP.md` (the `modules/flux-bootstrap` module is planned, not yet created) |
| Pod Disruption Budgets | ✅ Resolved | PDBs added for backend (`backend-pdb.yaml`), frontend (`frontend-pdb.yaml`), and postgres (`postgres-db.yaml`) — all `minAvailable: 1` |
| Horizontal Pod Autoscaler | ✅ Resolved | HPA exists (`backend-hpa.yaml`, CPU 70%, 1–3 replicas) and `metrics-server` is installed (`metrics-server-release.yaml`) for the `metrics.k8s.io` API |
| Backup strategy | Proxmox hypervisor backups | Configure scheduled VM backups at the Proxmox level (using PBS or vzdump) |
| Monitoring stack | Jaeger traces only | VictoriaMetrics + Grafana scaffolded in `gitops/monitoring/` (see §5.9). **Backend JVM/HTTP metrics need an app-repo change** (`micrometer-registry-prometheus`) — tracked in `docs/BACKEND_INTEGRATION_CONTEXT.md`. DB/Redis metrics already flow via exporters. |
| cert-manager | Installed (v1.21.0) | Configured Let's Encrypt HTTP-01 `ClusterIssuer` + `Certificate` for `jokelab.dev` with an HTTPS Gateway listener |

---

## 10. How It's Set Up in *This* Project (Implementation Walkthrough)

This section explains the **concrete, repo-specific** wiring — not the theory, but *which file does what and why we chose to do it that way here*. If you just cloned the repo and want to understand the moving parts, start here.

### 10.1 The repo is two independent halves

```
TF/
├── *.tf, modules/, Makefile     ← HALF A: OpenTofu  (builds the VM + fetches kubeconfig)
└── gitops/                     ← HALF B: Flux manifests (builds the cluster contents)
```

They only meet at **one file**: `kubeconfig.yaml` (written by Half A, consumed by you + Flux's `Kustomization` sources). OpenTofu knows **nothing** about what runs in the cluster; Flux knows **nothing** about how the VM was made. This separation is deliberate — you can `make destroy` the VM and re-provision it without touching a single Flux manifest, and vice-versa.

- **Half A runs once** (when you provision or rebuild the node). It's imperative: `make apply` → VM exists.
- **Half B runs continuously** (every 30m/10m/5m). It's declarative: Flux constantly reconciles cluster state toward the `gitops/` tree.

### 10.2 End-to-end: how a backend code change reaches production

This is the path that actually matters day-to-day:

```
1. You push a new :latest image to ghcr.io/stefanf81/taskflow-enterprise/taskflow-backend
        │
2. Flux ImageRepository (gitops/clusters/taskflow/image-automation.yaml)
   polls ghcr every 5m, sees :latest moved to a new sha256 digest
        │
3. Flux ImagePolicy (digestReflectionPolicy: Always) records the new digest
        │
4. Flux ImageUpdateAutomation rewrites the marker line in
   gitops/apps/taskflow/backend.yaml:
     image: ...:latest # {"$imagepolicy": "flux-system:taskflow-backend"}
   → image: ...:latest@sha256:<newdigest>
   and COMMITS it back to main (auth: fluxcdbot)
        │
5. Flux Kustomization taskflow-app (interval 10m) sees the Git change,
   decrypts *-secrets.yaml via SOPS, and applies the new Deployment
        │
6. k3s pulls the pinned digest, rolls out the new pod (45s grace for
   Spring graceful shutdown), old pod drains
```

**Why this design:** `:latest` is mutable and dangerous (a re-pull can change running software silently). By pinning to the *digest* and committing that digest to Git, the repo becomes the **auditable source of truth** — `git blame` on `backend.yaml` shows exactly which image is running and when it changed. A plain `kubectl rollout restart` will NOT change the software, because the digest is fixed in Git.

### 10.3 How the VM gets built (Half A) — `modules/proxmox/main.tf`

The single most important design decision here is: **no SSH provisioners for k3s**. Instead:

- `proxmox_download_file` pulls the Ubuntu 26.04 cloud image into the `local` datastore.
- `proxmox_virtual_environment_file.cloud_config` builds a **cloud-init snippet** (heredoc from column 0 to avoid YAML-whitespace parsing bugs) that, at first boot, installs kernel tweaks, multipath/iscsi storage packages, and **runs the k3s install script** with our exact flags:
  ```
  --flannel-backend=none --disable-network-policy --disable servicelb --disable traefik
  ```
  These flags are why Cilium (not Flannel/kube-proxy/servicelb/traefik) is the *only* networking + ingress + LB stack. They are set **once at boot**, not by Terraform on every apply — so Terraform never re-runs a fragile script against a live node.
- `proxmox_virtual_environment_vm` creates the VM. Note `ignore_changes` on `tags` / `user_account` / `mac_address` so day-2 tweaks don't trigger a VM rebuild.

Then `modules/k3s-kubeconfig/main.tf` is a `null_resource` with a `local-exec` that **polls over SSH** until `/etc/rancher/k3s/k3s.yaml` exists, copies it locally, and `sed`s `127.0.0.1` → the VM IP so the kubeconfig is usable from your laptop. Its `triggers` include `vm_recreate_id` (= the Proxmox VM ID), so **destroying/rebuilding the VM auto-re-fetches** the kubeconfig (new certs) — no stale-cert errors.

### 10.4 How the cluster gets its brains (Half B controllers)

`gitops/clusters/taskflow/kustomization.yaml` is the Flux root. It orders three layers with `dependsOn`:

```
infra-controllers ──▶ infra-configs ──▶ taskflow-app
   (HelmReleases)        (Cilium IP    (your app,
                          pool, GW     SOPS-decrypted)
                          class)
```

- **`infra-controllers`** (`gitops/infrastructure/controllers/`) installs the platform via HelmRelease objects:
  - `cilium/release.yaml` — Cilium 1.19.5 with `kubeProxyReplacement: true`, `gatewayAPI.enabled: true`, `l2announcements.enabled: true`. This is what makes the Gateway API and external IPs work.
  - `cert-manager/release.yaml` — cert-manager 1.21.0 (fully active, managing TLS certificates).
  - `proxmox-csi/` — Proxmox CSI driver (dynamic storage provisioning of virtual disks with native hypervisor backup integration).
  - `gateway-api/` — the standard Gateway API CRDs.
- **`infra-configs`** (`gitops/infrastructure/configs/`) applies Cilium's `CiliumLoadBalancerIPPool` (`192.168.50.200–250`), the `CiliumL2AnnouncementPolicy` (which Ethernet interfaces advertise the IP via ARP), and the `GatewayClass` named `cilium`. These **must** come after the controllers, hence the dependency.

### 10.5 How the app is exposed (the request path)

```
Browser ── https://www.jokelab.dev ──▶ (DNS → Public IP → Port Forward → 192.168.50.201, an L2-announced IP; bare apex `jokelab.dev` 301-redirects to `www`)
                                            │
                                     Cilium Gateway (taskflow-gateway, class: cilium, :80)
                                            │  HTTPRoute taskflow-route (first-match-wins):
                                            ├─ /api*    → service backend:8080      (30s backend timeout)
                                            ├─ /jaeger* → [REMOVED — see §10.6]
                                            └─ /*       → service frontend:8080
```

Key point: **Services are `ClusterIP` only**. Nothing is exposed except through the Gateway. The external IP (`192.168.50.200+`) is handed out by Cilium's L2 announcement, not by k3s ServiceLB (which we disabled). That's why disabling `servicelb` in cloud-init and defining the IP pool in `infra-configs` are two halves of the same decision.

### 10.6 Security model as actually implemented (zero-trust, in practice)

| Control | Where it lives | What it enforces |
|---------|--------------|------------------|
| Network isolation | `network-policy.yaml` (DB), `redis.yaml` (redis NP), `jaeger.yaml` (jaeger NP) | Only `app: taskflow-backend` pods may reach Postgres (5432), Redis (6379), or Jaeger OTLP (4317/4318). Everything else is denied by default (Cilium deny-all baseline). |
| **Jaeger UI locked down** | `httproute.yaml` + `jaeger.yaml` | The `/jaeger` Gateway route was **removed** and the open `16686` ingress rule deleted (ISSUES.md #2). Jaeger UI is now cluster-internal only — reach it via `kubectl port-forward`, never through the public Gateway, because it has no auth. |
| Read-only root FS | every Deployment's `securityContext` | Containers can't write to their image layer; only explicit `emptyDir` mounts (`/tmp`, nginx caches) are writable. |
| Non-root + dropped caps | every container | `runAsNonRoot: true`, `capabilities.drop: [ALL]`. Backend/Redis/Jaeger use UID `10001`; Postgres uses image-native UID `70`; frontend uses nginx UID `101`. |
| Secret encryption | `.sops.yaml` + `taskflow-secrets.yaml` | `POSTGRES_PASSWORD`, `SPRING_SECURITY_PASSWORD`, and `REDIS_PASSWORD` are age-encrypted; Flux decrypts at apply time using the `sops-age` Secret. The plaintext `key.txt` is `.gitignore`d. |
| Immutable images | `image-automation.yaml` | Flux pins every app image to a `@sha256:` digest in Git. |

### 10.7 What to touch when you want to change X

| You want to… | Edit this file | Then |
|--------------|---------------|------|
| Change backend JVM/heap or env | `gitops/apps/taskflow/backend.yaml` | `flux reconcile kustomization taskflow-app -n flux-system` (or wait 10m) |
| Add a new microservice | new Deployment+Service in `gitops/apps/taskflow/`, add to `kustomization.yaml` | Flux picks it up |
| Expose a new URL path | `gitops/apps/taskflow/httproute.yaml` | Flux reconciles Gateway |
| Change the external IP range | `gitops/infrastructure/configs/cilium/ippool.yaml` | `flux reconcile kustomization infra-configs` |
| Rotate a DB/app secret | `sops edit gitops/apps/taskflow/taskflow-secrets.yaml` | Flux re-decrypts on next sync |
| Bump Cilium/Proxmox CSI/cert-manager version | the `version:` in the relevant `release.yaml` | Flux upgrades (CRDs `CreateReplace`) |
| Change VM size/network | `terraform.tfvars` + `variables.tf` | `make apply` (note: some changes force VM recreate → auto re-fetch kubeconfig) |
| Add a TLS cert | `gitops/infrastructure/controllers/cert-manager/` + HTTPS listener in `gateway.yaml` | see ISSUES.md #19 |
| Change VictoriaMetrics retention / storage | `gitops/monitoring/platform/release.yaml` (`vmsingle.spec`, `vmsingle.storage`) | `flux reconcile kustomization monitoring -n flux-system` |
| Rotate the Grafana admin password | `sops edit gitops/monitoring/platform/grafana-secrets.yaml` | Flux re-decrypts on next sync |

### 10.8 Footguns / things that will bite you

1. **CORS** (`configmap.yaml`) lists `http://localhost:4200,https://jokelab.dev,https://www.jokelab.dev`. The canonical prod access URL is `www.jokelab.dev` (the `taskflow-route` only serves `www`; the bare apex 301-redirects to it). If you change the published hostname, update this list **and** `certificate.yaml`'s `dnsNames` **and** `httproute.yaml`'s `hostnames`, or the browser's `/api` calls get CORS-rejected. (A localhost-only CORS list was a live bug — ISSUES.md #1.)
2. **Jaeger UI is not on the Gateway anymore** — don't re-add a `/jaeger` route without putting auth in front of it.
3. **Postgres UID is 70 on purpose** — don't "standardize" it to `10001`; the Postgres volume ownership depends on 70.
4. **`proxmox_insecure = true`** disables TLS verification to Proxmox. Fine for a self-signed homelab, dangerous anywhere else.
5. **Ubuntu 26.04 ("Resolute")** is a future release — verify the cloud-image URL in `modules/proxmox/main.tf` actually resolves before `make provision` (ISSUES.md #18).
6. The whole stack is **single-replica** — there is no HA. A node reboot = full downtime. That's the accepted homelab tradeoff, not a bug.

### 10.9 The monitoring stack (VictoriaMetrics + Grafana) and how to reach it

Scaffolded in `gitops/monitoring/` (see §5.9). It reconciles independently of the app
and is **ready the moment the backend emits metrics** — but note the split:

- **`monitoring`** Kustomization (`gitops/monitoring/platform`) installs the operator +
  CRDs + Grafana (SOPS admin secret) + the Proxmox CSI TSDB PVC. Depends on `infra-controllers`.
- **`monitoring-app`** Kustomization (`gitops/monitoring/app`) applies the
  ServiceMonitors. Depends on `monitoring` so the ServiceMonitor CRD already exists.

**Reaching the UIs:**

The monitoring UIs are now exposed through the main Cilium Gateway API using zero-config wildcard IP and public DNS routing. See [Gateway Access Guide](GATEWAY_ACCESS_GUIDE.md) for full setup instructions.

- **Grafana:** `https://grafana.jokelab.dev`
  *(admin login credentials are saved in your local gitignored `grafana.secret`)*
- **VictoriaMetrics (VMSingle):** Accessed privately via `kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8428:8428` at `http://localhost:8428/vmsingle/`

**What produces metrics today vs. later:**
- ✅ Node + kubelet (cadvisor) + kube-state-metrics — from the stack itself, providing workload and host metrics.
- ✅ PostgreSQL + Redis — via the `postgres-exporter` / `redis-exporter` side-cars in `gitops/apps/taskflow` (no backend change).
- ⏳ **Backend JVM/HTTP** — requires the app repo to add `micrometer-registry-prometheus` and expose `/actuator/prometheus` (unauthenticated, in-cluster scrape). The VMServiceScrape already exists and is inert until then. See `docs/BACKEND_INTEGRATION_CONTEXT.md`.

**Resource budget (memory-trimmed):** the stack reserves ~1.1 GiB of limit
(VMSingle 512 Mi cap / 128 Mi req, vmagent 256 Mi, Grafana 256 Mi,
operator 128 Mi, exporters + node-exporter ~0.4 GiB; kube-state-metrics off). VictoriaMetrics runs **3d
retention** and scrapes at **30s** for higher-resolution dashboards.
On the 14 GiB node this still leaves the bulk for backend (2 GiB guaranteed) +
Postgres (1 GiB limit) + Redis + Jaeger; if it's still tight, the biggest single
lever is the backend JVM (already trimmed to 1 GiB heap / 2 GiB QoS) or disabling
monitoring entirely. As a last resort, bump `vm_memory` in `variables.tf`
(ISSUES.md #16) before disabling monitoring.

**Footgun:** the `monitoring` Kustomization has SOPS decryption enabled (reuses `sops-age`). The Grafana secret (`grafana-secrets.yaml`) **must stay encrypted** — editing it in plaintext will make Flux fail to decrypt. Rotate with `sops edit gitops/monitoring/platform/grafana-secrets.yaml`.
