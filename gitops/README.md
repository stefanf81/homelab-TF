# GitOps Layout

This directory contains the Git repository tree reconciled by Flux (`https://github.com/stefanf81/homelab-TF.git`).
Flux itself is managed declaratively by the Flux Operator via `infrastructure/flux-instance/flux-instance.yaml`;
see `./FLUX_BOOTSTRAP.md` for fresh-cluster bring-up (`make bootstrap-foundation`) and recovery procedures. OpenTofu does not bootstrap Flux.

## Directory Structure & Architecture

```text
gitops/
├── clusters/                   # 1. Cluster entrypoints (The Bootstrap Target)
│   └── taskflow/
├── infrastructure/             # 2. Platform/System services (Helm charts & System configs)
│   ├── controllers/            #   Controllers and CRD providers (Cilium, cert-manager, CoreDNS, Proxmox CSI, Kyverno, Falco, Trivy, Reloader, Flux Operator)
│   ├── flux-instance/          #   FluxInstance managed by the Flux Operator
│   └── configs/
├── platform/                   # 3. Platform workloads with their own Kustomization (need the app tier, SOPS secrets or ordering)
│   ├── policy-reporter/        #   Policy Reporter + UI (dashboard at kyverno.<domain>)
│   ├── hubble-ui/              #   Hubble UI behind oauth2-proxy
│   ├── renovate/               #   Renovate operator and job
│   └── abuseipdb/              #   AbuseIPDB synchronizer (IP reputation -> Cilium + Cloudflare)
├── apps/                       # 4. User-facing applications (TaskFlow frontend, backend, database)
│   ├── taskflow/
│   └── kyverno-policies/       #   CEL ValidatingPolicies (Deny, fail-open); reconciled by kyverno-policies Kustomization
├── monitoring/                 # 5. VictoriaMetrics, Grafana, Loki, Alloy, and dashboards
│   ├── platform/               #   VictoriaMetrics stack, Grafana, routes, grafana secrets
│   ├── app/                    #   App scrapes + 7 Grafana dashboards (TaskFlow Performance, AbuseIPDB Security, Blocked Sources, cert-manager, Kyverno, Cilium Agent, Hubble Flows)
│   └── logging/                #   Loki, Alloy (TaskFlow app/WAF logs + derived WAF metrics, abuseipdb-sync logs, 12 platform namespaces, Hubble flow export) + 6 dashboards (WAF, Access Logs, Rate Limits, Falco, Trivy, Logging pipeline)
├── images/                     # Custom images: WAF (Caddy+Coraza) and abuseipdb-sync Dockerfiles
├── RENOVATE.md                  #   Dependency-update bot activation and operation
├── README.md                   # GitOps directory overview
└── FLUX_BOOTSTRAP.md    # Instructions for remote Git & Flux CD integration
```

**Cluster variables.** `clusters/taskflow/cluster-vars.yaml` holds `DOMAIN`, `GATEWAY_IP`, `NODE_IP`, `LAN_CIDR` and the `LB_POOL_START`/`LB_POOL_STOP` range. Kustomizations that render them (`infra-controllers`, `infra-configs`, `taskflow-app`, `monitoring`, `policy-reporter`, `hubble-ui`, `abuseipdb`) declare `postBuild.substituteFrom: cluster-vars`; manifests use `${DOMAIN}`, `${NODE_IP}` and so on. Write a literal `${...}` as `$${...}`. `scripts/validate-gitops.sh` emulates the substitution and fails if a path uses a variable without the `postBuild` block.

### 1. `clusters/` (The Entrypoint & Orchestration Layer)
This is where your Flux CD controllers start scanning. When you bootstrap Flux on your k3s node, you point it to a subfolder inside `clusters/` (e.g., `gitops/clusters/taskflow/`).

* **Role:** Orchestrates the deployment order using **Kustomization dependency graphs** (`dependsOn`). It ensures platform infrastructure is fully running before application code attempts to deploy.
* **How it works:**
  1. Flux reads `clusters/taskflow/infra-controllers.yaml` and deploys the operators (Cilium, Proxmox CSI, cert-manager).
  2. Once those are healthy, Flux reads `clusters/taskflow/infra-configs.yaml` to deploy configurations (Cilium IP pools).
  3. Finally, Flux reads `clusters/taskflow/taskflow.yaml` to deploy your TaskFlow application, guaranteeing the database persistent volumes (Proxmox CSI) and IP allocations (Cilium L2 announcements) are ready to consume.

### 2. `infrastructure/` (The Platform / Systems Layer)
This layer manages cluster-wide utilities and operators that provide auxiliary services (network, storage, TLS certs) to other workloads in the cluster. It is split into two logical subdirectories to prevent race conditions during deployment:

#### A. `infrastructure/controllers/` (CRD and Operator Deployments)
Contains the system controllers deployed primarily via **HelmReleases** (plus `gateway-api/` static CRDs):
* **`gateway-api/`**: Vendored Gateway API `v1.6.3` standard-channel CRDs and upgrade `ValidatingAdmissionPolicy`.
* **`cilium/`**: Installs Cilium with kube-proxy replacement, Gateway API controller, Hubble, and native L2 announcements (`CiliumLoadBalancerIPPool`).
* **`coredns/`**: Replaces k3s's disabled packaged addon with a GitOps-managed CoreDNS release (`10.43.0.10`, hairpin NAT `hosts` overrides).
* **`proxmox-csi/`**: Installs the Proxmox CSI driver to dynamically provision virtual disk storage on Proxmox VE (`proxmox-csi` default and `proxmox-csi-db` for PostgreSQL).
* **`cert-manager/`**: Handles automated provisioning of Let's Encrypt TLS certificates via Gateway API HTTP-01.
* **`kyverno/`**: Installs the Kyverno policy engine (`admissionController` + `reportsController`; the idle `backgroundController` and `cleanupController` are disabled). Enforces CEL `ValidatingPolicy` CRs (`policies.kyverno.io/v1`). CRDs are owned by the chart (`crds.install: true`); the Flux `HelmRelease` uses `install.crds: Skip` to avoid CRD ownership conflicts.
* **`falco/`**: Installs Falco runtime security as a DaemonSet with the `modern_ebpf` driver and single-replica Falcosidekick writing native Kubernetes `PolicyReport`s. Exposes Prometheus metrics on port 8765.
* **`trivy-operator/`**: Installs the Trivy vulnerability/config-audit/RBAC/infra/secret/compliance scanner operator (`targetNamespaces: "taskflow,abuseipdb"`). Reconciled by its own `trivy-operator` Kustomization (`dependsOn: infra-controllers`).
* **`reloader/`**: Stakater Reloader in namespace-scoped mode (`taskflow`, `abuseipdb`), rolling annotated Deployments on ConfigMap/Secret updates. Reconciled by `reloader` (`dependsOn: taskflow-app, abuseipdb`).
* **`flux-operator/`**: Manages the Flux Operator `HelmRelease` (`flux-operator` Kustomization -> `flux-instance` Kustomization).

*(Workloads that depend on the Gateway, SOPS secrets, or app-tier ordering — **`policy-reporter/`**, **`hubble-ui/`**, **`abuseipdb/`**, and **`renovate/`** — live under `gitops/platform/` with dedicated cluster Kustomizations.)*

#### B. `infrastructure/configs/` (Controller Instances)
Contains the custom configurations and Custom Resources (CRs) consumed by the controllers installed above:
* **`gatewayclass.yaml`**: `GatewayClass/cilium`.
* **`priorityclasses.yaml`**: `PriorityClass/taskflow-critical` (`preemptionPolicy: Never`) for the TaskFlow request path and data stores.
* **`letsencrypt-http01-issuers.yaml`**: Staging and production Let's Encrypt HTTP-01 `ClusterIssuer`s attached to `taskflow-gateway`.
* **`cilium/ippool.yaml`**: Configures the LoadBalancer IP pool (`192.168.50.200 - 192.168.50.250`).
* **`cilium/l2announcement-policy.yaml`**: Advertises LoadBalancer IPs locally via Layer 2 (ARP) using `CiliumL2AnnouncementPolicy`.
* **`cilium/abuseipdb-ingress-deny.yaml`**: `CiliumClusterwideNetworkPolicy` that denies sources from runtime-managed `CiliumCIDRGroup/abuseipdb` at `reserved:ingress` for direct-to-origin traffic.
* **`cilium/hubble-isolation.yaml`**: Locks down `hubble-ui` (`:8081`) and `hubble-relay` (`:4245`) in `kube-system` so in-cluster pods cannot bypass `hubble-ui-oauth2-proxy`.

### 3. `apps/` (The Application Layer)
This layer houses user-facing workloads and microservices. Workloads here are kept separate from the infrastructure layer to allow application developers to deploy code without risking platform-level system configuration.

#### `apps/taskflow/`
This folder represents your **TaskFlow** application (Angular 22, Spring Boot 4.1.1, PostgreSQL 18, Redis 8.10, and Jaeger).
* **`backend.yaml`**: Configures the JVM Spring Boot 4.1.1 server with preflight checks (`wait-for-db` init-container) and a 1 GiB heap (`MaxRAMPercentage=50.0` of its 2 GiB cgroup limit) with G1GC tuning (`JAVA_TOOL_OPTIONS`). The deployment owns the JVM sizing flags. The container image uses the mutable `:latest` tag, which Flux pins to its current `sha256` digest via the `# {"$imagepolicy": ...}` marker (see `../FLUX_BOOTSTRAP.md` §7 — the Git source must be writable and the marker must be the *basic* form, not `:digest`).
* **`backend-waf.yaml` / `frontend-waf.yaml`**: Put Caddy + Coraza CRS in front of the backend and frontend Services. The Gateway routes only to these WAF Services.
* **`frontend.yaml`**: Configures the Angular 22 client packaged with Nginx, utilizing custom emptyDirs to secure a `readOnlyRootFilesystem`. Same Flux digest-pin behavior as the backend.
* **`postgres-db.yaml` & `postgres-pvc.yaml`**: Configures the database storage. *Optimized:* Postgres runs tuned caching params (`shared_buffers=128MB`, `effective_cache_size=384MB`, `work_mem=8MB`, `autovacuum_work_mem=32MB`, `max_connections=50`) within its 768Mi RAM limit, and storage (`postgres-data`) uses `10Gi` on the `proxmox-csi-db` StorageClass (`cache: none`, `noatime`).
* **`redis.yaml`**: Configures the caching layer. *Optimized:* capped at `--maxmemory 64mb` with `allkeys-lru` eviction to avoid OOM-kill cache loss (ephemeral `emptyDir`, no persistence).
* **`jaeger.yaml`**: Configures Jaeger All-in-One telemetry for OTLP trace collection.
*   **`network-policy.yaml`**: Enforces strict network-level isolation (restricting PostgreSQL ingress to backend and `postgres-exporter`).
*   **`default-deny.yaml`**: Default-deny ingress for the data tier (postgres, redis, jaeger) — flips the allow-by-default baseline so `restrict-*` policies actually enforce.
*   **`namespace-default-deny.yaml`**: Extends default-deny to the **entire** `taskflow` namespace, then selectively re-opens the Cilium Gateway (Envoy -> WAFs), WAF -> app paths, and `vmagent`-only monitoring scrapes.
*   **`backend-pdb.yaml`** & **`frontend-pdb.yaml`**: PodDisruptionBudgets (`maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`) so single-node drains/upgrades never deadlock on a single replica.
*   **`certificate.yaml`**: Let's Encrypt ECDSA P-256 TLS certificate for `jokelab.dev`, `www.jokelab.dev`, `grafana.jokelab.dev`, `kyverno.jokelab.dev`, and `hubble.jokelab.dev`.
*   **`http-redirect.yaml`**: HTTP→HTTPS 301 redirect (port 80 → 443) and bare apex `jokelab.dev` → `www.jokelab.dev` redirect.
*   **`cloudflare-ddns.yaml`**: Cloudflare DDNS updater keeping the TaskFlow, Grafana, Policy Reporter, and Hubble host records synced to the public endpoint.
*   **`kustomization.yaml`**: Aggregates all these resources into a single manifest compilation unit for Flux.

## Pre-baked Optimizations inside GitOps

The scaffolded manifests inside this layout include critical performance and networking adjustments:

### 1. Database & Storage Scaling (`apps/taskflow/`)
* **Proxmox CSI Storage Association:** `postgres-pvc.yaml` defines `postgres-data` with `storageClassName: proxmox-csi-db` (`cache: none`, `noatime`) at `10Gi` of virtual disk storage, mapped to the Proxmox node via Kubernetes topology labels (`topology.kubernetes.io/region=homelab`, `topology.kubernetes.io/zone=<proxmox_node>`).
* **PostgreSQL Engine Tuning:** `postgres-db.yaml` tunes buffers, cache sizes, and connection limits within its 768Mi RAM limit (e.g. `shared_buffers=128MB`, `effective_cache_size=384MB`, `work_mem=8MB`, `autovacuum_work_mem=32MB`, `max_connections=50`).

### 2. Modern Kubernetes Gateway API with Cilium (`apps/taskflow/`)
* **Cilium CNI & Gateway API Operator:** Deployed under `infrastructure/controllers/cilium/`. The core Gateway API schemas are fully managed under `infrastructure/controllers/gateway-api/` using a **local-vendored** copy of the official `v1.6.3` standard installation release. This ensures Flux CD performs dry-run validations with 100% compliance, preventing any schema version conflicts or ownership clashes with K3s's built-in platform installers.
* **Unified Gateway & Hostname Routing (`gateway.yaml` & `httproute.yaml`):** The TaskFlow app is securely routed through Cilium-native Gateway API rules scoped to `www.jokelab.dev` on the HTTPS listener. Plain HTTP is redirected to HTTPS:
  * `https://www.jokelab.dev/` maps to the TaskFlow Angular Frontend
  * `https://www.jokelab.dev/api` maps to the Spring Boot Backend API
  * Jaeger UI is **not** exposed via the Gateway (no auth in front of it) — reach it with `kubectl port-forward -n taskflow svc/jaeger-ui 16686:16686`
* **Secure ClusterIP Services:** The backend, frontend, and jaeger Services are configured as internal-only `type: ClusterIP` rather than open `NodePort` resources. All incoming physical traffic is safely parsed and authenticated by the Cilium Gateway controller first.

### 3. GitOps Secrets Workflow (`.sops.yaml` in Root)
* **SOPS Ready:** Matches your `*-secrets.yaml` files. To secure your credentials in Git, generate an age key and run:
  ```bash
  sops -e -i gitops/apps/taskflow/taskflow-secrets.yaml
  ```
  The AbuseIPDB synchronizer uses the same mechanism
  (`gitops/platform/abuseipdb/abuseipdb-secrets.yaml`, holding
  the AbuseIPDB API key and the Cloudflare API token):
  ```bash
  sops gitops/platform/abuseipdb/abuseipdb-secrets.yaml
  ```

### 4. Policy Engine & Dashboard (Kyverno + Policy Reporter)

Kyverno provides Kubernetes-native policy enforcement; Policy Reporter gives it a UI.

* **Controller** — `gitops/infrastructure/controllers/kyverno/` (HelmRelease `kyverno` v3.9.2, shipping Kyverno v1.19.2, single-replica, CRDs owned by the chart). System namespaces (`kube-system`, `flux-system`, `kyverno`, `cert-manager`) are excluded from enforcement.
* **Policies** — `gitops/apps/kyverno-policies/` holds CEL `ValidatingPolicy` resources in **Deny** mode with `failurePolicy: Ignore` (`disallow-latest-tag`, `require-common-labels`). Reconciled by the `kyverno-policies` Kustomization, which `dependsOn: infra-controllers` so the CRDs exist before policies apply.
* **Dashboard** — `gitops/platform/policy-reporter/` (HelmRelease `policy-reporter` v3.11.2, `ui.enabled`, `plugin.kyverno.enabled` + `plugin.trivy.enabled`, `ui.oauth.enabled: false`, fronted by `oauth2-proxy` with `github_users = ["stefanf81"]`, six Trivy `ui.sources`; `dependsOn: [infra-controllers, taskflow-app, trivy-operator]`). Its `HTTPRoute` serves `https://kyverno.jokelab.dev` via `policy-reporter-ui-oauth2-proxy:80` on the shared Cilium Gateway, using the `taskflow-jokelab-cert` certificate. Ensure the hostname has a public DNS record before certificate issuance or renewal.

**Add a policy:** add a `ValidatingPolicy` YAML (start with `validationActions: [Audit]`) to `gitops/apps/kyverno-policies/` and its `kustomization.yaml`, check it with `kubectl apply --dry-run=server -k gitops/apps/kyverno-policies`, and commit — Flux applies it automatically.

**Go to Deny (carefully):** once its background-scan results are all `pass`, flip `validationActions: [Audit]` → `[Deny]` in one policy at a time. See `docs/KYVERNO_POLICY_ENGINE.md` §8.

**Verify:**
```bash
flux get kustomizations | grep -E 'infra-controllers|kyverno'
flux get hr -n kyverno
flux get hr -n policy-reporter
kubectl -n kyverno get pods
kubectl get validatingpolicies
kubectl get policyreports -A
```

> **Security note:** the Policy Reporter UI's built-in OAuth is disabled (`ui.oauth.enabled: false` because it lacks a user allow-list); authentication is enforced by **`oauth2-proxy`** (`oauth2-proxy-release.yaml`, credentials in SOPS-encrypted `policy-reporter-ui-oauth-secrets.yaml`, host-only `__Host-o2p-kyverno` cookie), backed by pod-network default-deny (`oauth2-proxy-network-policy.yaml`). CoreDNS already carries the hairpin-NAT `hosts` override for `kyverno.jokelab.dev` (`controllers/coredns/release.yaml`).

See `docs/KYVERNO_POLICY_ENGINE.md` for the full reference (CRD gotchas, troubleshooting, rollback).
