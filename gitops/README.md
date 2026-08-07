# GitOps Layout

This directory is intended to become the future Git repository that Flux will reconcile from.

Right now it only exists locally. Once you create a remote Git repository (for example on GitHub), you can copy or push this directory there and then bootstrap Flux against it manually (see `./FLUX_BOOTSTRAP.md`). Note: the Terraform `modules/flux-bootstrap` module is **planned but not yet created**.

## Directory Structure & Architecture

```text
gitops/
├── clusters/                   # 1. Cluster entrypoints (The Bootstrap Target)
│   └── taskflow/
├── infrastructure/             # 2. Platform/System services (Helm charts & System configs)
│   ├── controllers/
│   │   ├── kyverno/            #   Kyverno policy engine (HelmRelease; reconciled by infra-controllers)
│   │   ├── policy-reporter/    #   Policy Reporter + UI (own Kustomization; dashboard at kyverno.jokelab.dev)
│   │   ├── falco/              #   Falco runtime security (modern eBPF, PolicyReport integration)
│   │   └── trivy-operator/     #   Trivy vulnerability scanner (own Kustomization; dependsOn infra-controllers)
│   └── configs/
├── apps/                       # 3. User-facing applications (TaskFlow frontend, backend, database)
│   ├── taskflow/
│   └── kyverno-policies/       #   Example ClusterPolicies (Audit mode); reconciled by kyverno-policies Kustomization
├── README.md                   # GitOps directory overview
└── FLUX_BOOTSTRAP.md    # Instructions for remote Git & Flux CD integration
```

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
* **`kyverno/`**: Installs the Kyverno policy engine (admission + background/cleanup/reports controllers). Validates, mutates, and generates Kubernetes resources via `ClusterPolicy` CRs. CRDs are owned by the chart (`crds.install: true`); the Flux `HelmRelease` uses `install.crds: Skip` to avoid a CRD ownership conflict. Reconciled by `infra-controllers`.
* **`policy-reporter/`**: Installs Policy Reporter + its UI subchart — a read-only web dashboard for Kyverno, Trivy, and Falco `PolicyReport` / `ClusterPolicyReport` objects. Exposed at `https://kyverno.jokelab.dev` through the Cilium Gateway (same pattern as Grafana), protected by **GitHub OAuth**. Trivy findings are surfaced via the `trivy-operator-polr-adapter` (Trivy CRDs → PolicyReports) plus the `plugin.trivy` enrichment. Has its **own** cluster Kustomization (`policy-reporter`) that `dependsOn` both `infra-controllers` and `taskflow-app` so the Gateway exists before the HTTPRoute is programmed.
* **`falco/`**: Installs Falco runtime security as a DaemonSet with modern eBPF driver. Uses Falcosidekick to write native Kubernetes `PolicyReport` CRDs visible in the Policy Reporter UI. Exposes Prometheus metrics on port 8765 for VictoriaMetrics scraping.
* **`trivy-operator/`**: Installs the Trivy vulnerability scanner operator. Scans container images for CVEs, runs the **config-audit** (misconfiguration), **RBAC**, **infra-assessment**, and **exposed-secret** scanners, generates **SBOMs**, and executes **cluster compliance** reports (NSA, CIS, PSS) on a schedule — all producing `VulnerabilityReport`/`ConfigAuditReport`/… CRDs consumed by the Policy Reporter (see `docs/TRIVY_SECURITY_SCANNING.md`). Has its **own** cluster Kustomization (`trivy-operator`) that `dependsOn` `infra-controllers`.

#### B. `infrastructure/configs/` (Controller Instances)
Contains the actual custom configurations and Custom Resources (CRs) consumed by the controllers installed in the folder above.
* **`cilium/ippool.yaml`**: Configures the IP pool block for LoadBalancer services via `CiliumLoadBalancerIPPool`. *Optimized:* Adjusted to map your homelab subnet (`192.168.50.200 - 192.168.50.250`).
* **`cilium/l2announcement-policy.yaml`**: Advertises the allocated IP ranges locally via Layer 2 (ARP) using `CiliumL2AnnouncementPolicy`.

### 3. `apps/` (The Application Layer)
This layer houses user-facing workloads and microservices. Workloads here are kept separate from the infrastructure layer to allow application developers to deploy code without risking platform-level system configuration.

#### `apps/taskflow/`
This folder represents your **TaskFlow** application (Angular 22, Spring Boot 3.5.3, PostgreSQL 18, Redis 8.10, and Jaeger).
* **`backend.yaml`**: Configures the JVM Spring Boot 3.5.3 server with preflight checks (`wait-for-db` init-container) and a 1 GiB heap (`MaxRAMPercentage=50.0` of its 2 GiB cgroup limit) with G1GC tuning (`JAVA_TOOL_OPTIONS`). The container image uses the mutable `:latest` tag, which Flux pins to its current `sha256` digest via the `# {"$imagepolicy": ...}` marker (see `../FLUX_BOOTSTRAP.md` §7 — the Git source must be writable and the marker must be the *basic* form, not `:digest`).
* **`frontend.yaml`**: Configures the Angular 22 client packaged with Nginx, utilizing custom emptyDirs to secure a `readOnlyRootFilesystem`. Same Flux digest-pin behavior as the backend.
* **`postgres-db.yaml` & `postgres-pvc.yaml`**: Configures the database storage. *Optimized:* Postgres now runs tuned caching params (`shared_buffers=384MB`, `effective_cache_size=700MB`, `work_mem=8MB`, `max_connections=50`) within its 1024Mi RAM limit, and storage is scaled to `10Gi` backed by the dynamic `proxmox-csi` storage engine.
* **`redis.yaml`**: Configures the caching layer. *Optimized:* capped at `--maxmemory 384mb` with `allkeys-lru` eviction to avoid OOM-kill cache loss (ephemeral `emptyDir`, no persistence).
* **`jaeger.yaml`**: Configures Jaeger All-in-One telemetry for OTLP trace collection.
*   **`network-policy.yaml`**: Enforces strict network-level isolation (e.g., restricting PostgreSQL & Redis ingress ports to the backend container).
*   **`default-deny.yaml`**: Default-deny ingress for the data tier (postgres, redis, jaeger) — flips the allow-by-default baseline so `restrict-*` policies actually enforce.
*   **`namespace-default-deny.yaml`**: Extends default-deny to the **entire** `taskflow` namespace, then selectively re-opens the Cilium Gateway (Envoy) and monitoring scrapes. Implements full zero-trust networking.
*   **`backend-hpa.yaml`**: HorizontalPodAutoscaler ready to activate (CPU 70%, 1–3 replicas); requires `metrics-server` for the `metrics.k8s.io` API.
*   **`backend-pdb.yaml`** & **`frontend-pdb.yaml`**: PodDisruptionBudgets (`minAvailable: 1`) blocking voluntary evictions for single-replica workloads.
*   **`certificate.yaml`**: Let's Encrypt TLS certificate for `jokelab.dev`, `www.jokelab.dev`, `grafana.jokelab.dev`, and `kyverno.jokelab.dev`.
*   **`http-redirect.yaml`**: HTTP→HTTPS 301 redirect (port 80 → 443) and bare apex `jokelab.dev` → `www.jokelab.dev` redirect.
*   **`cloudflare-ddns.yaml`**: Cloudflare DDNS updater keeping the TaskFlow, Grafana, and Policy Reporter host records synced to the public endpoint.
*   **`kustomization.yaml`**: Aggregates all these resources into a single manifest compilation unit for Flux.

## Pre-baked Optimizations inside GitOps

The scaffolded manifests inside this layout include critical performance and networking adjustments:

### 1. Database & Storage Scaling (`apps/taskflow/`)
* **Proxmox CSI Storage Association:** `postgres-pvc.yaml` is configured with `storageClassName: proxmox-csi` and scaled to `10Gi` of high-performance virtual disk storage, mapped directly to VM 900 via the node's `instance-id` annotation.
* **PostgreSQL Engine Tuning:** `postgres-db.yaml` utilizes container launch variables to tune buffers, cache sizes, and connection limits within its 1024Mi RAM limit (e.g. `shared_buffers=384MB`, `effective_cache_size=700MB`, `work_mem=8MB`, `max_connections=50`).

### 2. Modern Kubernetes Gateway API with Cilium (`apps/taskflow/`)
* **Cilium CNI & Gateway API Operator:** Deployed under `infrastructure/controllers/cilium/`. The core Gateway API schemas are fully managed under `infrastructure/controllers/gateway-api/` using a **local-vendored** copy of the official `v1.2.1` standard installation release. This ensures Flux CD performs dry-run validations with 100% compliance, preventing any schema version conflicts or ownership clashes with K3s's built-in platform installers.
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

### 4. Policy Engine & Dashboard (Kyverno + Policy Reporter)

Kyverno provides Kubernetes-native policy enforcement; Policy Reporter gives it a UI.

* **Controller** — `gitops/infrastructure/controllers/kyverno/` (HelmRelease `kyverno` v3.8.2, single-replica, CRDs owned by the chart). System namespaces (`kube-system`, `flux-system`, `kyverno`, `cert-manager`, `cilium`) are excluded from enforcement.
* **Policies** — `gitops/apps/kyverno-policies/` holds `ClusterPolicy` resources in **Audit** mode (no blocking yet). Reconciled by the `kyverno-policies` Kustomization, which `dependsOn: infra-controllers` so the CRDs exist before policies apply.
* **Dashboard** — `gitops/infrastructure/controllers/policy-reporter/` (HelmRelease `policy-reporter` v3.9.1, `ui.enabled`, `plugin.kyverno.enabled` + `plugin.trivy.enabled`, GitHub OAuth, six Trivy `ui.sources`). Its `HTTPRoute` serves `https://kyverno.jokelab.dev` via the shared Cilium Gateway, using the `taskflow-jokelab-cert` certificate, whose `dnsNames` already include `kyverno.jokelab.dev`. Ensure the hostname has a public DNS record before certificate issuance or renewal.

**Add a policy:** drop a `ClusterPolicy` YAML into `gitops/apps/kyverno-policies/` and commit — Flux applies it automatically.

**Go to Enforce (carefully):** flip `validationFailureAction: Audit` → `Enforce` in a policy, one at a time. Kyverno's webhook then blocks non-compliant admissions (system namespaces stay excluded).

**Verify:**
```bash
flux get kustomizations | grep -E 'infra-controllers|kyverno'
flux get hr -n kyverno
flux get hr -n policy-reporter
kubectl -n kyverno get pods
kubectl get clusterpolicy
kubectl get clusterpolicyreport -A
```

> **Security note:** the Policy Reporter UI is protected by **GitHub OAuth** (`ui.oauth`), with the OAuth app credentials in the SOPS-encrypted `policy-reporter-github-oauth` secret. If you later remove OAuth, consider `ui.basicAuth` (SOPS-encrypted secret) to avoid exposing policy reports publicly. Also, the Let's Encrypt certificate requires a DNS record for `kyverno.jokelab.dev` resolving to the Gateway IP — without it the cert stays `Pending`. If the record exists but cert-manager's self-check still times out (hairpin NAT behind a router), add a `hosts` entry in CoreDNS to resolve the domain to the Gateway's internal IP `192.168.50.201` — see `docs/KYVERNO_POLICY_ENGINE.md` §6 for the exact patch.

See `docs/KYVERNO_POLICY_ENGINE.md` for the full reference (CRD gotchas, troubleshooting, rollback).

## Next step later

1. Create a remote repository.
2. Push this `gitops/` directory into it.
3. Follow `./FLUX_BOOTSTRAP.md`.
4. Bootstrap Flux manually per `./FLUX_BOOTSTRAP.md` (the `modules/flux-bootstrap` Terraform module is planned but not yet created).
