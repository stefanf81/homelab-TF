# Cluster Audit — October 2026

Full review of every workload Flux reconciles from `gitops/`, plus the k3s/Proxmox
layer in `modules/`. For each app it answers three questions: is the
configuration state of the art, can it be tuned for performance, and is it
secure.

"State of the art" is measured against five leading community GitOps homelabs,
read at their HEAD on 2026-10-19: `onedr0p/home-ops` (`b346c88`),
`bjw-s-labs/home-ops` (`6f465b6`), `buroa/k8s-gitops` (`7a85da0`),
`joryirving/home-ops` (`fdef7d6`) and `szinn/k8s-homelab` (`9e1a01d`). All five
run multi-node Talos, so node-level comparisons are translated to k3s.

Static review of this repository at `87a87e1` (2026-10-19); nothing was run
against the live cluster. Items marked **verify** depend on live state or on
the separate backend/frontend repositories.

Companion documents: `SOTA_HOMELAB_2026.md` (September gap analysis) and
`BACKLOG_2026.md` (September remediation backlog). §5 tracks what happened to
that backlog.

---

## 1. Verdict

The workload-level engineering is above what most public homelab repos do:
every TaskFlow pod runs non-root with `seccompProfile: RuntimeDefault`,
dropped capabilities, read-only root filesystems where the image allows it and
no service-account token; custom images are digest-pinned; secrets are SOPS
encrypted; ingress is Gateway API on Cilium (ingress-nginx is EOL); the WAF
(Caddy + Coraza CRS at paranoia level 2, per-IP rate limits keyed on a
validated client IP) is more careful than anything in the reference repos; and
the data tier sits behind default-deny network policies. None of the five
reference repos runs Kyverno, Falco, Trivy or oauth2-proxy at all, so the
security tooling here goes further than theirs.

Where the reference repos are ahead is the platform: none of them exposes a
port on the home router (Cloudflare Tunnel or a WireGuard edge VPS instead),
all run CloudNativePG with object-store backups, Kopia-based PVC backups,
Alertmanager with an external dead-man's switch, Reloader, Flux Operator with
OCI chart sources, and no CPU limits.

The gaps are at the platform level and most of them are already in your
September backlog. **None of the four P0 items has been done**:

| # | Gap | Risk |
|---|-----|------|
| 1 | No alerting (vmalert and Alertmanager disabled, no Flux `Alert`) | A reboot, full disk, expiring cert or Falco detection produces no signal |
| 2 | No backups of Postgres, Grafana or any PVC; `Retain` is not a backup | One bad migration or deleted PVC loses all bookings |
| 3 | Origin is reachable directly through the router port-forward, bypassing Cloudflare | Cloudflare WAF, bot and DDoS protection only apply to traffic that chooses to use it (new finding) |
| 4 | k3s secrets are stored unencrypted in the sqlite datastore | Anyone with the VM disk or a Proxmox backup has every secret, including the `sops-age` key |
| 5 | k3s still runs kube-proxy next to Cilium's kube-proxy replacement | Duplicate iptables programming and conntrack work on every Service change (new finding) |

Sections 2–4 give the per-app detail; §6 is the prioritized action list.

---

## 2. App-by-app review

Legend: ✅ state of the art · 🟡 fine for a homelab, behind SOTA · 🔴 gap.

### 2.1 Node and cluster layer

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Ubuntu 26.04 VM (Proxmox, `cpu: host`, virtio-scsi-single, iothread, discard) | image 20260927 | 🟡 Talos is the community default (`SOTA_HOMELAB_2026.md`) | ✅ VM hardware settings are right | 🟡 see below |
| k3s | v1.36.x, sqlite datastore | 🟡 | 🔴 kube-proxy not disabled | 🔴 no secrets encryption, no audit log |

- 🔴 **kube-proxy still runs.** The install line in `modules/proxmox/main.tf:87`
  disables flannel, servicelb, traefik, CoreDNS, metrics-server and local-storage,
  but not kube-proxy, while Cilium runs with `kubeProxyReplacement: true`.
  `docs/ARCHITECTURE.md` §10 states the opposite. Both datapaths program Services;
  Cilium's eBPF path wins at the socket level, so it works, but k3s keeps
  rewriting iptables and conntrack on every Service/EndpointSlice change. Add
  `--disable-kube-proxy` (and, on the live node, `disable-kube-proxy: true` in
  `/etc/rancher/k3s/config.yaml`, restart k3s, then flush the `KUBE-*` chains or
  reboot). Every reference repo that runs Cilium disables kube-proxy
  (Talos `KubeProxyConfig: enabled: false`, e.g. onedr0p
  `talos/controlplane.yaml.j2`).
  **Do not edit the cloud-init snippet in Terraform casually:** changing it
  replaces `proxmox_virtual_environment_file.cloud_config`, which changes
  `user_data_file_id` and plans a VM replacement. Change the live node first and
  fold the flag into Terraform together with an `ignore_changes` entry or a planned
  rebuild.
- 🔴 **No `--secrets-encryption`** (backlog P0 #3). Proxmox `vzdump` backups of the
  VM disk carry the plaintext datastore.
- 🟡 No API-server audit policy (`--kube-apiserver-arg=audit-policy-file=…`,
  `audit-log-path`, `audit-log-maxage`). Falco covers syscalls, nothing records
  who changed what through the API.
- 🟡 No automated OS reboots or k3s upgrades: add kured (reboot window) and
  system-upgrade-controller (backlog #16). The reference repos use `tuppr`, which
  is Talos-only and gates upgrades on backup and storage health.
- 🟡 `curl https://get.k3s.io | sh` at first boot runs an unverified script;
  the version is pinned but the installer is not. Low risk, but the k3s release
  artifacts can be fetched with checksums instead.
- 🟡 Terraform uses a `root@pam` API token and root SSH (`providers.tf`). A
  dedicated Proxmox user with a custom role limits the blast radius of a leaked
  `terraform.tfvars`. Check the same for the token inside
  `proxmox-csi-secrets.yaml` (**verify**: it should be a CSI-only role, not root).

**CPU budget (verify on the live node).** Explicit CPU requests in Git add up
to about 6.5 CPU (about 6.1 at steady state, without transient jobs), before
Flux's own controllers and charts that set no requests. At the Terraform
default of 6 vCPU with 400m kube/system reserved, allocatable is 5.6 CPU. If the
VM really has 6 cores, the cluster is over-reserved: the backend's rolling
update needs 2 more CPU for the surge pod and will sit `Pending`. Check
`kubectl describe node | grep -A8 'Allocated resources'`. The fix is right-sizing
(§3.1), not more cores.

### 2.2 Networking: Cilium, Gateway API, CoreDNS, L2

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Cilium (+ Envoy, Hubble relay/UI) | 1.20.2 | ✅ core choice; 🟡 tuning | 🟡 | 🟡 |
| Gateway API CRDs | v1.6.3 standard | ✅ | ✅ | ✅ |
| CoreDNS | chart 1.48.2, image 1.14.7 | ✅ | 🟡 | ✅ |
| L2 announcements, LB pool | — | ✅ | ✅ | 🟡 |

What the reference repos set that this release does not (onedr0p, bjw-s, buroa
and joryirving agree on all of these; file
`kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`):

- `bandwidthManager: {enabled: true, bbr: true}` — BBR congestion control and
  EDT pacing for pod traffic. Helps responses to internet clients most.
- `rollOutCiliumPods: true` and `operator.rollOutPods: true` — today a Helm value
  change updates the `cilium-config` ConfigMap but the agents keep the old
  config until something restarts them, so a change can look applied and not be.
  This is a correctness fix more than a performance one.
- `routingMode: native`, `ipv4NativeRoutingCIDR: 10.42.0.0/16`,
  `autoDirectNodeRoutes: true` — no effect while there is one node (traffic never
  leaves it), but set it before a second node arrives so VXLAN is never used.
- `bpf.preallocateMaps: true` (steadier latency, a little more memory),
  `endpointRoutes.enabled: true`, `pmtuDiscovery.enabled: true`.
- `enableIPv4BIGTCP: true` — only helps high-throughput east-west traffic and
  needs driver support; low value here.
- `loadBalancer: {algorithm: maglev, mode: dsr}` and `socketLB.hostNamespaceOnly`
  are multi-node or sidecar concerns; skip them for now.

Not recommended as a quick win: `bpf.datapathMode: netkit` (buroa, joryirving and
szinn use it; onedr0p and bjw-s stay on veth). Cilium 1.20 marks netkit beta,
an existing node cannot be switched from veth in place, and mixing modes is
unsupported. Adopt it when the node is rebuilt or when a second node is added.

Specific to this cluster (the reference repos use Envoy Gateway, not Cilium's
Gateway API, so they have no equivalent):

- `envoy.resources.requests` — the `cilium-envoy` DaemonSet carries every
  Gateway request but has no requests, so it gets the worst OOM score on the node.
  Give it at least `cpu: 50m, memory: 64Mi`.
- `k8sClientRateLimit` — Cilium's L2 announcement docs say to size it as
  `services × 1/leaseRenewDeadline`. With one announced IP the defaults (10 QPS,
  burst 20) are ample; revisit only if many LoadBalancer IPs are added.

CoreDNS: replace `cache 30` with the block the reference repos use,
`cache { prefetch 20; serve_stale; servfail 0 }` (onedr0p and buroa), so hot names
are refreshed before they expire and an upstream hiccup returns a stale answer
instead of SERVFAIL. They also set `pods verified` instead of `pods insecure`,
and `log { class error }`.

Security:

- Hubble relay (`hubble-relay.kube-system:80`) and the Hubble UI service have no
  network policy. The oauth2-proxy protects the public path only; any pod in the
  cluster can read every flow. Restrict them to the oauth2-proxy namespace and
  host.
- The L2 policy matches `^eth[0-9]+` and `^enp[0-9]+` but not `eno*`/`ens*`
  (backlog #10). Fine for the current virtio NIC.
- `192.168.50.201` is requested explicitly by the Gateway but also inside the
  general pool (backlog #10): give the Gateway its own one-address pool.

### 2.3 Public exposure: Cloudflare, Gateway, certificates, DDNS

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Router port-forward → `192.168.50.201` | — | 🔴 no reference repo opens a home port | ✅ | 🔴 |
| cert-manager, HTTP-01 | v1.21.2 | 🟡 all five use DNS-01 | ✅ | 🟡 |
| `taskflow-jokelab-cert` (5 SANs, RSA) | — | 🟡 all five use one ECDSA wildcard | 🟡 RSA | 🟡 |
| cloudflare-ddns (favonia) | 1.17.1 | ✅ | ✅ | ✅ |

- 🔴 **Direct-to-origin traffic bypasses Cloudflare.** The documented path is
  `DNS → public IP → port-forward → 192.168.50.201`. Anyone who finds the WAN
  address (internet-wide TLS scans index certificates by IP) reaches the Gateway
  directly, so Cloudflare's WAF rules, bot fight mode, rate limiting and the
  AbuseIPDB edge list do not apply, and `grafana.`, `hubble.` and `kyverno.` are
  reachable without Cloudflare in front. The Cilium AbuseIPDB deny only removes
  known-bad addresses. Two fixes, best first:
  1. **Cloudflare Tunnel** (`cloudflared` Deployment → Gateway Service). No
     inbound port at all; close 80/443 on the router. onedr0p, buroa and szinn do
     this (onedr0p `network/cloudflare-tunnel/app/helmrelease.yaml`: two replicas,
     `*.turbo.ac` → the external gateway over HTTPS with `http2Origin: true`).
     bjw-s gets the same effect with a WireGuard edge VPS and a
     CiliumNetworkPolicy that only admits the VPS address.
  2. Keep the port-forward but allow only Cloudflare's published ranges plus the
     LAN on the `reserved:ingress` identity (a `CiliumCIDRGroup` for the
     Cloudflare ranges + a `CiliumClusterwideNetworkPolicy`), and enable
     Cloudflare *Authenticated Origin Pulls*. Note that
     `abuseipdb-ingress-deny.yaml` currently contains `ingress: fromEntities: all`;
     allow rules are additive, so that rule must be replaced by the allowlist or
     the allowlist has no effect.
- 🟡 **Switch ACME to DNS-01** with a Cloudflare token scoped to
  `Zone:DNS:Edit` on `jokelab.dev`. It removes the need for port 80, allows a
  wildcard certificate, and stops certificate issuance depending on the
  hairpin-NAT CoreDNS override. The reference repos also set
  `dns01RecursiveNameservers: https://1.1.1.1:443/dns-query,https://1.0.0.1:443/dns-query`
  with `dns01RecursiveNameserversOnly: true`, so the propagation self-check
  never goes through the local resolver.
- 🟡 One certificate covers five hostnames (backlog #7): a failed challenge on
  `kyverno.` blocks renewal for `www.`. All five reference repos issue a single
  `[domain, "*.domain"]` wildcard via DNS-01 with
  `privateKey: {algorithm: ECDSA, size: 256}` (onedr0p
  `network/certificates/export/certificate.yaml`). ECDSA P-256 makes every TLS
  handshake on the Gateway cheaper than the default RSA-2048.
  `rotationPolicy: Always` is already the default since cert-manager v1.18.
  They also request Let's Encrypt's `shortlived` profile (6-day certificates);
  optional.
- 🟡 No HSTS or other security headers are set anywhere in this repository
  (Gateway, either WAF). **Verify** in the frontend's nginx config; otherwise
  enable HSTS in Cloudflare (SSL/TLS → Edge Certificates) or add a `header`
  block to the frontend WAF Caddyfile.
- cert-manager: `--enable-gateway-api` via `extraArgs` still works, but v1.21
  moved the setting to the controller config as `config.gatewayAPI.enabled: true`
  (the v1.15–v1.20 field `config.enableGatewayAPI` is now deprecated too). Only
  needed while HTTP-01 uses `gatewayHTTPRoute`; with DNS-01 it can go.

### 2.4 TaskFlow application

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Backend (Spring Boot 4.1.1, JVM) | digest-pinned `:latest` | ✅ | 🟡 | ✅ pod; 🟡 DB role |
| Frontend (Angular 22 on nginx) | digest-pinned `:latest` | ✅ | ✅ | ✅ |
| Backend/Frontend WAF (Caddy 2.11.7 + Coraza 2.6.2 + CRS) | `r6`, digest-pinned | ✅ beyond SOTA | 🟡 | ✅ |
| PostgreSQL | 18.6-alpine (tag only) | 🔴 plain Deployment, no backups | 🟡 | 🟡 |
| Redis | 8.10.2-alpine (tag only) | 🟡 | 🟡 | ✅ |
| Jaeger all-in-one (in-memory) | 2.22.0 | 🟡 | ✅ | ✅ not exposed |
| postgres-exporter / redis-exporter | 0.20.1 / 1.93.0 | ✅ | ✅ | 🟡 superuser |

**Backend** (`apps/taskflow/backend.yaml`)

- Performance:
  - The 2-CPU Guaranteed reservation is a third of a 6-vCPU node for a mostly
    idle app. Requests equal to limits do *not* mean "never throttled" (the
    comment says so): without the kubelet static CPU manager the container is
    still CFS-throttled whenever it uses its 200 ms per 100 ms period, and the JVM
    bursts exactly then (JIT, GC, startup). Either (a) drop the CPU limit, keep a
    right-sized request (check `container_cpu_usage_seconds_total` over two weeks;
    likely 500m–1 CPU) and pin `-XX:ActiveProcessorCount=2` so JVM ergonomics do
    not jump to 6 CPUs, or (b) keep Guaranteed and enable
    `--kubelet-arg=cpu-manager-policy=static` with `reserved-cpus`, which gives
    the pod exclusive cores and actually removes throttling. Option (a) is what
    the reference repos do: onedr0p and buroa set no CPU limits anywhere, only
    memory limits and small CPU requests.
  - If the image runs JDK 25 or newer, `-XX:+UseCompactObjectHeaders` (JEP 519,
    a product flag since JDK 25) cuts object headers from 12 to 8 bytes, which
    typically means 10–20 % less live heap. **Verify** the image's JDK version.
    It must go in `JAVA_TOOL_OPTIONS` *and* the image's CDS/AOT archive must be
    trained with the same flag, or the archive is silently ignored.
  - `-XX:+UseContainerSupport` is the default since JDK 10; drop it.
  - `/tmp` emptyDir has no `sizeLimit` and receives heap dumps (up to the 1 GiB
    heap) and GC logs. Add `sizeLimit: 2Gi`.
- Security:
  - **Verify which database role the backend uses.** The exporter connects as
    `postgres` (superuser) and the backend reads the same `POSTGRES_PASSWORD`; if
    `spring.datasource.username` is also `postgres`, a single SQL injection gives
    `COPY … TO PROGRAM`, i.e. shell inside the database pod. Create an app role
    that owns the schema (no `SUPERUSER`, `CREATEROLE`, `CREATEDB`) and give the
    exporter its own `pg_monitor` role.
  - The RSA private key arrives as an environment variable; a file mount
    (`/run/secrets/…`, mode `0400`) keeps it out of `/proc/*/environ` and child
    processes. The OOM heap dump in `/tmp` also contains it.
  - `SPRING_REDIS_PASSWORD` maps to the Spring Boot 2 property `spring.redis.password`;
    Boot 3+ reads `spring.data.redis.password` (`SPRING_DATA_REDIS_PASSWORD`, also
    set). Unless the app reads the old name itself, drop the duplicate.

**WAFs** (`apps/taskflow/*-waf.yaml`)

- Configuration is excellent: correct trusted-proxy chain, `trusted_proxies_strict`,
  `CF-Connecting-IP` deliberately ignored, query-string redaction, CI tests that
  keep both trusted-proxy lists in sync.
- Performance:
  - Set `GOMEMLIMIT` from the memory limit (downward API `resourceFieldRef:
    limits.memory`, or a fixed ~90 % value). Since Go 1.25 the runtime derives
    `GOMAXPROCS` from the cgroup CPU limit automatically, but it still knows
    nothing about the memory limit: without `GOMEMLIMIT` the GC lets the heap grow
    past the 768Mi/512Mi limit until the kernel OOM-kills Caddy under a CRS-heavy
    burst.
  - The frontend WAF runs the full CRS on every static asset. The nginx image
    already sends `Cache-Control: public` with a 6-month expiry, so make sure
    Cloudflare caches them (`cf-cache-status: HIT` on `/main-*.js`; add a cache
    rule for hashed assets if not). Every cached hit is a request neither WAF nor
    nginx has to handle.
- Both WAFs need a manual `rollout restart` after a ConfigMap edit (header
  comment). Reloader (backlog #5; all five reference repos run it) or a Kustomize
  `configMapGenerator` with a content hash removes that step.

**PostgreSQL** (`apps/taskflow/postgres-db.yaml`)

- SOTA: all five reference repos run Postgres through **CloudNativePG**. bjw-s
  (`kubernetes/components/cnpg/pg18/cluster.yaml`) is the closest template: PG 18.6,
  the barman-cloud plugin as WAL archiver to an object store with 30-day
  retention, a `ScheduledBackup`, and a `bootstrap.recovery` stanza so a rebuilt
  cluster restores itself. onedr0p sets `enableSuperuserAccess: false`. CNPG also
  preloads `pg_stat_statements` automatically and creates separate app and
  monitoring roles, which closes the superuser finding above. Even with one
  instance this gives a tested backup and restore path. This is backlog P0 #2.
- 🔴 **Startup probe can kill crash recovery.** `pg_isready` reports "rejecting
  connections" while Postgres replays WAL. The startup budget is about 32 s
  (`initialDelaySeconds: 2` + 10 × 3 s), while `max_wal_size=2GB` lets up to 2 GB
  of WAL accumulate between checkpoints. After an unclean shutdown under write
  load, replay can take longer than 32 s; the kubelet then kills Postgres
  mid-recovery and it restarts the replay, in a loop. Raise `failureThreshold`
  to 100 (5 min); liveness only starts once startup succeeds, so this costs
  nothing in normal operation.
- Performance:
  - Add `shared_preload_libraries=pg_stat_statements` (then
    `CREATE EXTENSION pg_stat_statements;`) and `track_io_timing=on`: you cannot
    tune queries you cannot see, and postgres-exporter can export the top
    statements. Changing `shared_preload_libraries` needs a restart.
  - `jit=off`: JIT compilation helps long analytical queries and adds latency to
    short OLTP queries like these.
  - `checkpoint_timeout=900` (15 min) with the existing `max_wal_size=2GB`: fewer
    checkpoints, fewer full-page writes.
  - Mount an `emptyDir: {medium: Memory, sizeLimit: 256Mi}` at `/dev/shm`. The
    container default is 64 MB; parallel query and parallel vacuum use POSIX
    shared memory and fail with "could not resize shared memory segment" when
    it runs out.
  - `max_parallel_maintenance_workers=2` is already the PostgreSQL default; the
    flag does nothing.
- Durability: `synchronous_commit=off` is a valid, documented trade-off, but the
  comment's reasoning is wrong. On a single primary, `on` guarantees the commit's
  WAL is flushed to the *local* disk before the client is told "committed"; it
  is not about replicas. With `off`, an unclean shutdown can lose up to about
  600 ms (3 × `wal_writer_delay`) of bookings the user already saw as confirmed.
  Keep it only if that is acceptable for appointments.
- Hardening: add `readOnlyRootFilesystem: true` with an emptyDir at
  `/var/run/postgresql`; pin the image by digest (Renovate `pinDigests`).

**Redis** (`apps/taskflow/redis.yaml`)

- `--io-threads 2` in a 500m container: `redis.conf` advises I/O threads only on
  machines with 4 or more cores, keeping one spare, and only when Redis is
  actually CPU-bound. With half a core, the extra thread competes for the same
  CFS quota and adds context switches. Use `--io-threads 1` (the default). The
  manifest comment is also outdated: in Redis 8, `io-threads-do-reads` is a
  deprecated no-op and I/O threads handle reads and writes.
- SOTA: none of the reference repos runs Redis or Valkey; they run **Dragonfly**
  (bjw-s `components/dragonfly/cluster.yaml`: `--proactor_threads=2`,
  `--maxmemory` taken from the memory limit through `resourceFieldRef`). For an
  ephemeral cache this small, Redis 8 is fine; Valkey is the drop-in if the
  Redis licence matters to you.
- Pin by digest; consider `readOnlyRootFilesystem: true` (only `/data` is
  written).

**Jaeger** — fine for development tracing; the in-memory store is capped. The
2026 direction is OTel Collector → Tempo or VictoriaTraces, which would sit
next to the existing VictoriaMetrics stack. Add `readOnlyRootFilesystem: true`.

**cloudflare-ddns** — fine. favonia added `CLOUDFLARE_API_TOKEN` in v1.15.0 and
marks `CF_API_TOKEN` for deprecation in 2.0.0; rename it when convenient. The
whole Deployment becomes unnecessary with a Cloudflare Tunnel (the reference
repos create a CNAME to `<id>.cfargotunnel.com` with external-dns instead).

**Namespace-level**

- 🔴 No egress control (backlog #11). Postgres, Redis and Jaeger can open
  connections to the internet; a compromised backend can reach Hubble relay,
  the Policy Reporter UI/REST API and every other unauthenticated in-cluster
  service. Start with default-deny egress plus DNS, intra-namespace paths and
  explicit FQDNs (`toFQDNs`, as `abuseipdb-sync` already does).
- No Pod Security Admission labels on `taskflow` (or most namespaces). The pods
  look compliant with `restricted`; add `enforce: baseline`,
  `warn/audit: restricted` now and move to `enforce: restricted` after a week
  of clean audit events.

### 2.5 Security tooling

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Kyverno (4 controllers) | 1.19.1 | 🔴 deprecated `ClusterPolicy`, Audit only | 🟡 heavy for 2 policies | 🟡 |
| Policy Reporter + UI + Trivy adapter | 3.11.0 / 0.11.5 | ✅ | ✅ | 🟡 |
| Falco + Falcosidekick | chart 9.2.0 / 2.35.0 | ✅ | ✅ | 🟡 privileged |
| Trivy operator (server mode) | chart 0.37.0 | ✅ | ✅ | 🟡 scope |
| AbuseIPDB synchronizer | 0.3.1-r1 | ✅ custom, well hardened | ✅ | 🟡 RBAC |
| oauth2-proxy ×2 (Hubble, Policy Reporter) | chart 10.7.1 | ✅ | ✅ | 🟡 cookies |

None of the five reference repos runs any of these tools; they rely on not
exposing anything publicly except through a tunnel. The ✅ marks therefore
compare against each tool's own upstream best practice.

- **Kyverno**: two Audit-mode policies run on ~1 CPU of limits and 640Mi of
  requests across four controllers. Migrate to `policies.kyverno.io/v1`
  `ValidatingPolicy` (backlog #8), or — for simple pod-security rules — to
  Kubernetes-native `ValidatingAdmissionPolicy` (GA since 1.30), which runs inside
  the API server with no webhook hop. If no `CleanupPolicy` exists, disable the
  cleanup controller.
- **Falco** runs as a fully privileged container. Set
  `driver.modernEbpf.leastPrivileged: true`: the chart then runs it with
  `CAP_SYS_RESOURCE`, `CAP_BPF`, `CAP_PERFMON` and `CAP_SYS_PTRACE` only.
  Falcosidekick writes PolicyReports and nothing else, so a detection is only
  seen when someone opens the UI; add an alert output (ntfy, Telegram,
  Alertmanager) together with backlog #1. The chart comment still describes an
  `-rc1` pin while `version: 9.2.0` is set; update or drop the comment.
- **Trivy** excludes every platform namespace, so the most privileged images on
  the node (Cilium, Falco, Proxmox CSI node plugin, Kyverno, CoreDNS) are never
  vulnerability-scanned. With server mode and `scanJobsConcurrentLimit: 1` the
  extra cost is small; scan them and keep only the noisy config-audit scope
  narrow.
- **Policy Reporter**: `rest.enabled: true` exposes a read API for all
  reports to the whole cluster (Falcosidekick writes PolicyReports through the
  Kubernetes API, not this endpoint). Disable it unless something reads it.
  `policy-reporter-secrets.yaml` (the old, unused GitHub OAuth app) is still
  applied (backlog #6): delete it and revoke the app. **Verify** that the
  PLACEHOLDER values in `policy-reporter-ui-oauth-secrets.yaml` were replaced;
  otherwise `kyverno.jokelab.dev` is a dead route.
- **oauth2-proxy** (both): `cookie_domains = [".jokelab.dev"]` with the default
  cookie name `_oauth2_proxy` means the two proxies overwrite each other's
  session cookie (logging into Hubble logs you out of Policy Reporter), and the
  browser sends the session cookie to `www.jokelab.dev` as well. Drop
  `cookie_domains` (host-only cookies) or give each proxy a distinct
  `cookie_name`. Narrow `scope` to `user:email`; `read:org` is unused because no
  org restriction is configured.
- **abuseipdb-sync**: the ClusterRole grants `get/update/patch` on *all*
  `ciliumcidrgroups`. Split it: `create` (cannot be name-scoped) plus
  `get/update/patch` with `resourceNames: [abuseipdb]`. The namespace has no PSA
  labels although the pod is `restricted`-compliant.

### 2.6 Observability

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| VMSingle + vmagent + operator | stack 0.96.0, operator 0.75.0 | ✅ lighter than the references' kube-prometheus-stack | ✅ | ✅ internal |
| kube-state-metrics, node-exporter, metrics-server | — / — / 0.9.0 | ✅ | ✅ | 🟡 insecure kubelet TLS |
| Grafana | 13.2.3 | ✅ (references use grafana-operator) | ✅ | 🟡 cookie flags |
| Loki (monolithic) + gateway | chart 18.15.1 | 🟡 all five references run VictoriaLogs | 🟡 | ✅ internal |
| Grafana Alloy | chart 1.13.1 | ✅ | 🟡 | 🟡 root + hostPath |
| vmalert / Alertmanager | disabled | 🔴 | — | 🔴 no alerts |

- 🔴 **Alerting** (backlog P0 #1): enable `vmalert` and `alertmanager` in the stack
  (the chart ships the default kubernetes-mixin rules), route to ntfy, Pushover
  or Telegram, add a Flux `Provider` + `Alert` for failed reconciliations, and add
  an external probe (Gatus or blackbox exporter) for `www.jokelab.dev`. The
  reference pattern (onedr0p `o11y/kube-prometheus-stack/app/alertmanagerconfig.yaml`
  and `components/alerts/`): Alertmanager → Pushover, the always-firing
  `Watchdog` alert routed every 2.5 minutes to an *external* Gatus heartbeat
  (it pages when the heartbeat stops, i.e. when the whole node is down), Flux
  `Alert`s at `eventSeverity: error` sent to Alertmanager plus GitHub commit
  status, and a Flux `Receiver` so a push reconciles immediately instead of
  waiting for the poll interval.
- **Grafana**: set `security.cookie_secure: true` (default is false even behind
  HTTPS), `security.strict_transport_security: true` and
  `security.content_security_policy: true`. Narrow GitHub scopes to `user:email`.
  The role mapping (`role_attribute_strict`, single login) is correct.
- **metrics-server**: replace `--kubelet-insecure-tls` with
  `--kubelet-certificate-authority` pointing at the k3s server CA
  (`/var/lib/rancher/k3s/server/tls/server-ca.crt`, mounted read-only), backlog #10.
- **Loki**: Alloy and Grafana go through the chart's nginx `loki-gateway`, which
  adds a pod and a hop in front of a single binary with auth disabled. Point both
  at `loki:3100` and disable the gateway (keep the `abuseipdb-sync` network
  policy in step). Longer term, VictoriaLogs (same vendor as the metrics stack,
  LogsQL, alerting through the same vmalert) uses a fraction of Loki's memory.
  All five reference repos run `victoria-logs-single` with
  `victoria-logs-collector`; only szinn still keeps Loki and Alloy alongside.
  The Alloy-derived WAF metrics would need an equivalent (vmalert recording
  rules over LogsQL, or keep Alloy just for that pipeline).
- **Alloy** collects logs only from `taskflow` and `abuseipdb`, through the
  Kubernetes API (`loki.source.kubernetes`). Flux, cert-manager, Kyverno and
  Falco logs are not collected. For cluster-wide logs, run Alloy as a DaemonSet
  that tails `/var/log/pods` (`loki.source.file`): it reads files from disk
  instead of streaming every line through the API server. The chart runs Alloy as
  root with a `hostPath` mount; set a non-root `securityContext` if the Hubble
  export file permissions allow it.
- **VMSingle**: drop unused high-cardinality series (API-server request
  histograms, unused cAdvisor metrics) with vmagent `metricRelabelConfigs`
  (already noted as open in `PERFORMANCE.md`).

### 2.7 GitOps and supply chain

| Component | Version | SOTA | Performance | Security |
|---|---|---|---|---|
| Flux | v2.9.6 | 🟡 | ✅ | 🟡 |
| Flux image automation | v1 APIs | 🟡 | ✅ | 🔴 pushes to `main` |
| Renovate operator + job | 6.5.1 / 44.155.1 | ✅ | ✅ | ✅ tightly scoped |
| GitHub Actions (WAF, abuseipdb-sync) | SHA-pinned | ✅ | ✅ | 🟡 no signing |

- **Image automation commits straight to `main`**, which Flux then deploys.
  Combined with no branch protection and no PR validation, the in-cluster Git
  credential (which must have write access) is a path from "cluster compromised"
  to "arbitrary code on `main`". Push to an `image-updates` branch and let a
  workflow open an auto-merging PR gated on validation, or protect `main` and
  document the trade-off. The image-reflector/automation controllers are still not
  in `gotk-components.yaml` (backlog P0 #4): a re-bootstrap silently stops
  digest updates.
- **Validate every GitOps PR**: only WAF/dashboard paths are validated today. Add
  `flux-local test` (renders every Kustomization and HelmRelease) or kubeconform
  so a broken render fails in CI instead of in the cluster.
- **Flux Operator**: all five reference repos install Flux through the Flux
  Operator (`FluxInstance`, chart 0.61.0 in onedr0p) and have *zero*
  `HelmRepository` objects: every chart comes from an `OCIRepository` referenced
  by `chartRef`. That solves backlog #4 (the image controllers become a
  `components` list entry instead of a regenerated manifest) and makes Flux
  upgrades a Renovate PR. onedr0p
  (`flux-system/flux-instance/app/helmrelease.yaml`) also patches controller
  concurrency (`--concurrent=10/20`, `--requeue-dependency=5s`), enables the
  `OOMWatch`, `CancelHealthCheckOnNewRevision` and `DefaultToRetryOnFailure`
  feature gates, and applies HelmRelease defaults (`strategy: RemediateOnFailure`,
  `cleanupOnFail`, `crds: CreateReplace`) centrally instead of repeating them in
  every release as this repo does.
- `driftDetection` is rare in the reference repos (one repo, two charts); it is
  optional, not a gap.
- **Supply chain**: images are digest-pinned but not signed (backlog #13). Add
  cosign keyless signing, SBOM and provenance to both build workflows, and a
  Kyverno image-verification policy for `ghcr.io/stefanf81/*`. Pin the
  remaining tag-only images by digest with Renovate `pinDigests`
  (Postgres, Redis, Jaeger, both exporters, DDNS, the `alpine` init container,
  Falcosidekick, CoreDNS, the Caddy and Go base images).

---

## 3. Performance summary

### 3.1 Highest-value changes

1. Disable kube-proxy (§2.1).
2. Right-size CPU: drop CPU limits on latency-sensitive pods (backend, Postgres,
   WAFs, Cilium Envoy) or enable the static CPU manager, then lower requests to
   measured usage plus headroom. This also frees the scheduler headroom the
   backend's rolling update needs.
3. Cilium: BBR bandwidth manager, `rollOutCiliumPods`, Envoy requests; netkit at
   the next node rebuild (beta, cannot be switched in place).
4. Postgres: `pg_stat_statements` and `track_io_timing` first (visibility), then
   `jit=off`, 15-minute checkpoints and a memory-backed `/dev/shm`.
5. Redis: `--io-threads 1` at 500m.
6. Go services: `GOMEMLIMIT` on the WAFs (and oauth2-proxy, abuseipdb-sync).
7. JVM: compact object headers on JDK 25.
8. ECDSA certificate keys; make sure Cloudflare caches the hashed frontend assets.
9. Loki: bypass the nginx gateway; consider VictoriaLogs.

### 3.2 Already well tuned

JVM sizing and off-heap caps, `MALLOC_ARENA_MAX=2`, Tomcat keep-alive towards
the WAF, Loki results cache and limits, VMSingle sizing, scrape-interval
choices, Trivy server mode with a concurrency of one, Redis persistence off for
an ephemeral cache, `fsGroupChangePolicy: OnRootMismatch` on Postgres, and the
Proxmox VM settings (`cpu: host`, virtio-scsi-single, iothread, discard).

---

## 4. Security summary

| Severity | Finding | Section |
|---|---|---|
| High | Origin reachable directly; Cloudflare protections optional for an attacker | 2.3 |
| High | No backups | 2.4 |
| High | No alerting; Falco/Trivy/WAF detections go nowhere actionable | 2.6 |
| High | Secrets unencrypted in the k3s datastore (and in VM backups) | 2.1 |
| Medium | Database accessed as the `postgres` superuser (exporter certain, backend **verify**) | 2.4 |
| Medium | No egress policies; unauthenticated in-cluster UIs (Hubble relay/UI, Policy Reporter) | 2.2, 2.4, 2.5 |
| Medium | Image automation pushes unreviewed commits to `main`; no PR validation | 2.7 |
| Medium | oauth2-proxy session cookies shared across subdomains | 2.5 |
| Medium | Falco fully privileged; platform images never scanned by Trivy | 2.5 |
| Medium | Kyverno audit-only, deprecated API; no PSA labels on most namespaces | 2.4, 2.5 |
| Low | Grafana cookie/HSTS flags; no HSTS in repo | 2.3, 2.6 |
| Low | metrics-server `--kubelet-insecure-tls` | 2.6 |
| Low | abuseipdb-sync RBAC not name-scoped; stale OAuth secret still deployed | 2.5 |
| Low | Tag-only images; unsigned custom images | 2.7 |
| Low | Proxmox root token/SSH for Terraform; unverified k3s installer | 2.1 |

---

## 5. Status of the September backlog

| Backlog item | Status in the repo today |
|---|---|
| P0 #1 Alerting | Open (`vmalert`/`alertmanager` disabled, no Flux alerts) |
| P0 #2 Backups | Open |
| P0 #3 k3s secrets encryption | Open (flag absent in `modules/proxmox/main.tf`) |
| P0 #4 Image controllers in Git | Open (`gotk-components.yaml` lists four controllers) |
| P1 #5 Reloader | Open (WAFs still say "MANUAL RELOAD REQUIRED") |
| P1 #6 Unused OAuth secret | Open (`policy-reporter-secrets.yaml` still in the Kustomization) |
| P1 #7 Certificate hardening | Open (single 5-SAN certificate) |
| P1 #8 Kyverno CEL + enforcement | Open (seccomp/SA-token part done) |
| P1 #9 `local-storage` disabled | Done in Terraform; live node **verify** |
| P1 #10 Small fixes | Open: metrics-server TLS, oauth2-proxy scopes, LB IP reservation, `driftDetection` (optional, see §2.7); L2 regex partly widened (`enp*` added) |
| P1 #11 Egress policies | Open (only `renovate` and `abuseipdb` restrict egress) |
| P2/P3 #12–#19 | Open |

Documentation drift found during the review:

- `docs/ARCHITECTURE.md` §10 says Cilium replaces kube-proxy; the k3s flags do not disable it.
- `gitops/README.md` says the PDBs use `minAvailable: 1` (they use `maxUnavailable: 1`)
  and that the Policy Reporter UI uses its built-in GitHub OAuth (it is disabled;
  oauth2-proxy fronts it).
- `falco/release.yaml` comment describes an `-rc1` pin; the chart is `9.2.0`.
- `postgres-db.yaml` explains `synchronous_commit` in terms of replicas (§2.4).
- `backend.yaml` says Guaranteed QoS means CPU is never throttled (§2.4).
- `redis.yaml` says reads stay on the main thread unless `--io-threads-do-reads`
  is set; that option is a no-op in Redis 8 (§2.4).

---

## 6. Prioritized action list

**This week (risk reduction)**

1. Alerting: vmalert + Alertmanager → ntfy/Telegram, Flux `Alert`, external probe, Falcosidekick alert output.
2. Backups: CloudNativePG with the barman-cloud plugin to R2/B2 (or a `pg_dump` CronJob to R2 as a stopgap), plus PVC backups for Grafana and Loki. The reference repos moved from VolSync to kopiur (Kopia-based, CSI-snapshot source, auto-restore through the PVC's `dataSourceRef`); **verify** that proxmox-csi supports VolumeSnapshots on `local-lvm` first, otherwise use VolSync or k8up in copy mode. Do one restore drill.
3. Close direct origin access: Cloudflare Tunnel, or the Cloudflare-only allowlist on `reserved:ingress`.
4. `--secrets-encryption` on the live node, then `k3s secrets-encrypt reencrypt`.
5. Postgres startup probe `failureThreshold: 100`.

**Next (quick wins, low risk)**

6. `--disable-kube-proxy` on the live node.
7. App and exporter database roles without superuser.
8. oauth2-proxy host-only cookies and `user:email` scope; Grafana `cookie_secure`/HSTS.
9. Cilium: `rollOutCiliumPods`, Envoy requests, BBR; CoreDNS `prefetch`/`serve_stale`.
10. Redis `--io-threads 1`; Postgres `pg_stat_statements`, `jit=off`, `/dev/shm`; WAF `GOMEMLIMIT`.
11. Falco `leastPrivileged`; Trivy scans platform namespaces; name-scoped abuseipdb RBAC; delete the stale OAuth secret.

**Then (convergence with SOTA)**

12. Egress default-deny for `taskflow`, then `monitoring`; network policies for Hubble and Policy Reporter.
13. PSA labels everywhere; Kyverno `ValidatingPolicy` in Enforce; image signature verification.
14. Image automation via PR; `flux-local` validation on every PR; Flux Operator with `OCIRepository` chart sources; Reloader.
15. DNS-01 + per-host or wildcard ECDSA certificates.
16. CPU right-sizing from two weeks of VictoriaMetrics data.
17. Longer term: VictoriaLogs, OTel → Tempo/VictoriaTraces, netkit and native routing at the next rebuild, Talos or system-upgrade-controller + kured, 3 nodes.
