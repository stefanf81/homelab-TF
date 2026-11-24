# Open Work

The single, current list of what is still missing, verified against the code on 2026-11-21.
The dated reports in `reports/` explain *why* and *how* (options, YAML, verification,
rollback); their own status markers are frozen and partly out of date, so status lives here.
IDs are the `reports/REMEDIATION_PLAN_2026-10.md` IDs where one exists.

When an item lands, delete its row (or move a decision to the last table) in the same commit.

Status: **Open**, **Partial** (the row says what remains), **Verify** (live-node state that
Git cannot show).

## Reliability

| ID | Item | Status | What remains | Where |
|---|---|---|---|---|
| REL-01 | Alerting: Alertmanager + receiver, dead-man's switch, alert rules (cert expiry, disk, Flux not-ready, Falco critical, node CPU saturation), Flux `Alert`, external probe | Partial | vmalert runs only for recording rules (`notifier.blackhole`); Alertmanager disabled; no VMRule, VMProbe or Flux `Provider`/`Alert` anywhere | `gitops/monitoring/platform/release.yaml` |
| REL-02 | Backups: `pg_dump` CronJob off-host (stopgap), then CloudNativePG + object-store backups; PVC backups; off-host copy of the age key and k3s token; PBS for the VM; written RPO/RTO and a restore drill | Open | Nothing exists. Proxmox CSI attaches PV disks with `backup=0`, so even a VM backup misses Postgres, Grafana and VictoriaMetrics data | `modules/proxmox/main.tf`, `gitops/apps/taskflow/postgres-pvc.yaml` |
| REL-05 | Certificates: DNS-01 wildcard or per-host certificates, `renewBefore`, expiry alert | Partial | ECDSA P-256 with `rotationPolicy: Always` is done; still one 5-SAN certificate over HTTP-01, no `renewBefore`; cert-manager still passes the deprecated `--enable-gateway-api` | `gitops/apps/taskflow/certificate.yaml`, `gitops/infrastructure/controllers/cert-manager/release.yaml` |
| REL-08 | Automated k3s upgrades (system-upgrade-controller) and OS reboots (kured) | Open | Only after REL-01 and REL-02 | — |
| HA-01 | 3-node HA (embedded etcd or Talos, API VIP, storage decision) | Open (long-term) | CIL-01/CIL-02 and WireGuard become relevant with a second node | — |
| OBS-01 | Tracing backend: OTel Collector → Tempo instead of in-memory Jaeger | Open (long-term) | Jaeger all-in-one keeps 5000 traces in memory | `gitops/apps/taskflow/jaeger.yaml` |
| OBS-02 | k3s `/metrics` body outgrows vmagent's scrape limit | Verify | `max_scrape_size: 48MiB` on the apiserver and kubelet scrapes is in Git (both failed from 2026-11-19 to 2026-11-24; the alerts that fired reached no one, see REL-01). New nodes also get `disabled-metrics` from the snippet. The running node needs `NODE_HOST_TUNING.md` §3.7 (one k3s restart), and the check there confirms the nine families are gone | `gitops/monitoring/platform/release.yaml`, `modules/proxmox/main.tf`, `NODE_HOST_TUNING.md` §3.7 |

## Security

| ID | Item | Status | What remains | Where |
|---|---|---|---|---|
| SEC-01 | Origin reachable without Cloudflare (router port-forward) | Open | Cloudflare Tunnel + WAF `trusted_proxies` change + Gateway ingress policy; then close router 80/443 and retire DDNS | `gitops/apps/taskflow/cloudflare-ddns.yaml`, `gitops/infrastructure/configs/cilium/abuseipdb-ingress-deny.yaml` |
| SEC-02 | k3s secrets encryption at rest | Open | No `secrets-encryption` in the k3s config; the plan has the live-node procedure (two restarts) | `modules/proxmox/main.tf` |
| SEC-03 | Database least privilege (app owner role, `pg_monitor` exporter role) | Open | Backend and exporter both log in as `postgres` | `gitops/apps/taskflow/postgres-db.yaml`, `postgres-exporter.yaml` |
| SEC-04 | Egress control, staged in Cilium audit mode (SEC-04a) | Partial | Restricted: both WAFs, both metric exporters, `abuseipdb-sync`, Renovate; Postgres, Redis and Jaeger have no egress at all. Still allow-all: backend (SMTP relay not enumerated), frontend, cloudflare-ddns, the other namespaces; no cluster-wide baseline | `gitops/apps/taskflow/namespace-default-deny.yaml`, `gitops/apps/taskflow/default-deny.yaml` |
| SEC-06 | Image automation pushes unreviewed commits to `main` with the sync credential | Partial | PR validation exists. Still: push to `main`, one PAT for sync and push, no HelmRelease rendering in CI | `gitops/clusters/taskflow/image-automation/update-automation.yaml` |
| SEC-08 | Security headers, Grafana session hardening | Partial | Grafana `cookie_secure`/`samesite` done; no HSTS/nosniff/Referrer-Policy on routes or Caddyfiles; Grafana HSTS/CSP/login lifetimes unset | `gitops/apps/taskflow/httproute.yaml`, `gitops/monitoring/platform/release.yaml` |
| SEC-09 | Falco least privilege; detections to Alertmanager | Partial | Falco runs with four capabilities instead of `privileged`, `system-cluster-critical`, rules from the image (no falcoctl). Open: detections reach no one (Falcosidekick writes PolicyReports only; needs REL-01 alerting) | `gitops/infrastructure/controllers/falco/release.yaml` |
| SEC-10 | Scanning the privileged platform images | Open | In-cluster scanning was rejected (see below); a scheduled CI `trivy image`/`trivy k8s` run is still missing | `.github/workflows/` |
| SEC-12 | Supply chain: cosign signing, Kyverno `ImageValidatingPolicy` + registry allow-list, digest pins everywhere | Partial | SBOM, provenance, hadolint and the Trivy gate are done for both image builds. The TaskFlow backend/frontend images are signed and attested by taskflow-enterprise's publish workflow and checked by `verify-taskflow-images` and `require-taskflow-image-scan` (Deny, fail-open). The WAF and `abuseipdb-sync` images are signed and attested by `.github/workflows/publish-image.yaml` and checked by `verify-homelab-images` (Deny; both pin signed revisions, WAF `r15` and `abuseipdb-sync` `0.3.5-r10`). Open: allow-list; chart-level images that are tag-only | `.github/workflows/build-*.yaml`, `gitops/apps/kyverno-policies/` |
| SEC-13 | metrics-server skips kubelet TLS verification | Open | Drop `--kubelet-insecure-tls` | `gitops/monitoring/platform/metrics-server-release.yaml` |
| SEC-14b | Stale `policy-reporter-github-oauth` Secret | Open | Remove `policy-reporter-secrets.yaml` from the kustomization and Git, revoke the old OAuth app. Also confirm the UI proxy's credentials are no longer placeholders: `sops -d gitops/platform/policy-reporter/policy-reporter-ui-oauth-secrets.yaml \| grep -c PLACEHOLDER` must print 0 | `gitops/platform/policy-reporter/` |
| SEC-15 | Kubernetes API audit log | Verify | New nodes get the policy and the `kube-apiserver-arg` settings from the snippet. The running node needs `NODE_HOST_TUNING.md` §3.7 (one k3s restart). Not shipped to Loki yet (needs the Alloy DaemonSet variant, PERF-10) | `modules/proxmox/main.tf`, `NODE_HOST_TUNING.md` §3.7 |
| SEC-16 | Provisioning hygiene | Partial | Installer pinning done. Open: `root@pam` token and root SSH for the provider; node SSH host key not pinned | `providers.tf`, `modules/k3s-kubeconfig/main.tf` |
| SEC-17 | Backend RSA private key in an env var; heap dumps | Open | Mount the key as a file; decide on heap dumps | `gitops/apps/taskflow/backend.yaml` |
| SEC-18 | Tetragon next to Falco; Cilium mutual auth | Open (long-term) | — | — |
| SEC-19 | Secrets outside Git (ESO + a vault), SOPS for bootstrap only | Open (long-term) | — | — |
| SEC-20 | Leftover hardening | Open | Jaeger has a writable root; Alloy runs as root with a hostPath; cloudflare-ddns uses the deprecated `CF_API_TOKEN`; `flux-system` has no PSA labels | `gitops/apps/taskflow/jaeger.yaml`, `gitops/monitoring/logging/alloy-release.yaml` |
| SEC-21 | WAF false positives on free text (blocking PL2, empty exclusion files) | Open | Six legitimate requests are blocked today and pinned as known false positives in `tests/benign-corpus.py` (review comments, catalog name/description, time-off reason, a service name with `&` and parentheses). Check Loki for those rule IDs on `application="taskflow-backend"`, then request-scoped exclusions per field, or PL1 blocking with `detection_paranoia_level=2` while tuning; flip each case to `PASS` with its exclusion | `gitops/apps/taskflow/backend-waf.yaml`, `gitops/images/taskflow-caddy-coraza/tests/benign-corpus.py` |

## Performance and networking

| ID | Item | Status | What remains | Where |
|---|---|---|---|---|
| PERF-07 | JVM flags | Partial | `-XX:+UseCompactObjectHeaders` (needs the backend image's AOT cache retrained); `/tmp` emptyDir unbounded | `gitops/apps/taskflow/backend.yaml` |
| PERF-10 | Logging pipeline | Partial | Optional: Alloy DaemonSet reading files instead of API log streaming; VictoriaLogs | `gitops/monitoring/logging/alloy-release.yaml` |
| PERF-13 | `GOMEMLIMIT` on `abuseipdb-sync` | Open (low) | WAFs and Jaeger have it | `gitops/platform/abuseipdb/deployment.yaml` |
| CIL-01 | Cilium native routing (`routingMode: native`, `autoDirectNodeRoutes`) | Open | Planned window; re-check the `cilium_host` address the WAFs trust afterwards. Procedure: `reports/CILIUM_REVIEW_2026-10.md` §4.2 | `gitops/infrastructure/controllers/cilium/release.yaml` |
| CIL-03 | `gatewayAPI.enableAlpn` (HTTP/2 from Cloudflare to Envoy) | Open | Does not need SEC-01 (`reports/NETWORK_REVIEW_2026-10.md` §2.6) | same |
| CIL-04 | Cilium operator dashboard | Open (low) | Agent and Hubble dashboards are vendored; the operator one is not | `gitops/monitoring/app/dashboards/` |
| LB-01 | Dedicated pool (or `serviceSelector`) for the Gateway IP `192.168.50.201` | Open | It sits inside the shared `.200–.250` pool | `gitops/infrastructure/configs/cilium/ippool.yaml` |
| NET-01 | Cloudflare Smart Tiered Cache | Open | Dashboard setting, not in Git | — |
| NET-02 | `SERVER_TOMCAT_MAX_KEEP_ALIVE_REQUESTS` 100 → 1000 | Open (optional) | — | `gitops/apps/taskflow/configmap.yaml` |

## Platform and IaC

| ID | Item | Status | What remains | Where |
|---|---|---|---|---|
| FLUX-01 | HelmRelease `driftDetection` | Open (optional) | None of the 18 HelmReleases sets it | — |
| FLUX-02 | Shared HelmRelease defaults (remediation, `crds`) via a Kustomize patch | Open (low) | Every HelmRelease repeats the block | — |
| FLUX-03 | Flux `Receiver` (GitHub webhook) | Open (optional) | — | — |
| IAC-01 | IaC hardening | Partial | CI fmt/validate/tflint/kubeconform done; open: `null_resource` → `terraform_data`, encrypted remote state, IaC config scan, `tofu plan` in CI | `modules/k3s-kubeconfig/main.tf`, `providers.tf` |
| OS-01 | Talos Linux | Open (long-term) | — | — |
| NET-03 | Dual-stack IPv6 | Open (long-term) | ISP-dependent | — |
| LIVE-01 | One-off steps on the running node | Verify | kube-proxy disabled and `KUBE-*` chains flushed (PERF-01); all k3s flags in `config.yaml`, unit runs `k3s server` (REL-00); `/etc/cloud/cloud-init.disabled`; `local-storage` and the packaged CoreDNS disabled; `tcp_mtu_probing`; NIC multiqueue active | `docs/NODE_HOST_TUNING.md` §3 |

## Decided against (keep the reason)

| Item | Decision | Reason / where |
|---|---|---|
| Trivy Operator on platform namespaces (SEC-10) | Rejected in-cluster | Scan jobs for excluded pods still ran (upstream trivy-operator #2817) and exceeded node headroom; allowlist `taskflow,abuseipdb` (`docs/TRIVY_SECURITY_SCANNING.md` §3) |
| Policy Reporter REST off (SEC-05/14c) | Rejected | The chart enables REST whenever the UI is on; namespace default-deny covers it |
| CoreDNS `autopath @kubernetes` | Rejected | Breaks `toFQDNs` for `abuseipdb-sync` (`gitops/infrastructure/controllers/coredns/release.yaml`) |
| oauth2-proxy scope `user:email` only | Rejected | The GitHub provider needs `read:org` |
| kubelet static CPU manager (PERF-02 option B) | Rejected | Pins only Guaranteed pods with whole CPUs (`docs/NODE_HOST_TUNING.md` §2) |
| Postgres `hostUsers: false` | Deferred | Needs an idmapped mount of the CSI volume |
| `bpf.datapathMode: netkit` (CIL-02) | Deferred | Node rebuild only, after a released fix for cilium#47913 |
| HTTP HelmRepository for the VM stack, Loki, Alloy, metrics-server, trivy-operator | Kept | No (or stale) OCI chart; the CI validators read the HTTP index |
| Exporters as native sidecars; one shared WAF base | Rejected | Separate lifecycles and simpler diffs |
| Cilium `endpointRoutes`, `socketLB.hostNamespaceOnly`, BIG TCP, DSR/maglev, `envoy.enabled: false` | Do not copy | Would change the Envoy → WAF source address the WAFs trust (`reports/CILIUM_REVIEW_2026-10.md` §3) |
| h2c WAF → backend, Caddy `lb_try_duration`/`encode`, NodeLocal DNSCache, HTTPRoute retries | Rejected | `reports/NETWORK_REVIEW_2026-10.md` §2.7 |

## Closed

Done and verified in code on 2026-11-21: REL-00, REL-03, REL-04, REL-06, REL-07, SEC-05,
SEC-07, SEC-11, SEC-14a, PERF-01 to PERF-06, PERF-08, PERF-09, PERF-11, PERF-12, and the
NETWORK_REVIEW §2.1–2.3/2.5 and CILIUM_REVIEW §4.1/4.3 items. See `git log` for the changes.
