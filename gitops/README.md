# GitOps Layout

This directory contains the Git repository tree reconciled by Flux. The current
bootstrap manifest points at `https://github.com/stefanf81/homelab-TF.git`; see
`./FLUX_BOOTSTRAP.md` for bootstrap and recovery procedures. Flux itself is
being moved under the Flux Operator (`infrastructure/flux-instance/`); until
that takeover is verified, `clusters/taskflow/flux-system/` remains the
bootstrap source. OpenTofu does not bootstrap Flux.

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
│   ├── app/                    #   App scrapes + Grafana dashboards (TaskFlow Performance, AbuseIPDB Security, Blocked Sources, cert-manager, Kyverno)
│   └── logging/                #   Loki, Alloy (WAF logs + derived WAF metrics, abuseipdb-sync logs, Hubble flow export) + WAF, Access Logs, Rate Limits, Falco, Trivy, Logging pipeline dashboards
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
Contains the system controllers deployed primarily via **HelmReleases**. 
* **`cilium/`**: Installs Cilium with native L2 announcements (`CiliumLoadBalancerIPPool`) to manage external LoadBalancer IPs.
* **`proxmox-csi/`**: Installs the Proxmox CSI driver to dynamically provision high-performance virtual disk storage on your Proxmox VE hypervisor for persistent volumes (PVCs).
* **`cert-manager/`**: Handles automated provisioning of TLS certificates.
* **`kyverno/`**: Installs the Kyverno policy engine (admission + background/cleanup/reports controllers). Validates, mutates, and generates Kubernetes resources via CEL `ValidatingPolicy` CRs (`policies.kyverno.io/v1`; `ClusterPolicy` is removed in Kyverno 1.20). CRDs are owned by the chart (`crds.install: true`); the Flux `HelmRelease` uses `install.crds: Skip` to avoid a CRD ownership conflict. Reconciled by `infra-controllers`.
* **`policy-reporter/`**: Installs Policy Reporter + its UI subchart — a read-only web dashboard for Kyverno, Trivy, and Falco `PolicyReport` / `ClusterPolicyReport` objects. Exposed at `https://kyverno.jokelab.dev` through the Cilium Gateway (same pattern as Grafana), protected by **GitHub OAuth**. Trivy findings are surfaced via the `trivy-operator-polr-adapter` (Trivy CRDs → PolicyReports) plus the `plugin.trivy` enrichment. Has its **own** cluster Kustomization (`policy-reporter`) that `dependsOn` both `infra-controllers` and `taskflow-app` so the Gateway exists before the HTTPRoute is programmed.
* **`falco/`**: Installs Falco runtime security as a DaemonSet with modern eBPF driver. Uses Falcosidekick to write native Kubernetes `PolicyReport` CRDs visible in the Policy Reporter UI. Exposes Prometheus metrics on port 8765 for VictoriaMetrics scraping.
* **`trivy-operator/`**: Installs the Trivy vulnerability scanner operator. Scans container images for CVEs, runs the **config-audit** (misconfiguration), **RBAC**, **infra-assessment**, and **exposed-secret** scanners, and executes **cluster compliance** reports (NSA, CIS, PSS) on a schedule. SBOM generation is disabled in the current configuration. Results produce `VulnerabilityReport`/`ConfigAuditReport`/… CRDs consumed by the Policy Reporter (see `docs/TRIVY_SECURITY_SCANNING.md`). Has its **own** cluster Kustomization (`trivy-operator`) that `dependsOn` `infra-controllers`.
* **`abuseipdb/`**: Runs the **AbuseIPDB synchronizer** — it downloads the AbuseIPDB blacklist, validates/normalizes it, and maintains two runtime-managed enforcement sinks: `CiliumCIDRGroup/abuseipdb` (used by the `CiliumClusterwideNetworkPolicy` that denies listed sources on the direct path) and a Cloudflare account IP list referenced by a zone WAF custom rule (the enforcement point that sees real client IPs behind the proxy). It also collects Cloudflare Security Events for the `Blocked Sources` dashboard. Has its **own** cluster Kustomization (`abuseipdb`) that `dependsOn` `infra-controllers`. See `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`.

#### B. `infrastructure/configs/` (Controller Instances)
Contains the actual custom configurations and Custom Resources (CRs) consumed by the controllers installed in the folder above.
* **`cilium/ippool.yaml`**: Configures the IP pool block for LoadBalancer services via `CiliumLoadBalancerIPPool`. *Optimized:* Adjusted to map your homelab subnet (`192.168.50.200 - 192.168.50.250`).
* **`cilium/l2announcement-policy.yaml`**: Advertises the allocated IP ranges locally via Layer 2 (ARP) using `CiliumL2AnnouncementPolicy`.
* **`cilium/abuseipdb-ingress-deny.yaml`**: `CiliumClusterwideNetworkPolicy` that denies sources from `CiliumCIDRGroup/abuseipdb` at the `reserved:ingress` (Cilium Gateway) hop, for direct-to-origin traffic. The referenced CIDR group is maintained at runtime by `abuseipdb-sync` and is deliberately not committed to Git.

### 3. `apps/` (The Application Layer)
This layer houses user-facing workloads and microservices. Workloads here are kept separate from the infrastructure layer to allow application developers to deploy code without risking platform-level system configuration.

#### `apps/taskflow/`
This folder represents your **TaskFlow** application (Angular 22, Spring Boot 4.1.1, PostgreSQL 18, Redis 8.10, and Jaeger).
* **`backend.yaml`**: Configures the JVM Spring Boot 4.1.1 server with preflight checks (`wait-for-db` init-container) and a 1 GiB heap (`MaxRAMPercentage=50.0` of its 2 GiB cgroup limit) with G1GC tuning (`JAVA_TOOL_OPTIONS`). The deployment owns the JVM sizing flags. The container image uses the mutable `:latest` tag, which Flux pins to its current `sha256` digest via the `# {"$imagepolicy": ...}` marker (see `../FLUX_BOOTSTRAP.md` §7 — the Git source must be writable and the marker must be the *basic* form, not `:digest`).
* **`backend-waf.yaml` / `frontend-waf.yaml`**: Put Caddy + Coraza CRS in front of the backend and frontend Services. The Gateway routes only to these WAF Services.
* **`frontend.yaml`**: Configures the Angular 22 client packaged with Nginx, utilizing custom emptyDirs to secure a `readOnlyRootFilesystem`. Same Flux digest-pin behavior as the backend.
* **`postgres-db.yaml` & `postgres-pvc.yaml`**: Configures the database storage. *Optimized:* Postgres now runs tuned caching params (`shared_buffers=128MB`, `effective_cache_size=256MB`, `work_mem=8MB`, `max_connections=50`) within its 512Mi RAM limit, and storage is scaled to `10Gi` backed by the dynamic `proxmox-csi` storage engine.
* **`redis.yaml`**: Configures the caching layer. *Optimized:* capped at `--maxmemory 64mb` with `allkeys-lru` eviction to avoid OOM-kill cache loss (ephemeral `emptyDir`, no persistence).
* **`jaeger.yaml`**: Configures Jaeger All-in-One telemetry for OTLP trace collection.
*   **`network-policy.yaml`**: Enforces strict network-level isolation (e.g., restricting PostgreSQL & Redis ingress ports to the backend container).
*   **`default-deny.yaml`**: Default-deny ingress for the data tier (postgres, redis, jaeger) — flips the allow-by-default baseline so `restrict-*` policies actually enforce.
*   **`namespace-default-deny.yaml`**: Extends default-deny to the **entire** `taskflow` namespace, then selectively re-opens the Cilium Gateway (Envoy) and monitoring scrapes. Implements full zero-trust networking.
*   **`backend-pdb.yaml`** & **`frontend-pdb.yaml`**: PodDisruptionBudgets (`minAvailable: 1`) blocking voluntary evictions for single-replica workloads.
*   **`certificate.yaml`**: Let's Encrypt TLS certificate for `jokelab.dev`, `www.jokelab.dev`, `grafana.jokelab.dev`, and `kyverno.jokelab.dev`.
*   **`http-redirect.yaml`**: HTTP→HTTPS 301 redirect (port 80 → 443) and bare apex `jokelab.dev` → `www.jokelab.dev` redirect.
*   **`cloudflare-ddns.yaml`**: Cloudflare DDNS updater keeping the TaskFlow, Grafana, Policy Reporter, and Hubble host records synced to the public endpoint.
*   **`kustomization.yaml`**: Aggregates all these resources into a single manifest compilation unit for Flux.

## Pre-baked Optimizations inside GitOps

The scaffolded manifests inside this layout include critical performance and networking adjustments:

### 1. Database & Storage Scaling (`apps/taskflow/`)
* **Proxmox CSI Storage Association:** `postgres-pvc.yaml` is configured with `storageClassName: proxmox-csi` and scaled to `10Gi` of high-performance virtual disk storage, mapped directly to VM 900 via the node's `instance-id` annotation.
* **PostgreSQL Engine Tuning:** `postgres-db.yaml` utilizes container launch variables to tune buffers, cache sizes, and connection limits within its 512Mi RAM limit (e.g. `shared_buffers=128MB`, `effective_cache_size=256MB`, `work_mem=8MB`, `max_connections=50`).

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
* **Dashboard** — `gitops/platform/policy-reporter/` (HelmRelease `policy-reporter` v3.11.2, `ui.enabled`, `plugin.kyverno.enabled` + `plugin.trivy.enabled`, GitHub OAuth, six Trivy `ui.sources`). Its `HTTPRoute` serves `https://kyverno.jokelab.dev` via the shared Cilium Gateway, using the `taskflow-jokelab-cert` certificate, whose `dnsNames` already include `kyverno.jokelab.dev`. Ensure the hostname has a public DNS record before certificate issuance or renewal.

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

> **Security note:** the Policy Reporter UI is protected by **GitHub OAuth** (`ui.oauth`), with the OAuth app credentials in the SOPS-encrypted `policy-reporter-github-oauth` secret. If you later remove OAuth, consider `ui.basicAuth` (SOPS-encrypted secret) to avoid exposing policy reports publicly. Also, the Let's Encrypt certificate requires a DNS record for `kyverno.jokelab.dev` resolving to the Gateway IP — without it the cert stays `Pending`. If the record exists but cert-manager's self-check still times out (hairpin NAT behind a router), add a `hosts` entry in CoreDNS to resolve the domain to the Gateway's internal IP `192.168.50.201` — see `docs/KYVERNO_POLICY_ENGINE.md` §6 for the exact patch.

See `docs/KYVERNO_POLICY_ENGINE.md` for the full reference (CRD gotchas, troubleshooting, rollback).

## Next step later

1. Create a remote repository.
2. Push this `gitops/` directory into it.
3. Follow `./FLUX_BOOTSTRAP.md`.
4. Bootstrap Flux manually per `./FLUX_BOOTSTRAP.md` (OpenTofu does not bootstrap Flux).
