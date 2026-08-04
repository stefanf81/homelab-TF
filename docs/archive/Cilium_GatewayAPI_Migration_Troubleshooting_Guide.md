# Cilium CNI & Kubernetes Gateway API Migration and Troubleshooting Guide

This guide compiles the complete technical logs, structural adjustments, and troubleshooting steps executed on **July 9, 2026**, during the migration of the TaskFlow Homelab cluster from legacy networking (Flannel + open NodePorts) to a modern, high-performance, kernel-level **Cilium (eBPF) CNI & Kubernetes Gateway API** architecture.

> **Status update:** Following this migration, external IP allocation was moved off **MetalLB** to **native Cilium L2 announcements** (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` under `gitops/infrastructure/configs/cilium/`). The MetalLB references below reflect the intermediate state *during* the July 9 migration and are now superseded by Cilium L2 announcements. Additionally, the `/jaeger` Gateway route mentioned in §D below was **subsequently removed** for security (Jaeger UI has no auth) — see [`ISSUES.md`](../ISSUES.md) #2 and `gitops/apps/taskflow/httproute.yaml`.

---

## 1. Migration Architecture: Before vs. After

| Feature | Legacy State | Modern Optimized State |
| :--- | :--- | :--- |
| **CNI (Network Engine)** | Flannel (Standard iptables encapsulation) | **Cilium v1.20.0 (eBPF-native routing)** |
| **Routing Layer** | Open `type: NodePort` on host nodes | **Kubernetes Gateway API (eBPF Envoy Proxy)** |
| **Ports Exposed** | `30042` (Frontend), `30080` (Backend), `31686` (Jaeger) | **Port 80 (Consolidated Path-Based Routing)** |
| **Routing Target** | Direct node endpoints | Secure internal **`type: ClusterIP`** services |
| **Default Hostname** | Host Node IP Address only | **`jokelab.dev`** & **Wildcard IP routing** |
| **Secrets Security** | Checked-in raw YAML files | **SOPS Integration Ready** (with age configuration) |
| **PostgreSQL persistency** | `1Gi` standard storage | **`10Gi` high-availability (Proxmox CSI-backed)** |
| **Database configuration**| Default Alpine parameters (128MB RAM budget) | **Tuned Engine Parameters (for 1024Mi RAM container limit)** |

---

## 2. Complete Summary of Changes (File by File)

### A. Infrastructure & VM Provisioning (OpenTofu)
* **`modules/proxmox/main.tf`**:
  * Cleaned up the formatting of the `#cloud-config` user-data snippet, left-aligning it to column `0` to prevent any parser/whitespace failures.
  * Appended `--flannel-backend=none` and `--disable-network-policy` to the K3s server installer commands.
  * Exported the dynamic Proxmox VM ID as a new output `k3s_node_id`.
* **`modules/k3s-kubeconfig/main.tf` & `modules/k3s-kubeconfig/variables.tf`**:
  * Added `vm_recreate_id` as an input variable and linked it to the `null_resource.fetch_kubeconfig` triggers block. This guarantees that rebuilding the VM automatically triggers OpenTofu to wait and fetch a fresh, updated `kubeconfig.yaml` to your Mac.
* **`main.tf`**:
  * Wired the `k3s_node_id` output directly from `module.proxmox` to `module.k3s_kubeconfig` as `vm_recreate_id`.

### B. GitOps Platform Controllers (`gitops/infrastructure/controllers/`)
* **`gateway-api/` (New Folder)**:
  * **`standard-install.yaml`**: Local-vendored copy of the official Kubernetes Gateway API `v1.2.1` standard installation release asset.
  * **`tlsroute-crd.yaml`**: Local-vendored copy of the Gateway API `v1.2.1` experimental `TLSRoute` Custom Resource Definition (essential for Cilium Gateway initialization).
  * **`kustomization.yaml`**: Created to group and apply the local-vendored assets.
* **`cilium/` (New Folder)**:
  * Created `namespace.yaml` (`kube-system`), `repository.yaml` (`https://helm.cilium.io/`), and `release.yaml` declaring a HelmRelease for Cilium `v1.19.5` with native CNI, IPAM (`mode: kubernetes`), `kubeProxyReplacement: true` (eBPF proxy bypass), and **`gatewayAPI.enabled = true`**.
* **`kustomization.yaml`**:
  * Wired `gateway-api` and `cilium` to the top of the Kustomize controller deployment list so networking boots before cert-manager and Proxmox CSI.

### C. GitOps Platform Configs (`gitops/infrastructure/configs/`)
* **`gatewayclass.yaml` (New File)**:
  * Natively registered the cluster-scoped **`cilium` GatewayClass** to bind incoming gateway manifests to Cilium's background controller (`io.cilium/gateway-controller`).
* **`kustomization.yaml`**:
  * Registered `gatewayclass.yaml` into the platform configs loop.
* **`cilium/ippool.yaml`**:
  * Aligned the Cilium IP pool allocation block directly with your physical homelab subnet: **`192.168.50.200 - 192.168.50.250`**.

### D. TaskFlow Application Layout (`gitops/apps/taskflow/`)
* **`gateway.yaml` (New File)**:
  * Deployed a standard Gateway API `Gateway` resource listening on port `80` using protocol `HTTP` and binding to the `cilium` class.
* **`httproute.yaml` (New File)**:
  * Deployed HTTPRoute specifications allowing wildcard access. It maps incoming physical traffic on port 80 based on path patterns:
    * `/` $\rightarrow$ routes to **Angular Frontend** service.
    * `/api` $\rightarrow$ routes to **Spring Boot Backend API** service.
    * `/jaeger` $\rightarrow$ routes to **Jaeger Telemetry UI** service.
* **`backend.yaml` / `frontend.yaml` / `jaeger.yaml`**:
  * Converted all Service resources from insecure `NodePort` mapping to fully protected **`ClusterIP`** structures.
* **`postgres-pvc.yaml`**:
  * Scaled storage request limits from `1Gi` to **`10Gi`** and explicitly specified `storageClassName: proxmox-csi`.
* **`postgres-db.yaml`**:
  * Injected custom container startup arguments to align PostgreSQL memory and planner operations with its 1024Mi container limit (e.g. `shared_buffers = 384MB`, `effective_cache_size = 700MB`, `work_mem = 8MB`, `maintenance_work_mem = 64MB`, `max_connections = 50`).
* **`kustomization.yaml`**:
  * Registered `gateway.yaml` and `httproute.yaml` into the application lifecycle.

### E. Security hardening
* **`.sops.yaml` (New File at Root)**:
  * Configured encryption rules mapping any `*-secrets.yaml` file to facilitate encrypted GitOps pipelines with `age` encryption.

---

## 3. Comprehensive Troubleshooting Log & Resolutions

Throughout the bootstrap and CNI-swap process, several classic, complex Kubernetes network-layer and dependency challenges were encountered and successfully resolved:

### Issue 1: Cilium Agent Crashloop (`address already in use` on VXLAN)
* **Symptom:** The `cilium-agent` pod continuously failed to start with a fatal error:
  `failed to setup vxlan tunnel device: setting up vxlan device: creating vxlan device: setting up device cilium_vxlan: address already in use`
  The agent logs listed active node devices as: `devices="[eth0 flannel.1]"`.
* **Root Cause:** In OpenTofu/Proxmox, updating a virtual machine's `user_data_file_id` updates the metadata template but does **not** force-recreate or reboot the running guest node. Consequently, the node was still running the older K3s setup where the default **Flannel** CNI was active and holding the system VXLAN network port.
* **Resolution:** Tainted/Destroyed the VM and triggered a clean OpenTofu build (`make destroy && make apply`). This forced K3s to initialize on a clean network stack with `--flannel-backend=none` from second one.

### Issue 2: The CNI Chicken-and-Egg Bootstrap Deadlock
* **Symptom:** On the newly rebuilt VM, the node remained in a **`NotReady`** state indefinitely. Attempting to bootstrap Flux CD resulted in all controller pods hanging in `ContainerCreating` with `cni plugin not initialized` warnings.
* **Root Cause:** Because Flannel was disabled, there was no CNI running on the fresh node. However, Flux CD cannot deploy Cilium if Flux's own pods cannot be scheduled, and Flux's pods cannot be scheduled because there is no active CNI.
* **Resolution:** Workstation-initiated bootstrapping. Broke the loop by manually running a direct Helm install command from the local Mac workstation:
  ```bash
  helm repo add cilium https://helm.cilium.io/
  helm install cilium cilium/cilium --namespace kube-system --set ipam.mode=kubernetes --set kubeProxyReplacement=true --set operator.replicas=1 --set gatewayAPI.enabled=true
  ```
  This immediately initialized host networking, flipped the node to **`Ready`**, and allowed Flux CD to bootstrap cleanly, which subsequently adopted the Helm installation.

### Issue 3: Cilium Operator Crashloop (`TLSRoute` missing in v1alpha2)
* **Symptom:** The `cilium-operator` crashed repeatedly with the fatal log:
  `failed to create gateway controller: failed to setup reconciler: no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"`
* **Root Cause:** Cilium Operator's internal Gateway API controller compiles reconciliation loops for the full Gateway API spec (including advanced/experimental specs like `TLSRoute` and `GRPCRoute`). Because we initially deployed Gateway API CRDs from the **standard** channel, `TLSRoute` was unregistered in the API server, causing a thread initialization crash.
* **Resolution:** Switched our remote GitOps CRD URL source from the standard channel to the **experimental channel** of the Gateway API repository.

### Issue 4: Gateway API CRD Schema Conflict (`v1` Storage Version Mismatch)
* **Symptom:** Flux Kustomization dry-run validation failed with the error:
  `CustomResourceDefinition.apiextensions.k8s.io "backendtlspolicies.gateway.networking.k8s.io" is invalid: status.storedVersions[0]: Invalid value: "v1": missing from spec.versions`
* **Root Cause:** Your highly modern **K3s v1.36.2** node has newer Gateway API CRDs pre-packaged. In Gateway API v1.2+, some experimental resources were modified and etcd saved a `v1` storage schema. When Flux attempted to dry-run apply `v1.1.0` CRDs (where `BackendTLSPolicy` is versioned `v1alpha3`), the API server rejected it because Kubernetes forbids schema downgrades that omit a stored schema version history.
* **Resolution (GitOps Local Vendoring):** 
  1. Purged the old cached version records inside the cluster:
     ```bash
     kubectl delete crd backendtlspolicies.gateway.networking.k8s.io tlsroutes.gateway.networking.k8s.io
     ```
  2. Adopted **"Local Vendoring"** in GitOps. Downloaded the exact SIG-upstream compiled `v1.2.1` `standard-install.yaml` and separate `tlsroute-crd.yaml` experimental manifest, saving them inside `gitops/infrastructure/controllers/gateway-api/` to match K3s's schema constraints perfectly.

### Issue 5: Flux Discovery Cache Invalidation Delay
* **Symptom:** Even after successfully applying the `v1.2.1` schemas, `flux get kustomizations` still reported validation errors:
  `dry-run failed: no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"`
* **Root Cause:** Flux's running `kustomize-controller` pod caches API schemas to optimize dry-run speeds. When CRDs are updated on-the-fly, the controller continues to evaluate using its stale in-memory discovery cache.
* **Resolution:** Triggered a rolling restart of the Flux deployment to clear its cache:
  ```bash
  kubectl rollout restart deployment kustomize-controller -n flux-system
  kubectl rollout status deployment kustomize-controller -n flux-system
  flux reconcile kustomization taskflow-app
  ```

### Issue 6: Network Gateway Timeouts (`ERR_CONNECTION_TIMED_OUT`)
* **Symptom:** Navigating to `http://192.168.1.201` resulted in a connection timeout.
* **Root Cause:** The cluster IP lease for the gateway load balancer was assigned from the old default placeholder subnet pool (`192.168.1.x`) before Flux synced the updated range. Because your physical homelab workstation router is on the `192.168.50.x` subnet, the workstation had no routing path to `192.168.1.x`, leading to connection drops.
* **Resolution:** Since Kubernetes and Cilium never forcibly tear down active network leases, we released the old lease by forcing a recreation of the GatewayClass and Service configurations:
  ```bash
  flux reconcile source git flux-system
  flux reconcile kustomization infra-configs
  ```
  This triggered Cilium to assign a fresh IP from the correct pool (**`192.168.50.201`**), making the entire application natively routable inside your local network!
