# GitOps Layout

This directory is intended to become the future Git repository that Flux will reconcile from.

Right now it only exists locally. Once you create a remote Git repository (for example on GitHub), you can copy or push this directory there and then bootstrap Flux against it manually (see `./FUTURE_FLUX_BOOTSTRAP.md`). Note: the Terraform `modules/flux-bootstrap` module is **planned but not yet created**.

## Directory Structure & Architecture

```text
gitops/
├── clusters/                   # 1. Cluster entrypoints (The Bootstrap Target)
│   └── taskflow/
├── infrastructure/             # 2. Platform/System services (Helm charts & System configs)
│   ├── controllers/
│   └── configs/
├── apps/                       # 3. User-facing applications (TaskFlow frontend, backend, database)
│   └── taskflow/
├── README.md                   # GitOps directory overview
└── FUTURE_FLUX_BOOTSTRAP.md    # Instructions for remote Git & Flux CD integration
```

### 1. `clusters/` (The Entrypoint & Orchestration Layer)
This is where your Flux CD controllers start scanning. When you bootstrap Flux on your k3s node, you point it to a subfolder inside `clusters/` (e.g., `gitops/clusters/taskflow/`).

* **Role:** Orchestrates the deployment order using **Kustomization dependency graphs** (`dependsOn`). It ensures platform infrastructure is fully running before application code attempts to deploy.
* **How it works:**
  1. Flux reads `clusters/taskflow/infra-controllers.yaml` and deploys the operators (Cilium, Longhorn, cert-manager).
  2. Once those are healthy, Flux reads `clusters/taskflow/infra-configs.yaml` to deploy configurations (Cilium IP pools).
  3. Finally, Flux reads `clusters/taskflow/taskflow.yaml` to deploy your TaskFlow application, guaranteeing the database persistent volumes (Longhorn) and IP allocations (Cilium L2 announcements) are ready to consume.

### 2. `infrastructure/` (The Platform / Systems Layer)
This layer manages cluster-wide utilities and operators that provide auxiliary services (network, storage, TLS certs) to other workloads in the cluster. It is split into two logical subdirectories to prevent race conditions during deployment:

#### A. `infrastructure/controllers/` (CRD and Operator Deployments)
Contains the system controllers deployed primarily via **HelmReleases**. 
* **`cilium/`**: Installs Cilium with native L2 announcements (`CiliumLoadBalancerIPPool`) to manage external LoadBalancer IPs.
* **`longhorn/`**: Installs the distributed block storage system to handle persistent volumes (PVCs). Optimized to run on your single-node Homelab cluster by limiting volume replica checks (`defaultClassReplicaCount: 1`).
* **`cert-manager/`**: Handles automated provisioning of TLS certificates.

#### B. `infrastructure/configs/` (Controller Instances)
Contains the actual custom configurations and Custom Resources (CRs) consumed by the controllers installed in the folder above.
* **`cilium/ippool.yaml`**: Configures the IP pool block for LoadBalancer services via `CiliumLoadBalancerIPPool`. *Optimized:* Adjusted to map your homelab subnet (`192.168.50.200 - 192.168.50.250`).
* **`cilium/l2announcement-policy.yaml`**: Advertises the allocated IP ranges locally via Layer 2 (ARP) using `CiliumL2AnnouncementPolicy`.

### 3. `apps/` (The Application Layer)
This layer houses user-facing workloads and microservices. Workloads here are kept separate from the infrastructure layer to allow application developers to deploy code without risking platform-level system configuration.

#### `apps/taskflow/`
This folder represents your **TaskFlow** application (Angular 22, Spring Boot 3.5.3, PostgreSQL 17, Redis 7.2, and Jaeger).
* **`backend.yaml`**: Configures the JVM Spring Boot 3.5.3 server with preflight checks (`wait-for-db` init-container) and a fixed 1.5 GB heap with G1GC tuning (`JAVA_TOOL_OPTIONS`).
* **`frontend.yaml`**: Configures the Angular 22 client packaged with Nginx, utilizing custom emptyDirs to secure a `readOnlyRootFilesystem`.
* **`postgres-db.yaml` & `postgres-pvc.yaml`**: Configures the database storage. *Optimized:* Postgres now runs tuned caching params (`shared_buffers=256MB`, `work_mem=8MB`, `max_connections=30`) within its 1536Mi RAM limit, and storage is scaled to `10Gi` backed by the dynamic `longhorn` storage engine.
* **`redis.yaml`**: Configures the caching layer. *Optimized:* capped at `--maxmemory 384mb` with `allkeys-lru` eviction to avoid OOM-kill cache loss (ephemeral `emptyDir`, no persistence).
* **`jaeger.yaml`**: Configures Jaeger All-in-One telemetry for OTLP trace collection.
* **`network-policy.yaml`**: Enforces strict network-level isolation (e.g., restricting PostgreSQL & Redis ingress ports to the backend container).
* **`kustomization.yaml`**: Aggregates all these resources into a single manifest compilation unit for Flux.

## Pre-baked Optimizations inside GitOps

The scaffolded manifests inside this layout include critical performance and networking adjustments:

### 1. Database & Storage Scaling (`apps/taskflow/`)
* **Longhorn Storage Association:** `postgres-pvc.yaml` is configured with `storageClassName: longhorn` and scaled to `10Gi` of block-replicated storage to ensure database high availability.
* **PostgreSQL Engine Tuning:** `postgres-db.yaml` utilizes container launch variables to tune buffers, cache sizes, and connection limits within its 1536Mi RAM limit (e.g. `shared_buffers=256MB`, `effective_cache_size=768MB`, `work_mem=8MB`, `max_connections=30`).

### 2. Modern Kubernetes Gateway API with Cilium (`apps/taskflow/`)
* **Cilium CNI & Gateway API Operator:** Deployed under `infrastructure/controllers/cilium/`. The core Gateway API schemas are fully managed under `infrastructure/controllers/gateway-api/` using a **local-vendored** copy of the official `v1.2.1` standard installation release. This ensures Flux CD performs dry-run validations with 100% compliance, preventing any schema version conflicts or ownership clashes with K3s's built-in platform installers.
* **Unified Gateway Routing (`gateway.yaml` & `httproute.yaml`):** The TaskFlow app is securely routed using Cilium-native Gateway API rules. All traffic flows through the single hostname `taskflow.local` on standard port `80`:
  * `http://taskflow.local/` maps to the TaskFlow Angular Frontend
  * `http://taskflow.local/api` maps to the Spring Boot Backend API
  * `http://taskflow.local/jaeger` maps to the Jaeger UI Telemetry console
* **Secure ClusterIP Services:** The backend, frontend, and jaeger Services are configured as internal-only `type: ClusterIP` rather than open `NodePort` resources. All incoming physical traffic is safely parsed and authenticated by the Cilium Gateway controller first.

### 3. GitOps Secrets Workflow (`.sops.yaml` in Root)
* **SOPS Ready:** Matches your `*-secrets.yaml` files. To secure your credentials in Git, generate an age key and run:
  ```bash
  sops -e -i gitops/apps/taskflow/taskflow-secrets.yaml
  ```

## Next step later

1. Create a remote repository.
2. Push this `gitops/` directory into it.
3. Follow `./FUTURE_FLUX_BOOTSTRAP.md`.
4. Bootstrap Flux manually per `./FUTURE_FLUX_BOOTSTRAP.md` (the `modules/flux-bootstrap` Terraform module is planned but not yet created).
