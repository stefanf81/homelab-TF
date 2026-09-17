# Remediation Backlog — TaskFlow Homelab (September 2026)

Prioritized, pick-up-later backlog from the September 2026 architecture review.
Companion to `SOTA_HOMELAB_2026.md` (the SOTA gap comparison).

**Step 0 — commit & push first.** The StorageClass default change, PDB fixes,
cert-manager resources, and trivy cleanup are edited locally but **not committed**.
The local clone is behind `origin/main`; run `git pull --rebase`, commit, push,
and let Flux reconcile before starting any P0 work.

Already changed but uncommitted (for context, do not redo):

- `proxmox-csi` set as default StorageClass (live + Helm values + `--disable local-storage` in cloud-init).
- PDBs switched to `maxUnavailable: 1` + `unhealthyPodEvictionPolicy: AlwaysAllow` (backend, frontend, postgres).
- cert-manager controller/webhook/cainjector/startupapicheck resources added.
- Dead `scanJob.resources` block removed from trivy-operator HelmRelease.

---

## P0 — Availability & data safety (this week)

- [ ] **1. Alerting (biggest single gap).** A reboot, disk fill, or cert failure is currently invisible.
  - `monitoring/platform/release.yaml`: `vmalert.enabled: true`, `alertmanager.enabled: true`.
  - New `monitoring/platform/vmrules.yaml`: `KubeNodeNotReady`, `KubePodCrashLooping`/restart-rate,
    `KubeDeploymentReplicasMismatch`, `up == 0`, PV >80% (`kubelet_volume_stats_*`),
    node disk (`node_filesystem_avail_bytes`), `CertificateNotReady` +
    `certmanager_certificate_expiration_timestamp_seconds < 14d`, Loki/VMSingle disk-free.
  - Route Alertmanager → ntfy (phone push) or Telegram.
  - Add `gitops/clusters/taskflow/flux-alerts.yaml` (`Provider` + `Alert`) so Flux failures surface too.

- [ ] **2. Backups with an offsite copy.** `Retain` is not a backup; there is no backup mechanism today.
  - Quickest best practice: **k8up** (restic schedules → S3/R2) for PVCs + a `pg_dump`/pgBackRest
    CronJob for Postgres, both to Cloudflare R2 / Backblaze B2; keep Proxmox PBS for VM-level.
  - Enable CSI VolumeSnapshot support (snapshot controller + CRDs) if proxmox-csi supports
    snapshots on `local-lvm`.
  - Write RPO/RTO in `PERFORMANCE.md`; perform one restore drill.
  - Long-term: replace the Postgres Deployment with **CloudNativePG** (WAL archiving → S3, PITR).

- [ ] **3. k3s secrets encryption at rest.** `sops-age`, Helm release values, and decrypted Secrets
  are plaintext in the sqlite datastore.
  - `modules/proxmox/main.tf:87`: add `--secrets-encryption` for new nodes.
  - Current node: add the flag to its k3s config, restart k3s once (brief blip), then
    `k3s secrets-encrypt reencrypt`; document key rotation (`rotate-keys`) in a runbook.

- [ ] **4. Image-automation controllers into Git.** A re-bootstrap silently breaks digest pinning.
  - Regenerate `gotk-components.yaml` with
    `flux install --components-extra=image-reflector-controller,image-automation-controller --export`
    (or add a `gotk-components-image.yaml` referenced by the flux-system kustomization).
  - Delete the manual workaround in `gitops/FLUX_BOOTSTRAP.md` §7.4.

## P1 — Correctness & hygiene (next few days)

- [ ] **5. Reloader.** Deploy stakater/reloader; add `reloader.stakater.com/auto: "true"` to
  backend, frontend, and both WAFs. Delete the manual rollout runbooks
  (`*-waf.yaml:1-4`, FLUX docs). Covers ConfigMap **and** Secret rotations.

- [ ] **6. Remove the unused OAuth secret.** Delete `policy-reporter-secrets.yaml`
  (`policy-reporter-github-oauth`), the live secret, and revoke the GitHub app;
  fix `gitops/README.md:125`. Decide on `kyverno.jokelab.dev`: finish the OAuth app
  (replace the `PLACEHOLDER` values in `policy-reporter-ui-oauth-secrets.yaml`) or drop the route.

- [ ] **7. Certificate hardening.** Split `certificate.yaml` into per-hostname Certificates
  (one failure must not take down app + Grafana + Kyverno + Hubble), add
  `renewBefore: 720h` and `privateKey.rotationPolicy: Always`, plus the expiry alert from #1.

- [ ] **8. Kyverno to CEL + enforcement.** `ClusterPolicy` is deprecated (live warning).
  - Migrate to `policies.kyverno.io/v1 ValidatingPolicy`; flip core rules to `Deny`.
  - Fix the untagged-image hole (`!*:latest` misses `nginx`).
  - Add policies for runAsNonRoot/seccomp/drop-ALL, no `hostPath`/`hostNetwork`/privileged,
    registry allow-list.
  - Add PSS labels to every namespace (`pod-security.kubernetes.io/enforce: baseline|restricted`).
  - Add `seccompProfile: RuntimeDefault` + `automountServiceAccountToken: false` to taskflow workloads.

- [ ] **9. Default-SC follow-through for the current node.** Add `--disable local-storage` to the
  running k3s (SSH + restart + delete the SC) so `local-path` cannot silently return.
  Terraform already covers new nodes.

- [ ] **10. Small fixes:**
  - metrics-server: `--kubelet-certificate-authority` instead of `--kubelet-insecure-tls`.
  - CoreDNS pinned image (`1.14.7` vs chart `1.14.6`): align or annotate with a `# renovate:` marker.
  - Fix the Jaeger QoS comment (Burstable, not Guaranteed).
  - Widen the L2 interface regex (`ens*`, `eno*`).
  - Reserve `192.168.50.201` (dedicated pool or Cilium LB-IPAM `serviceSelector`).
  - Narrow oauth2-proxy scopes to `user:email`.
  - Add Flux `driftDetection: enabled` to HelmReleases.

- [ ] **11. Egress policies.** Start with the `taskflow` namespace: default-deny egress + allow DNS,
  DB/Redis/Jaeger inside the namespace, registry/monitoring scrape, and explicit external
  endpoints. Then `monitoring`. Copy the Renovate namespace pattern.

## P2 — Resilience & supply chain (next few weeks)

- [ ] **12. 3-node HA.** Three Proxmox VMs (or mini-PCs): k3s `--cluster-init` (embedded etcd) or
  Talos; API VIP via kube-vip or Cilium LB; control-plane taints; decide storage
  (keep proxmox-csi + PBS, or replicated Longhorn/democratic-csi).

- [ ] **13. Supply chain.** GH Action: `id-token: write`, cosign keyless signing + `syft` SBOM +
  SLSA provenance, `timeout-minutes`, `persist-credentials: false`; pin Dockerfile base images
  by digest; add Kyverno `ImageValidatingPolicy` to verify signatures + registry allow-list;
  branch-protect `main` and move image updates to PRs (Flux `ImageUpdateAutomation` → PR branch,
  or keep direct commits with a documented threat model).

- [ ] **14. Runtime security.** Add Tetragon (Cilium-native, kernel enforcement) alongside Falco;
  enable Cilium mutual auth (SPIFFE) between WAF → app → DB paths.

- [ ] **15. Observability depth.** blackbox_exporter probes for `www.jokelab.dev` + Grafana
  (alert on `probe_success`); Loki `min_free_disk_space`/retention guard; eventually
  OTel Collector + Tempo instead of in-memory Jaeger.

## P3 — SOTA convergence (ongoing)

- [ ] **16. Talos Linux migration** (Image Factory + `talosctl upgrade-k8s`) — removes SSH/cloud-init
  drift entirely. Or, staying on k3s: add **system-upgrade-controller** so K8s patch bumps
  become automated PRs instead of manual work.

- [ ] **17. Secrets beyond Git.** ESO + OpenBao/Vault/Bitwarden, keeping SOPS only for bootstrap;
  add rotation runbooks.

- [ ] **18. IaC hardening.** `null_resource` → `terraform_data` (`triggers_replace`); pin the node
  SSH host key; encrypted remote state (S3/R2 + `use_lockfile`); drop `-target` from the Makefile;
  add CI (`tofu plan` + tflint/trivy/checkov) and `flux-local`/kubeconform validation on PRs.

- [ ] **19. Dual-stack IPv6** if the ISP/router allows, plus cluster-wide default-deny
  (`CiliumClusterwideNetworkPolicy`) with audited egress.
