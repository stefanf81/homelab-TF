# TaskFlow vs. State-of-the-Art Homelab Kubernetes (2026)

Gap analysis of this cluster against what leading homelab Kubernetes
clusters (the `home-operations` community and similar setups) do in 2026.

This is a **reference document only** — it records the comparison and the
rationale behind each SOTA practice. No action items are tracked here; see
`ARCHITECTURE.md` §9 for the current known-limitations list.

Status: informational snapshot, September 2026.

| Area | This cluster | 2026 SOTA | Why it matters |
|---|---|---|---|
| Node OS | Ubuntu 26.04 + cloud-init k3s | **Talos Linux** (immutable, no SSH/shell, Image Factory extensions, API-driven upgrades) — the mainstream of the home-operations community in 2026 | Eliminates config drift, package CVEs, snowflake nodes; upgrades become declarative |
| Topology | 1 node | **3-node HA** (Talos or k3s + embedded etcd), kube-vip/Cilium for the API VIP; control-plane taints | A single-node reboot is a full outage; HA turns it into a non-event |
| Upgrade automation | Manual chart bumps via Renovate | **system-upgrade-controller / `talosctl upgrade-k8s`**, staged K8s upgrades | K8s/OS patch cadence without downtime planning per-node |
| Storage & DR | proxmox-csi, `Retain`, no snapshots | **VolumeSnapshots + Velero/Volsync/k8up to S3/R2 + PBS**, periodic restore drills; Longhorn/Ceph only if multi-node | `Retain` is not a backup; a fat-fingered PVC delete is unrecoverable today |
| Database | Hand-rolled Postgres Deployment | **CloudNativePG operator** (WAL archiving → S3, PITR, replicas/failover when HA arrives) | PITR + tested restores instead of hoping |
| Secrets | SOPS in Git, single age key, no at-rest encryption | **ESO + OpenBao/Vault/Bitwarden/Infisical** (secrets never in Git) + rotation; SOPS only for bootstrap | Blast radius of one leaked age key = everything; no rotation story today |
| Admission policy | Kyverno `ClusterPolicy`, Audit, 2 rules | **Kyverno CEL `ValidatingPolicy`/`ImageValidatingPolicy`** (ClusterPolicy is deprecated as of Kyverno 1.19) + PSS labels + enforce, **cosign/Sigstore verification**, registry allow-list | Kyverno 1.19 already emits a deprecation warning for `ClusterPolicy`; audit-only gives no protection |
| Runtime security | Falco (modern eBPF) | **Tetragon** (Cilium-native, kernel-level enforcement, process identity) — optionally alongside Falco; **Cilium mutual auth (SPIFFE mTLS)** | Cilium is already the CNI; Tetragon is the natural 2026 complement/enforcement layer |
| Networking | IPv4, L2 announcements | Dual-stack IPv6; BGP where the router supports it; **CiliumClusterwideNetworkPolicy default-deny** + egress allow-lists | Egress allow-all is the largest remaining lateral-movement surface |
| Observability | VM + Grafana + Loki + Alloy | Same core, **plus alerting** (Alertmanager → ntfy/Telegram/Discord), blackbox external probes, SLOs; **OTel Collector + Tempo** instead of in-memory Jaeger; Loki min-free-space guard | Dashboards without alerts give no signal — exactly what a silent reboot exposes |
| GitOps | Flux app-of-apps, image automation | Flux **Alerts/Receivers**, driftDetection, image automation for *every* image (WAF is manual today), **PR-based promotion** for prod, `flux-local`/kubeconform in CI | Closes the "green but stale" and "unreviewed push to prod" gaps |
| IaC | OpenTofu + SSH local-exec, `-target` | `terraform_data`/Talos provider, **remote encrypted state**, CI `plan` + tflint/trivy/checkov | Reproducibility and review currently depend on a single workstation |
| Supply chain | SHA-pinned Actions, no signing | **cosign keyless signing + SBOM + SLSA provenance**, verified at admission; `timeout-minutes`, `persist-credentials: false` | Digest pinning guarantees *which* image, not *who* built it |
| Ingress | **Gateway API (ahead of the curve)** | Keep — ingress-nginx went EOL March 2026 | This is the strongest architectural bet; no change needed |
