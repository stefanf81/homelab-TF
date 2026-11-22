# TaskFlow — Architecture & Infrastructure Documentation

## 1. Overview

TaskFlow is a **single-node homelab Kubernetes platform** running on Proxmox VE, provisioned via OpenTofu and managed through GitOps (Flux CD). The stack delivers a Spring Boot 4.1.1 / Angular 22 enterprise application with PostgreSQL, Redis caching, and Jaeger distributed tracing — all behind Cilium's Gateway API with zero-trust security hardening.

The repository has two halves that meet only at `kubeconfig.yaml` and one value kept equal
by hand (`NODE_IP` in `gitops/clusters/taskflow/cluster-vars.yaml` = `ip_address` in
`terraform.tfvars`):

- **OpenTofu** (`*.tf`, `modules/`, `Makefile`) builds the VM and fetches the kubeconfig. It
  runs once per node build and knows nothing about what runs in the cluster.
- **Flux** (`gitops/`) builds and continuously reconciles the cluster contents (Git polled every
  1m, Kustomizations every 10m–1h). It knows nothing about how the VM was made.

Bring-up order: `README.md` (provisioning) → `gitops/FLUX_BOOTSTRAP.md` (cluster bootstrap).

---

## 2. Infrastructure Layer (OpenTofu → Proxmox)

### 2.1 Provisioning Stack
| Component | Tool / Version | Purpose |
|-----------|---------------|---------|
| IaC Engine | OpenTofu (minimum ≥ 1.8.0) | VM provisioning & kubeconfig fetch |
| Provider | `bpg/proxmox` v0.122.0 | Proxmox VE API integration |
| Cloud Image | Ubuntu 26.04 (Resolute), release-20261108, SHA-256 pinned (the VM ignores later re-pins: `disk[0].file_id` is in `ignore_changes`) | k3s host OS |
| k3s | v1.37.2+k3s1 | Kubernetes distribution |
| Orchestration | Makefile (`make init`, `make apply`) | Enforces correct provisioning sequence |

### 2.2 VM Specifications (defaults in `variables.tf`)
- **CPU**: 6 cores (host CPU type)
- **Memory**: 12 GiB (dedicated + floating; was 14 GiB until 2026-11, which made the 15 GiB host swap)
- **Disk**: 100 GB SCSI (virtio-scsi-single, SSD + discard enabled)
- **Network**: `vmbr0` bridge, static IP via cloud-init
- **Tags**: `kubernetes`, `k3s`

### 2.3 Cloud-Init Hardening (`modules/proxmox/main.tf`)
| Category | Configuration |
|----------|--------------|
| Kernel params | `net.ipv4.ip_forward=1`, `fs.inotify.max_user_instances=8192`, `fs.inotify.max_user_watches=524288`, `fs.file-max=2097152`, `fs.aio-max-nr=1048576`, `vm.swappiness=1` (swap also turned off), `net.ipv4.tcp_mtu_probing=1`, `kernel.core_pattern=\|/bin/false` (Ubuntu sets `vm.max_map_count=1048576`; kubelet sets `kernel.panic=10`, `kernel.panic_on_oops=1`) |
| Disk I/O | udev rule sets the `none` scheduler on the virtio-scsi disks (the host schedules I/O) |
| System services | qemu-guest-agent (enabled/started); iscsid/open-iscsi, multipathd, snapd and motd-news disabled; `serial-getty@ttyS0` masked (no serial port: it restarted every 10s); journald capped at 100 MB |
| VM NIC | virtio-net multiqueue, one queue pair per vCPU (`queues = var.cpu_cores`) |
| Kubelet | Graceful node shutdown (`shutdownGracePeriod: 90s`, `shutdownGracePeriodCriticalPods: 20s`) via `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-graceful-shutdown.conf`; unattended-upgrades' 30s logind cap masked. Image GC (`50-image-gc.conf`): unused images removed after 7 days (`imageMaximumGCAge: 168h`), threshold GC at 75 %/65 % |
| k3s config (`/etc/rancher/k3s/config.yaml`) | `flannel-backend: none`, `disable-network-policy: true`, `disable-kube-proxy: true`, `disable: [servicelb, traefik, coredns, metrics-server, local-storage]`; kubelet `system-reserved` and `kube-reserved` of `cpu=200m,memory=500Mi` each; `topology.kubernetes.io/region=homelab` / `zone=<proxmox_node>` node labels |

### 2.4 Module Dependency Graph
```
module.proxmox ──(outputs k3s_node_ip, k3s_node_build_id)──▶ module.k3s_kubeconfig
                                                          │
                                                  null_resource.fetch_kubeconfig
                                                  (waits for /etc/rancher/k3s/k3s.yaml,
                                                   SSHs in, sed 127.0.0.1 → VM IP, writes kubeconfig.yaml)
```

### 2.5 How the VM is built
- **No SSH provisioning of k3s.** `proxmox_download_file` fetches the pinned cloud image;
  `proxmox_virtual_environment_file.cloud_config` writes a cloud-init snippet that, at first
  boot, applies the tuning above, writes `/etc/rancher/k3s/config.yaml` and runs the
  commit-pinned, SHA-256-verified k3s installer with no command-line flags. The last `runcmd`
  touches `/etc/cloud/cloud-init.disabled`, so cloud-init never re-runs the installer.
- **Day-2 changes do not rebuild the VM:** `ignore_changes` covers `tags`, `user_account`,
  `mac_address`, `user_data_file_id` and `disk[0].file_id`, so snippet edits and image re-pins
  only affect new nodes; apply them to the running node by hand (`docs/NODE_HOST_TUNING.md` §3).
  `prevent_destroy` refuses any plan that would replace the VM.
- **Kubeconfig fetch** (`modules/k3s-kubeconfig`): a `null_resource` polls over SSH until
  `/etc/rancher/k3s/k3s.yaml` exists, rewrites `127.0.0.1` to the VM IP and writes the file
  0600 via a temp file. It is keyed to `k3s_node_build_id` (VM ID plus the NIC MAC, which
  changes on a rebuild), so a rebuilt VM gets a fresh kubeconfig, provided both modules are in
  one plan (`make apply`).
- Nodes installed before 2026-10-25 still run kube-proxy until `disable-kube-proxy: true` is set
  by hand (`docs/reports/REMEDIATION_PLAN_2026-10.md` PERF-01).

---

## 3. Kubernetes Layer (k3s + Cilium CNI)

### 3.1 Runtime
- **Distribution**: k3s (single-node cluster)
- **CNI**: Cilium v1.20.5 with `kubeProxyReplacement: true` (eBPF-based, no kube-proxy)
- **Storage**: Proxmox CSI (dynamic VM virtual disk provisioning)

### 3.2 Cilium Configuration (`gitops/infrastructure/controllers/cilium/release.yaml`)
| Feature | Setting |
|---------|---------|
| IPAM | `kubernetes` mode |
| BPF masquerade | Enabled (offloads SNAT to eBPF) |
| Gateway API | Built-in controller enabled |
| L2 announcements | Enabled (for external IP exposure); lease 60s / renew deadline 40s / retry 15s, so the lease holder writes to the k3s datastore every 15s instead of every 2s (chart default) |
| Operator leader election | lease 60s / renew 40s / retry 15s via `operator.extraArgs` (default retry 2s); fewer k3s SQLite writes, and short API restarts no longer drop leadership |
| Metrics | Agent, operator, Hubble (`dns`, `drop`, `tcp`, `flow`, `icmp`, `httpV2`) and Envoy scraped by VictoriaMetrics; Grafana dashboards `Cilium Agent` and `Hubble Flows` (Platform folder) |
| Operator replicas | 1 (single-node optimized) |
| Hubble flow export | `hubble.export.static` — DROPPED/ERROR flows written to `/var/run/cilium/hubble/events.log` for Loki/Grafana (`Blocked Sources`) |

### 3.3 Cilium Network Policies (`gitops/infrastructure/configs/cilium/`)
- **IP Pool**: `CiliumLoadBalancerIPPool` — `192.168.50.200–250`
- **L2 Policy**: `CiliumL2AnnouncementPolicy` — matches interfaces `^eth[0-9]+`, `^enp[0-9]+`, `^ens[0-9]+`
- **Hubble pod-network isolation**: `restrict-hubble-ui-ingress` admits `hubble-ui` (`:8081`) only from the oauth2-proxy in the `hubble-ui` namespace, and `restrict-hubble-relay-ingress` admits `hubble-relay` (`:4245`) only from the `hubble-ui` pod; both also allow `host` (probes, port-forward).
- **AbuseIPDB ingress deny**: `CiliumClusterwideNetworkPolicy deny-abuseipdb-ingress` selects
  `reserved:ingress` and denies `fromCIDRSet: cidrGroupRef: abuseipdb`. The group is maintained at
  runtime by the `abuseipdb-sync` controller (never committed to Git). See
  `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`.

### 3.4 Gateway API (`gitops/infrastructure/controllers/gateway-api/`)
- Standard Gateway API `v1.6.3` CRDs (including `HTTPRoute`, `Gateway`, `GatewayClass`, `TLSRoute`) installed via `standard-install.yaml`

---

## 4. GitOps Layer (Flux CD 2.10.x, managed by the Flux Operator)

### 4.1 Kustomization Dependency Chain
```
flux-system (generated by the FluxInstance; flux-operator → flux-instance manage Flux itself;
             it also applies cluster-vars and image-automation/ directly)
    │
    ▼
infra-controllers (Gateway API CRDs + HelmReleases: Cilium, cert-manager,
                    CoreDNS, Proxmox CSI, Kyverno)
    │
    ├──▶ falco (runtime security; own Kustomization so a failed Falco release blocks nothing else)
    ├──▶ abuseipdb (AbuseIPDB synchronizer → CiliumCIDRGroup + Cloudflare IP list)
    ├──▶ trivy-operator (Trivy vulnerability/config-audit/compliance operator)
    ├──▶ kyverno-policies (CEL ValidatingPolicies + ImageValidatingPolicies)
    ├──▶ renovate ──▶ renovate-job (daily dependency update PRs)
    ▼
infra-configs (Cilium IP pool + L2 policy + Hubble isolation, GatewayClass, PriorityClass,
               ClusterIssuers, AbuseIPDB deny)
    │
    ▼
taskflow-app ──(applied)──────▶ monitoring (VictoriaMetrics + Grafana + CRDs;
(SOPS-decrypted app manifests)   SOPS-decrypted Grafana admin secret; also needs infra-controllers)
    │                                  │
    ├──▶ policy-reporter (+ oauth2)    ├──▶ monitoring-app (VMServiceScrapes + 7 Grafana dashboards)
    ├──▶ hubble-ui (oauth2-proxy)      └──▶ monitoring-logging (Alloy + Loki + 6 Grafana dashboards)
    ├──▶ reloader (scoped rollout)
    ▼
(image automation commits new digests for taskflow-backend and taskflow-frontend)
```
> `monitoring` depends on both `infra-controllers` and `taskflow-app` (its Grafana
> route targets the TaskFlow Gateway), not on `infra-configs`; `monitoring-app`
> depends on `monitoring` (so the VMServiceScrape CRD exists before the VMServiceScrapes
> are applied); `abuseipdb` depends on `infra-controllers` (Cilium CRDs).
> `policy-reporter` also waits for `trivy-operator`, `reloader` also for `abuseipdb`, and
> `monitoring-logging` also for every platform Kustomization whose namespace Alloy tails
> (full list in §4.2).
>
> **Two kinds of dependency.** Where a Kustomization needs CRDs or a working
> controller from its dependency, `dependsOn` uses Flux's built-in check (the
> dependency is Ready). Where it only needs objects to *exist* (a namespace for an
> Alloy or Reloader Role, the Gateway an HTTPRoute attaches to), the entry carries a
> `readyExpr` that is true once the dependency has applied at least once (non-empty
> `status.inventory`), whether or not its workloads are currently healthy. Marked
> *(applied)* in the table below. This keeps a stuck TaskFlow rollout (image
> automation rolls the app often) from freezing monitoring, logging, Hubble UI,
> Policy Reporter and Reloader, which are what you need to debug it. On a fresh
> cluster the ordering is unchanged: nothing has an inventory until it has applied.

### 4.2 Flux Kustomizations
| Name | Path | Interval | Prune | Wait | Timeout | Depends On |
|------|------|----------|-------|------|---------|------------|
| `flux-operator` | `./gitops/infrastructure/controllers/flux-operator` | 1h | ✅ | ✅ | 5m | — |
| `flux-instance` | `./gitops/infrastructure/flux-instance` | 1h | ✅ | ✅ | 10m | flux-operator |
| `infra-controllers` | `./gitops/infrastructure/controllers` | 30m | ✅ | ✅ | 10m | — |
| `falco` | `./gitops/infrastructure/controllers/falco` | 30m | ✅ | ✅ | 10m | infra-controllers |
| `infra-configs` | `./gitops/infrastructure/configs` | 30m | ✅ | ✅ | 10m | infra-controllers |
| `abuseipdb` | `./gitops/platform/abuseipdb` | 30m | ✅ | ✅ | 5m | infra-controllers |
| `taskflow-app` | `./gitops/apps/taskflow` | 10m | ✅ | ✅ | 5m | infra-configs |
| `reloader` | `./gitops/infrastructure/controllers/reloader` | 1h | ✅ | ✅ | 5m | taskflow-app *(applied)*, abuseipdb *(applied)* |
| `monitoring` | `./gitops/monitoring/platform` | 30m | ✅ | ✅ | 10m | infra-controllers, taskflow-app *(applied)* |
| `monitoring-app` | `./gitops/monitoring/app` | 30m | ✅ | ✅ | 10m | monitoring |
| `monitoring-logging` | `./gitops/monitoring/logging` | 30m | ✅ | ✅ | 10m | monitoring; *(applied)*: taskflow-app, trivy-operator, policy-reporter, hubble-ui, reloader, renovate, falco |
| `kyverno-policies` | `./gitops/apps/kyverno-policies` | 30m | ✅ | ✅ | 5m | infra-controllers |
| `policy-reporter` | `./gitops/platform/policy-reporter` | 30m | ✅ | ✅ | 10m | infra-controllers, taskflow-app *(applied)*, trivy-operator |
| `trivy-operator` | `./gitops/infrastructure/controllers/trivy-operator` | 30m | ✅ | ✅ | 5m | infra-controllers |
| `hubble-ui` | `./gitops/platform/hubble-ui` | 10m | ✅ | ✅ | 5m | infra-controllers, taskflow-app *(applied)* |
| `renovate` | `./gitops/platform/renovate` | 1h | ✅ | ✅ | 5m | infra-controllers |
| `renovate-job` | `./gitops/platform/renovate/job` | 1h | ✅ | ✅ | 5m | renovate |

### 4.3 Image Automation (Digest Pinning)

How a new backend or frontend build reaches the cluster:

```
1. CI pushes a new :latest to ghcr.io/stefanf81/taskflow-backend (or -frontend)
2. ImageRepository (gitops/clusters/taskflow/image-automation/) polls ghcr every 10m
3. ImagePolicy (filter ^latest$, digestReflectionPolicy: Always) records the new digest
4. ImageUpdateAutomation rewrites the marker line in gitops/apps/taskflow/backend.yaml
     image: ...:latest # {"$imagepolicy": "flux-system:taskflow-backend"}
   to ...:latest@sha256:<digest> and commits it to main
   (author fluxcdbot, pushed with the flux-system PAT)
5. taskflow-app reconciles the change and rolls the Deployment
```

`:latest` alone is mutable; pinning its digest in Git makes every rollout auditable (`git log`
on `backend.yaml` shows which image ran when), and a `kubectl rollout restart` cannot change the
software. Setup requirements and troubleshooting: `gitops/FLUX_BOOTSTRAP.md` §6. The WAF and
`abuseipdb-sync` images are not automated this way; they are pinned `tag@digest` (Renovate).

### 4.4 Secrets Protection
- **SOPS** v3.13.3 with age encryption (`AES256_GCM`)
- Creation rule: `.*-secrets\.yaml$` with `encrypted_regex: ^(data|stringData)$` → encrypted with recipient `age14tnw8z...xnm22`
- Flux decrypts via `sops-age` Secret in `flux-system` namespace

---

## 5. Application Layer (TaskFlow)

### 5.1 Architecture Diagram
```
Gateway `taskflow-gateway` (Cilium, :80/:443)
  ├── `/api/v1/appointments/events` (31m) ──▶ backend WAF ──▶ backend:8080
  ├── `/api` (10s) ────────────────────────▶ backend WAF ──▶ backend:8080
  ├── `/` ────────────────────────────────▶ frontend WAF ─▶ frontend:8080
  ├── `grafana.jokelab.dev` ──────────────▶ Grafana (monitoring)
  ├── `kyverno.jokelab.dev` ──────────────▶ oauth2-proxy ──▶ Policy Reporter UI
  └── `hubble.jokelab.dev` ───────────────▶ oauth2-proxy ──▶ Hubble UI (kube-system)

Backend ──▶ Redis (64MB LRU)
Backend ──▶ Jaeger (OTLP; UI is internal and port-forward-only)
Backend ──▶ PostgreSQL (10Gi Proxmox CSI `proxmox-csi-db`)

VictoriaMetrics vmagent (monitoring) ──scrapes──▶ backend, exporters, Falco, Trivy, Cilium/Hubble/Envoy, CoreDNS, cert-manager, Kyverno, Policy Reporter, abuseipdb-sync
VictoriaMetrics TSDB ──▶ 8Gi Proxmox CSI PVC
```

### 5.2 Backend Deployment (`gitops/apps/taskflow/backend.yaml`)
| Property | Value |
|----------|-------|
| Image | `ghcr.io/stefanf81/taskflow-backend:latest` (digest-pinned by Flux) |
| Replicas | 1 |
| JVM Heap | Fixed 1 GiB — owned by the deployment's `JAVA_TOOL_OPTIONS` via `-XX:MaxRAMPercentage=50.0 -XX:InitialRAMPercentage=50.0` at the 2 GiB limit |
| GC | G1 with StringDedup, AlwaysPreTouch, ParallelRefProc, DisableExplicitGC |
| Base OS / runtime | Ubuntu 26.04 LTS (Java 25 AOT cache via `-XX:AOTCache`); `MALLOC_ARENA_MAX=2` caps glibc arenas (BENCHMARKS.md §51) |
| OOM Policy | `-XX:+ExitOnOutOfMemoryError` + `-XX:+HeapDumpOnOutOfMemoryError` (`/var/log/taskflow`) |
| Resources | CPU: 500m request, no limit; Memory: 1536Mi request / 2Gi limit (Burstable QoS) |
| SecurityContext | `hostUsers: false`, `readOnlyRootFilesystem: true`, `runAsNonRoot` UID/GID 10001, drop ALL capabilities |
| Init Container | `alpine:3.24.4` — waits for DB (port 5432) + Redis (port 6379) via nc |
| Probes | Startup: `/actuator/health/liveness`, Liveness: same, Readiness: `/actuator/health/readiness` |
| Termination Grace Period | 45s (10s `preStop` sleep + 30s Spring graceful shutdown) |

### 5.3 Frontend Deployment (`gitops/apps/taskflow/frontend.yaml`)
| Property | Value |
|----------|-------|
| Image | `ghcr.io/stefanf81/taskflow-frontend:latest` (digest-pinned by Flux) |
| Replicas | 1 |
| Resources | CPU: 25m request, no limit; Memory: 32Mi request / 256Mi limit (Burstable QoS) |
| SecurityContext | `hostUsers: false`, `readOnlyRootFilesystem: true`, `runAsNonRoot` UID/GID 10001, drop ALL capabilities |
| Volumes | `tmp-volume` (`/tmp`), `var-cache-volume` (`/var/cache/nginx`), `var-run-volume` (`/var/run`) — emptyDir; `upstream-config` (`/etc/nginx/upstream-server.conf` ConfigMap) |
| Probes | All probes on `/index.html` port 8080 |

### 5.4 PostgreSQL Deployment (`gitops/apps/taskflow/postgres-db.yaml`)
| Property | Value |
|----------|-------|
| Image | `postgres:18.7-alpine` |
| Replicas | 1 |
| Storage | 10 GiB PVC (`postgres-data`), `storageClassName: proxmox-csi-db` (`cache: none`, `noatime`, ReadWriteOnce) |
| SecurityContext | `readOnlyRootFilesystem: true`, `runAsNonRoot` UID/GID 70 (postgres), drop ALL capabilities, `fsGroup: 70` (`OnRootMismatch`) |
| Tuning | `shared_buffers=128MB`, `effective_cache_size=384MB`, `work_mem=8MB`, `maintenance_work_mem=64MB`, `autovacuum_work_mem=32MB`, `max_connections=80`, `jit=off`, `shared_preload_libraries=pg_stat_statements` |
| SSD / WAL tuning | `random_page_cost=1.1`, `effective_io_concurrency=200`, `checkpoint_timeout=15min`, `wal_buffers=16MB`, `wal_compression=lz4`, `max_wal_size=2GB`, `synchronous_commit=on` |
| Resources | CPU: 250m request, no limit; Memory: 768 MiB (request = limit) |

### 5.5 Redis Deployment (`gitops/apps/taskflow/redis.yaml`)
| Property | Value |
|----------|-------|
| Image | `redis:8.10.3-alpine` |
| Replicas | 1 |
| Storage | emptyDir (ephemeral, no persistence) |
| Memory Guard | `--maxmemory 64mb`, `allkeys-lru`, lazyfree eviction, 10 samples |
| Resources | CPU: 50m request, no limit; Memory: 128 MiB (request = limit) |

### 5.6 Jaeger Deployment (`gitops/apps/taskflow/jaeger.yaml`)
| Property | Value |
|----------|-------|
| Image | `jaegertracing/jaeger:2.23.0` |
| Replicas | 1 |
| Memory Guard | `--set=extensions.jaeger_storage.backends.some_storage.memory.max_traces=5000` (`GOMEMLIMIT=200MiB`) |
| Ports | Health: 13133, UI: 16686, OTLP-gRPC: 4317, OTLP-HTTP: 4318 |
| Resources | CPU: 25m request, no limit; Memory: 64–256 MiB |

### 5.7 Cloudflare DDNS (`gitops/apps/taskflow/cloudflare-ddns.yaml`)
Keeps the `jokelab.dev`, `www.jokelab.dev`, `grafana.jokelab.dev`,
`kyverno.jokelab.dev`, and `hubble.jokelab.dev` Cloudflare-proxied (`PROXIED=true`)
DNS A records synced to the router's public WAN IP (port-forwarded 80/443 → Cilium
Gateway `192.168.50.201`). Uses `favonia/cloudflare-ddns` with a SOPS-encrypted
Cloudflare API token.

### 5.8 Data-Tier Network Policies (`network-policy.yaml`, `redis.yaml`, `jaeger.yaml`)
| Target | Allowed From | Port(s) | Protocol |
|--------|-------------|---------|----------|
| postgres-db | `app: taskflow-backend`, `app: postgres-exporter` | 5432 | TCP |
| redis | `app: taskflow-backend`, `app: redis-exporter` | 6379 | TCP |
| jaeger | `app: taskflow-backend` | 4317, 4318 (OTLP only; UI 16686 is port-forward-only) | TCP |

### 5.9 Gateway & Routing (`gateway.yaml` + `httproute.yaml`)
- **Gateway**: `taskflow-gateway`, class `cilium`, ports 80/443, allowed routes restricted to
  the namespaces `taskflow`, `monitoring`, `policy-reporter` and `hubble-ui`. Its address
  (`192.168.50.201`, `GATEWAY_IP` in `cluster-vars`, from the `192.168.50.200–250` pool) is
  allocated by Cilium LB-IPAM and announced over L2; k3s ServiceLB is disabled. All Services
  are `ClusterIP`: nothing is reachable except through the Gateway.
- **Host-based routing.** The listeners set no `hostname`; each HTTPRoute matches its own
  hostnames, so a request without a matching `Host` header gets no route (no wildcard):

  | Route | Hostname | Backend |
  |---|---|---|
  | `taskflow-route` | `www.jokelab.dev` | backend/frontend WAFs (rules below) |
  | `monitoring-routes` | `grafana.jokelab.dev` | Grafana |
  | `policy-reporter-ui` | `kyverno.jokelab.dev` | oauth2-proxy → Policy Reporter UI |
  | `hubble-ui` | `hubble.jokelab.dev` | oauth2-proxy → Hubble UI |

  On port 80, `http-to-https-redirect` answers all five names (apex, `www`, `grafana`,
  `kyverno`, `hubble`) with a 301 to HTTPS; `apex-to-www-redirect` sends `https://jokelab.dev`
  to `www`.
- **`taskflow-route` rules** (first match wins):
  1. `/api/v1/appointments/events` (Exact) → backend WAF:8080 (backendRequest timeout 31m, SSE)
  2. `/api` → backend WAF:8080 (backendRequest timeout 10s)
  3. `/` → frontend WAF:8080
- **Same origin.** The frontend and `/api` share `www.jokelab.dev`, so browser API calls are
  same-origin and need no CORS. The apex stays in `APP_CORS_ALLOWED_ORIGINS` (`configmap.yaml`)
  as a safety net only.
- **Outside the cluster:** Cloudflare-proxied DNS (§5.7) → router WAN IP → port-forward 80/443 →
  `192.168.50.201`. CoreDNS maps the same hostnames to `192.168.50.201` inside the cluster
  (hairpin NAT). Testing from the LAN without Cloudflare needs router NAT reflection or a local
  DNS/hosts entry pointing at the Gateway IP.
- Jaeger UI is intentionally **not** exposed (no auth in front of it): `kubectl port-forward -n
  taskflow svc/jaeger-ui 16686:16686`. VMSingle is internal too (§5.10).

### 5.10 Monitoring Stack (`gitops/monitoring/`)
| Component | Implementation |
|-----------|----------------|
| VictoriaMetrics + Grafana | `victoria-metrics-k8s-stack` HelmRelease (chart 0.98.1) in namespace `monitoring` |
| CRDs | Installed by the chart (VMServiceScrape, VMSingle, …) |
| Persistence | VictoriaMetrics TSDB on a **Proxmox CSI-backed PVC** (8Gi) via `vmsingle.spec.storage` (StorageClass `proxmox-csi`) |
| Grafana auth | GitHub OAuth authentication (`auth.github`) with credentials from a **SOPS-encrypted** secret (`grafana-secrets.yaml`); Grafana UI is routed via the Gateway API (see `routes.yaml`); VictoriaMetrics UI is kept strictly internal and accessed via port-forwarding |
| App metrics | `VMServiceScrape`s in `gitops/monitoring/app` scrape the backend (`/actuator/prometheus`), `postgres-exporter`, and `redis-exporter` |
| DB/Redis metrics | Standalone exporter Deployments (`postgres-exporter.yaml` using `db-secret`, `redis-exporter.yaml` using `redis-secret` in `gitops/apps/taskflow`) — **no backend change required** |
| Backend metrics | Spring Boot Actuator and `micrometer-registry-prometheus` expose `/actuator/prometheus`; the VMServiceScrape selects the backend's named `http` Service port. |
| Security/denylist dashboards | Grafana `AbuseIPDB Security` (feed + sink health) and `Blocked Sources` (per-IP Cloudflare blocks from the Security Events collector and per-IP Cilium denials from the Hubble flow export shipped by Alloy to Loki). |


**Flux Kustomizations** (full graph in §4.1):
- **`monitoring`** (`gitops/monitoring/platform`): the VictoriaMetrics operator and CRDs,
  Grafana (SOPS secret), the TSDB PVC. Depends on `infra-controllers` and `taskflow-app`
  (its Grafana route attaches to the TaskFlow Gateway).
- **`monitoring-app`** (`gitops/monitoring/app`): the VMServiceScrapes and seven dashboards
  (`TaskFlow Performance`, `AbuseIPDB Security`, `Blocked Sources`, `cert-manager`,
  `Kyverno`, and `Cilium Agent` / `Hubble Flows` vendored from the Cilium chart).
- **`monitoring-logging`** (`gitops/monitoring/logging`): Loki (monolithic, Service port 3100,
  no gateway) and Alloy, which ships the TaskFlow app and WAF logs, `abuseipdb-sync` logs,
  the Hubble flow export, and the pod logs of 12 platform namespaces (`job="cluster-platform"`:
  `monitoring`, `falco`, `flux-system`, `kube-system`, `cert-manager`, `kyverno`, `csi-proxmox`,
  `trivy-system`, `policy-reporter`, `hubble-ui`, `reloader`, `renovate`), excluding Trivy
  scan-job payloads. Alloy also derives the bounded `loki_process_custom_taskflow_waf_*`
  counters. It depends (applied once) on every Kustomization whose namespace it tails, so the
  namespaces exist before Helm renders Alloy's namespaced RBAC. Dashboards: `Taskflow WAF`,
  `Taskflow Access Logs`, `Taskflow Rate Limits`, `Falco`, `Trivy Operator`, `Logging pipeline`.
  Details: `docs/TASKFLOW_WAF_ARCHITECTURE.md` § Logging Stack.
- Grafana folders: Security, Taskflow and Platform; dashboard conventions are in
  `gitops/monitoring/logging/dashboards/SOURCE.md`.

**Reaching the UIs:** Grafana at `https://grafana.jokelab.dev` (GitHub OAuth; the rendered
break-glass admin Secret is `grafana-admin`). VMSingle stays internal:
`kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8428:8428`, then
`http://localhost:8428/vmsingle/`.

**Resource budget:** VMSingle `768Mi` req / `1536Mi` limit, vmagent `192Mi`/`512Mi`, Grafana
`384Mi`/`1Gi` plus two sidecars at `128Mi`/`256Mi`, VM operator `64Mi`/`128Mi`, vmalert
`32Mi`/`128Mi`, Loki `128Mi`/`512Mi`, Alloy `128Mi`/`512Mi`. VictoriaMetrics keeps **14d**,
Loki **30d**; app scrapes run every 30–60s. Node sizing: `docs/PERFORMANCE.md` and
`docs/NODE_HOST_TUNING.md` (host memory).

---

## 6. Security Posture

| Control | Implementation |
|---------|---------------|
| Zero-trust networking | Cilium network policies restrict all inter-service access; only backend (plus the matching exporter for Postgres/Redis) can reach DB/Redis/Jaeger. A namespace-level default-deny (`namespace-default-deny.yaml`) blocks ALL ingress to the `taskflow` namespace by default, then selectively re-opens only the Gateway (Envoy) → WAFs, WAF → app, `vmagent` scrapes and cert-manager's HTTP-01 solver. Egress is restricted only for the two WAFs (see §9) |
| IP reputation denylist | AbuseIPDB feed enforced at two layers by `abuseipdb-sync`: Cloudflare edge (IP list + zone WAF block rule — sees real client IPs behind the proxy) and Cilium (`CiliumCIDRGroup` + cluster-wide deny on `reserved:ingress` — direct-to-origin traffic). Caddy/Coraza are untouched. See `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md` |
| Pod security | Every TaskFlow container runs `runAsNonRoot`, `allowPrivilegeEscalation=false`, drops ALL capabilities and has a read-only root filesystem (only in-memory Jaeger omits it); writable paths are explicit `emptyDir`/PVC mounts. UIDs: backend, frontend, Redis, Jaeger and exporters `10001`, WAFs `65532`, DDNS `1000`, Postgres the image-native `70` (its volume ownership depends on it). |
| Jaeger UI | No Gateway route and no ingress rule for `16686`; port-forward only, because it has no auth. |
| Secrets encryption | All nine `*-secrets.yaml` files are SOPS/age-encrypted and decrypted by Flux at apply time (`docs/SOPS.md`); `key.txt` is ignored by Git |
| Image pinning | Flux image automation rewrites `:latest` to `@sha256:<digest>` — immutable references in Git |
| Grafana & VM UIs | Grafana UI is exposed securely on the Gateway at `grafana.jokelab.dev` (protected by GitHub OAuth with SOPS-encrypted credentials). VictoriaMetrics (VMSingle) is kept strictly internal to protect operational metrics, accessible privately via port-forwarding. |
| In-cluster scrape only | VictoriaMetrics scrapes taskflow services over the cluster network (plain HTTP, no auth). The backend must therefore permit `GET /actuator/prometheus` unauthenticated (see `docs/BACKEND_INTEGRATION_CONTEXT.md` §2.3). |
| SSH hardening | kubeconfig fetch disables strict host key checking and uses `UserKnownHostsFile=/dev/null` (homelab convenience: the host key is not pinned); `BatchMode=yes`, 10s connect timeout |
| Cloud-init isolation | k3s installed via cloud-init user-data heredoc from column 0 (no whitespace parsing issues) |

---

## 7. File Structure Reference

```
homelab-TF/
├── main.tf                          # Root: proxmox + k3s-kubeconfig modules
├── providers.tf                     # bpg/proxmox v0.122.0, >= 1.8.0
├── variables.tf                     # All input vars (VM specs, SSH key, k3s token)
├── terraform.tfvars.example         # Template for the (ignored) terraform.tfvars
├── Makefile                         # OpenTofu workflow with plugin cache, validate/lint, bootstrap-foundation
├── mise.toml                        # Pinned CLI toolchain (OpenTofu, kubectl, Flux, SOPS, ...)
├── .gitignore                       # State files, secrets, kubeconfig, keys
├── .sops.yaml                       # SOPS age encryption rules
├── kubeconfig.yaml                  # (ignored) k3s cluster access
├── key.txt                          # (ignored) SOPS age private key
├── scripts/                         # bootstrap-foundation.sh, validate-gitops.sh, CI check scripts
├── .github/                         # CI workflows, Renovate config
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
│       └── variables.tf             # IP, VM rebuild id, SSH user, output path
│
├── gitops/
│   ├── README.md                    # GitOps directory overview
│   ├── FLUX_BOOTSTRAP.md            # GitHub + Flux bootstrap steps
│   ├── RENOVATE.md                  # Renovate activation and operation
│   │
│   ├── apps/taskflow/               # Application manifests (kustomize)
│   │   ├── namespace.yaml           # taskflow namespace (PSA restricted) + LimitRange
│   │   ├── configmap.yaml           # SPRING_PROFILES_ACTIVE, CORS origins, trusted-proxy/client-IP, Tomcat settings
│   │   ├── taskflow-secrets.yaml    # SOPS-encrypted: POSTGRES_PASSWORD, SPRING_SECURITY_PASSWORD, REDIS_PASSWORD, CLOUDFLARE_API_TOKEN
│   │   ├── taskflow-jwt-secrets.yaml # SOPS-encrypted: APP_RSA_PRIVATE_KEY, APP_RSA_PUBLIC_KEY
│   │   ├── backend.yaml             # Spring Boot deployment + ClusterIP service
│   │   ├── frontend.yaml            # Angular/nginx deployment + ClusterIP service + upstream ConfigMap
│   │   ├── postgres-db.yaml         # PostgreSQL 18 deployment + ClusterIP service (name: db) + PDB
│   │   ├── postgres-pvc.yaml        # 10Gi Proxmox CSI PVC postgres-data (proxmox-csi-db)
│   │   ├── postgres-exporter.yaml   # postgres-exporter deployment + service (:9187)
│   │   ├── redis.yaml               # Redis 8.10 deployment + ClusterIP service + NetworkPolicy
│   │   ├── redis-exporter.yaml      # redis-exporter deployment + service (:9121)
│   │   ├── jaeger.yaml              # Jaeger all-in-one + OTLP services + UI service + NetworkPolicy
│   │   ├── gateway.yaml             # Cilium Gateway (port 80/443, restricted namespace routes)
│   │   ├── httproute.yaml           # /api→backend WAF, /→frontend WAF (Jaeger UI NOT exposed)
│   │   ├── http-redirect.yaml       # HTTP→HTTPS 301 redirect + apex→www redirect
│   │   ├── network-policy.yaml      # DB access restriction (backend + postgres-exporter ingress)
│   │   ├── default-deny.yaml        # Default-deny ingress for data tier (postgres, redis, jaeger)
│   │   ├── namespace-default-deny.yaml  # Full-namespace default-deny + Gateway/WAF/vmagent allow-lists, WAF egress
│   │   ├── backend-waf.yaml         # Backend Caddy+Coraza WAF deployment + service + config
│   │   ├── frontend-waf.yaml        # Frontend Caddy+Coraza WAF deployment + service + config
│   │   ├── backend-pdb.yaml         # PodDisruptionBudget (maxUnavailable: 1)
│   │   ├── frontend-pdb.yaml        # PodDisruptionBudget (maxUnavailable: 1)
│   │   ├── certificate.yaml         # Let's Encrypt TLS cert for jokelab.dev + subdomains
│   │   ├── cloudflare-ddns.yaml     # Dynamic DNS updater for Cloudflare
│   │   └── kustomization.yaml       # Resource ordering
│   ├── apps/kyverno-policies/       # CEL Validating/ImageValidatingPolicies (fail-open)
│   │
│   ├── infrastructure/
│   │   ├── flux-instance/           # FluxInstance CR managed by Flux Operator
│   │   ├── controllers/             # HelmRelease + OCIRepository/HelmRepository for platform add-ons
│   │   │   ├── cilium/release.yaml  # Cilium v1.20.5 (eBPF, Gateway API, L2 announcements)
│   │   │   ├── cert-manager/        # cert-manager HelmRelease (v1.21.3) with Let's Encrypt certificate automation
│   │   │   ├── coredns/             # CoreDNS HelmRelease (v1.50.8) — replaces K3s packaged addon
│   │   │   ├── proxmox-csi/         # Proxmox CSI driver (dynamic storage provisioning)
│   │   │   ├── gateway-api/         # Vendored Gateway API v1.6.3 standard bundle
│   │   │   ├── kyverno/             # Kyverno policy engine (v3.10.0 / Kyverno v1.20.0)
│   │   │   ├── falco/               # Falco runtime security (v9.2.2 chart, modern eBPF; own Kustomization)
│   │   │   ├── trivy-operator/      # Trivy vulnerability scanner operator (own Kustomization)
│   │   │   ├── reloader/            # Stakater Reloader (own Kustomization)
│   │   │   └── flux-operator/       # Flux Operator HelmRelease (own Kustomization)
│   │   │
│   │   └── configs/                 # Cilium IP pool, L2 policy, GatewayClass, ClusterIssuers, deny/isolation policies
│   │       ├── cilium/ippool.yaml           # 192.168.50.200–250
│   │       ├── cilium/l2announcement-policy.yaml  # eth* + enp* + ens* interfaces
│   │       ├── cilium/abuseipdb-ingress-deny.yaml # reserved:ingress deny via cidrGroupRef
│   │       ├── cilium/hubble-isolation.yaml # kube-system Hubble UI/Relay pod-network isolation
│   │       ├── priorityclasses.yaml         # PriorityClass/taskflow-critical
│   │       ├── letsencrypt-http01-issuers.yaml # Let's Encrypt ClusterIssuers
│   │       └── gatewayclass.yaml            # Cilium GatewayClass
│   │
│   ├── platform/                    # Platform workloads with dedicated Kustomizations
│   │   ├── policy-reporter/         # Policy Reporter + UI + Trivy adapter + oauth2-proxy
│   │   ├── hubble-ui/               # Hubble UI oauth2-proxy (GitHub OAuth, public access)
│   │   ├── abuseipdb/               # AbuseIPDB synchronizer (IP reputation → Cilium + Cloudflare)
│   │   └── renovate/                # Renovate Operator + scheduled RenovateJob
│   │
│   ├── images/                      # Custom image sources
│   │   ├── taskflow-caddy-coraza/   # Caddy + Coraza WAF image
│   │   └── abuseipdb-sync/          # Go synchronizer (blacklist → Cilium + Cloudflare, flow collection)
│   │
│   ├── clusters/taskflow/           # Flux Kustomizations (cluster-level)
│   │   ├── kustomization.yaml       # References all layers
│   │   ├── cluster-vars.yaml        # DOMAIN, GATEWAY_IP, NODE_IP, LAN_CIDR, LB_POOL_*
│   │   ├── flux-operator.yaml       # Flux Operator HelmRelease, then the FluxInstance (Flux itself)
│   │   ├── infra-controllers.yaml   # HelmRelease controllers (Cilium, Proxmox CSI, etc.)
│   │   ├── falco.yaml               # Falco (dependsOn infra-controllers)
│   │   ├── infra-configs.yaml       # Cilium configs + GatewayClass + deny policy
│   │   ├── abuseipdb.yaml           # AbuseIPDB synchronizer (dependsOn infra-controllers)
│   │   ├── taskflow.yaml            # App layer with SOPS decryption
│   │   ├── reloader.yaml            # Stakater Reloader (dependsOn taskflow-app + abuseipdb)
│   │   ├── monitoring.yaml          # VictoriaMetrics + Grafana (SOPS-enabled)
│   │   ├── monitoring-app.yaml      # App VMServiceScrapes + Grafana dashboards (depends on monitoring)
│   │   ├── monitoring-logging.yaml  # Alloy + Loki (depends on monitoring, taskflow-app, platform namespaces)
│   │   ├── kyverno-policies.yaml    # Kyverno ValidatingPolicies (dependsOn infra-controllers)
│   │   ├── policy-reporter.yaml     # Policy Reporter + UI (dependsOn infra-controllers + taskflow-app + trivy-operator)
│   │   ├── trivy-operator.yaml      # Trivy vulnerability scanner (dependsOn infra-controllers)
│   │   ├── hubble-ui.yaml           # Hubble UI oauth2-proxy (dependsOn infra-controllers + taskflow-app)
│   │   ├── renovate.yaml            # Renovate Operator (dependsOn infra-controllers)
│   │   ├── renovate-job.yaml        # RenovateJob schedule (dependsOn renovate)
│   │   └── image-automation/        # ImageRepository + ImagePolicy + ImageUpdateAutomation
│   │
│   └── monitoring/                  # Observability stack
│       ├── platform/                # Operator + CRDs + storage + Grafana secret
│       │   ├── README.md            # Deployment-safety notes (vmalert, vmagent queue, Recreate strategies)
│       │   ├── namespace.yaml       # monitoring namespace
│       │   ├── repository.yaml      # victoriametrics HelmRepository
│       │   ├── grafana-secrets.yaml # SOPS-encrypted Grafana admin & GitHub OAuth (age-encrypted)
│       │   ├── release.yaml         # victoria-metrics-k8s-stack HelmRelease (tuned; sidecar folder provisioning)
│       │   ├── network-policies.yaml # monitoring ingress default-deny + Loki cross-namespace allow
│       │   ├── routes.yaml          # HTTPRoute for Grafana
│       │   ├── metrics-server-release.yaml  # metrics-server HelmRelease
│       │   ├── metrics-server-repository.yaml # metrics-server HelmRepository
│       │   ├── metrics-server-rbac.yaml       # metrics-server RBAC
│       │   └── kustomization.yaml
│       ├── app/                     # VMServiceScrapes + dashboards (applied after CRDs exist)
│       │   ├── vmservicescrapes.yaml # backend / postgres-exporter / redis-exporter / falco / trivy / cilium agent+operator+envoy / hubble / coredns / cert-manager / kyverno / policy-reporter
│       │   ├── abuseipdb.yaml        # AbuseIPDB synchronizer VMServiceScrape
│       │   ├── dashboards/           # AbuseIPDB Security, Blocked Sources, TaskFlow Performance, cert-manager, Kyverno, Cilium Agent, Hubble Flows
│       │   │                         # (standalone JSON + configMapGenerator + SOURCE.md)
│       │   └── kustomization.yaml
│       ├── logging/                 # Alloy + Loki for WAF audit + flow + pod log collection
│       │   ├── alloy-pvc.yaml       # 1Gi Proxmox CSI PVC for Alloy WAL and file positions
│       │   ├── alloy-release.yaml   # Grafana Alloy Deployment (WAF logs, app logs, abuseipdb, 12 platform namespaces, Hubble flow file)
│       │   ├── loki-release.yaml    # Grafana Loki (monolithic, 10Gi PVC, 30-day retention, no gateway)
│       │   ├── loki-datasource.yaml # Loki datasource auto-provisioned in Grafana
│       │   ├── dashboards/          # Falco, Trivy, WAF, access-log, rate-limit, Logging pipeline dashboards
│       │   │                        # (standalone JSON + configMapGenerator + SOURCE.md)
│       │   ├── repositories.yaml    # HelmRepository definitions
│       │   ├── vmservicescrapes.yaml # Loki + Alloy metrics scrapes
│       │   └── kustomization.yaml
│       └── tests/                   # Offline dashboard/Alloy/Loki validators (not reconciled by Flux)
```

---

## 8. Changing Things

Make targets are listed in `README.md`; the Flux reconcile order is in `gitops/FLUX_BOOTSTRAP.md` §4.

### 8.1 What to edit

| You want to… | Edit this file | Then |
|--------------|---------------|------|
| Change backend JVM/heap or env | `gitops/apps/taskflow/backend.yaml` | `flux reconcile kustomization taskflow-app -n flux-system` (or wait 10m) |
| Add a new microservice | new Deployment+Service in `gitops/apps/taskflow/`, add to `kustomization.yaml` | Flux picks it up |
| Expose a new URL path | `gitops/apps/taskflow/httproute.yaml` | Flux reconciles Gateway |
| Change the external IP range | `gitops/infrastructure/configs/cilium/ippool.yaml` | `flux reconcile kustomization infra-configs` |
| Rotate a DB/app secret | `sops edit gitops/apps/taskflow/taskflow-secrets.yaml` | Flux re-decrypts on next sync |
| Tune the AbuseIPDB sync (interval, list size, exceptions) | `gitops/platform/abuseipdb/config.yaml` | `flux reconcile kustomization abuseipdb -n flux-system` |
| Pause either denylist sink | `abuseipdb-ingress-deny` file (Cilium) / `CLOUDFLARE_SYNC_ENABLED` (edge) | see rollback in `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md` |
| Rotate the AbuseIPDB key / Cloudflare token | `sops edit gitops/platform/abuseipdb/abuseipdb-secrets.yaml` | Flux re-decrypts on next sync |
| Bump Cilium/Proxmox CSI/cert-manager version | `ref.tag` + `ref.digest` in the relevant `repository.yaml` | Flux upgrades (cert-manager/kyverno/renovate use `crds: Skip`; Cilium/Falco use `CreateReplace`) |
| Change VM size/network | `terraform.tfvars` + `variables.tf` | `make apply` (some changes force a VM recreate, which `prevent_destroy` refuses until lifted; a recreate re-fetches the kubeconfig). Cloud-init is disabled after the first boot: a larger `disk_size` still needs `growpart`/`resize2fs` on the node, and `ip_address` is fixed for the node's lifetime |
| Add a hostname to the TLS cert | `dnsNames` in `gitops/apps/taskflow/certificate.yaml` (the Gateway's HTTPS listener already serves `taskflow-tls-secret`) | cert-manager reissues via the `letsencrypt-http01-production` ClusterIssuer (HTTP-01 needs public DNS for the name first) |
| Change VictoriaMetrics retention / storage | `gitops/monitoring/platform/release.yaml` (`vmsingle.spec.retentionPeriod`, `vmsingle.spec.storage`) | `flux reconcile kustomization monitoring -n flux-system` |
| Rotate the Grafana admin password | `sops edit gitops/monitoring/platform/grafana-secrets.yaml` | Flux re-decrypts on next sync |

### 8.2 Footguns

1. **CORS** (`configmap.yaml`) lists `https://jokelab.dev,https://www.jokelab.dev`. The canonical prod access URL is `www.jokelab.dev` (the `taskflow-route` only serves `www`; the bare apex 301-redirects to it). If you change the published hostname, update this list **and** `certificate.yaml`'s `dnsNames` **and** `httproute.yaml`'s `hostnames`, or the browser's `/api` calls get CORS-rejected.
2. **Jaeger UI has no auth** — don't add a Gateway route for it without putting auth in front.
3. **Postgres UID is 70 on purpose** — don't "standardize" it to `10001`; the Postgres volume ownership depends on 70.
4. **`proxmox_insecure = true`** disables TLS verification to Proxmox. Fine for a self-signed homelab, dangerous anywhere else.
5. **Ubuntu 26.04 ("Resolute")** is pinned to the `release-20261108` cloud image and verified with a SHA-256 checksum in `modules/proxmox/main.tf`.
6. The whole stack is **single-replica** — there is no HA. A node reboot = full downtime. That's the accepted homelab tradeoff, not a bug.
7. **CoreDNS is GitOps-managed** (including the hairpin-NAT `hosts` overrides): change `gitops/infrastructure/controllers/coredns/release.yaml`, never the live ConfigMap.
8. **Encrypted files must stay encrypted:** edit `*-secrets.yaml` only with `sops <file>`; a plaintext edit breaks Flux decryption for the whole Kustomization.

---

## 9. Known Limitations & Future Work

The architectural limits below are the headline items; [`BACKLOG.md`](BACKLOG.md) is the complete, current list of open work, with the IDs used here.

| Area | Current state | Next step |
|------|-------------|------|
| Multi-node HA | Single k3s node | Add worker nodes via additional Proxmox VMs |
| Backend scaling | Intentionally single replica | Local SSE connections and the current database connection budget are not multi-replica safe; add distributed event fan-out and connection pooling before autoscaling. |
| Backup strategy | None configured in this repo. The VM's root disk (k3s datastore) is only protected from accidental `tofu destroy` by `prevent_destroy`; Proxmox CSI attaches PVC disks with `backup=0`, so a VM backup would not include Postgres, Grafana or VictoriaMetrics data | Scheduled vzdump/PBS VM backups to a target off the host SSD, plus `pg_dump`/CSI backups for Postgres (REL-02) |
| Alerting | None: vmalert evaluates only the bundled recording rules (`notifier.blackhole`), Alertmanager is disabled, and there are no alerting rules, Flux notification `Alert`s or dead-man's switch | Add an Alertmanager/notification target and alert rules (REL-01) |
| Egress control | Only the two WAFs, `abuseipdb-sync` and Renovate have egress allow-lists; every other pod (backend, data tier, monitoring, …) has unrestricted egress | Per-namespace egress policies (SEC-04) |
| k3s hardening | No `secrets-encryption` and no API audit log in the k3s config; no automated node reboots or k3s upgrades | SEC-02, SEC-15, REL-08 |

