# Pod Spec Review — 25 October 2026

Review of every pod-bearing manifest against the features Kubernetes added up to
v1.37 (the node runs k3s `v1.37.1+k3s1`) and against `onedr0p/home-ops` and
`bjw-s-labs/home-ops` at their HEAD on 2026-10-25. Companion to
`CLUSTER_AUDIT_2026-10.md`, which covers the platform level.

## 1. What changed

| Change | Where | Why |
|---|---|---|
| `hostUsers: false` (user namespaces) | backend, frontend, both WAFs, Redis, Jaeger, both exporters, cloudflare-ddns, abuseipdb-sync, Reloader | Container UIDs map to an unprivileged per-pod host range; a container escape lands as nobody. Both reference repos use it. |
| `lifecycle.preStop.sleep` | backend (10s), frontend and WAFs (5s) | The endpoint is withdrawn from Cilium/Envoy before the process starts shutting down, so rollouts stop dropping in-flight requests. Backend: 10s + Spring's 30s graceful phase fits the 45s grace period. |
| `resizePolicy` | backend | In-place resize (GA 1.35): CPU without restart; memory restarts the container because the JVM sizes its heap at start. |
| `startupProbe` | both WAFs | CRS load no longer counts against liveness. |
| `readOnlyRootFilesystem: true` | Postgres (+ emptyDirs for `/var/run/postgresql`, `/tmp`), Redis | The last two TaskFlow containers with a writable root. |
| `enableServiceLinks: false` | all TaskFlow pods, abuseipdb-sync | No `DB_PORT`/`REDIS_PORT`/`JAEGER_*` variables injected for every Service. Checked against the backend's properties: nothing reads them. |
| `revisionHistoryLimit: 3` | all TaskFlow Deployments | Image automation rolls often; the default keeps 10 ReplicaSets. |
| Tag + digest pins | init container `alpine`, Postgres, Redis, Jaeger, both exporters, cloudflare-ddns | Same immutability the custom images already have; Renovate updates tag and digest together. |
| Removed `SPRING_REDIS_PASSWORD` | backend | Spring Boot 4 reads only `spring.data.redis.*`; the backend repo has no other reference. |
| Pod Security Admission `restricted` (enforce + warn) | namespaces `taskflow`, `abuseipdb`, `reloader` | Admission by the API server itself, no webhook. All pods were checked against the restricted profile before enabling. |
| Reloader (`stakater/reloader` chart 2.2.18) | `gitops/infrastructure/controllers/reloader`, cluster Kustomization `reloader` | WAFs roll when their ConfigMap changes (no more manual restart); backend, Redis, exporters, cloudflare-ddns and abuseipdb-sync roll on ConfigMap/Secret changes. Scoped mode: namespaced Roles in `taskflow` and `abuseipdb` only, no ClusterRole. Postgres is excluded on purpose (its password only applies at initdb). |
| OCI chart sources (`OCIRepository` + `chartRef`) | cert-manager, Cilium, CoreDNS, Falco, Kyverno, Policy Reporter, both oauth2-proxies, polr adapter, Proxmox CSI, renovate-operator, Reloader | No multi-MB `index.yaml` downloads per repository; what the reference repos use for almost every chart. The version now lives in the `OCIRepository` `ref.tag`. |
| `--disable-kube-proxy` + `cloud-init.disabled` | `modules/proxmox/main.tf` (new nodes) | Cilium already replaces kube-proxy. The VM ignores `user_data_file_id` changes, so this edit never replaces the node. |

## 2. Manual steps on the running node

Terraform only affects new nodes. Before the next `tofu apply`, and in this order:

```bash
# 1. never let cloud-init re-run the installer (REMEDIATION_PLAN REL-00)
sudo touch /etc/cloud/cloud-init.disabled

# 2. confirm the runtime supports user namespaces (containerd 2.x, kernel >= 6.3)
uname -r; sudo k3s ctr version | grep -A1 Server

# 3. disable kube-proxy (REMEDIATION_PLAN PERF-01, ~30s API restart)
echo 'disable-kube-proxy: true' | sudo tee -a /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
sudo sh -c 'iptables-save | grep -v KUBE | iptables-restore'
```

`REL-00` notes that flags on the k3s command line override `config.yaml` for
repeatable flags; `disable-kube-proxy` is a plain boolean and is not affected.

## 3. Verification after Flux reconciles

```bash
flux get sources oci -A                      # every OCIRepository Ready
flux get helmreleases -A                     # every release upgraded and Ready
kubectl -n taskflow get pods -o custom-columns=NAME:.metadata.name,USERNS:.spec.hostUsers
kubectl -n taskflow exec deploy/redis -- cat /proc/self/uid_map   # not "0 0 4294967295"
kubectl -n reloader logs deploy/reloader | head
kubectl label --dry-run=server --overwrite ns taskflow pod-security.kubernetes.io/enforce=restricted
```

Rollback for user namespaces is per Deployment: delete the `hostUsers: false` line.

## 4. Deliberately not done

| Item | Reason |
|---|---|
| `hostUsers: false` on Postgres | The PGDATA volume is owned by host UID 70; in a user namespace it needs an idmapped mount of the proxmox-csi ext4 volume. Test it on a copy first. |
| CloudNativePG | Needs a backup target (bucket + credentials) and a cutover window; plan in `REMEDIATION_PLAN_2026-10.md` REL-02. |
| OCI for VictoriaMetrics, Loki, Alloy, metrics-server, trivy-operator | Alloy and metrics-server have no official OCI chart; trivy-operator's OCI copy stops at 0.32.1. The VM stack and Loki are read through their HTTP index by `validate-monitoring-configs.rb` and `validate-loki-version.rb` in CI; move them together with those scripts. |
| Cilium `routingMode: native`, `preallocateMaps` | No effect on one node and a live change disrupts pod networking (`PERF_DEEP_DIVE_2026-10.md` §4); set before a second node joins. |
| Exporters as native sidecars | Would change the `job`/`pod` labels the dashboards query, for little gain. |
| One shared WAF base (Kustomize component) | The CI suites and the image-bump workflow read each `*-waf.yaml` as a self-contained ConfigMap + Deployment. |
