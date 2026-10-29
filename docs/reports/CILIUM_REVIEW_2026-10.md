# Cilium Configuration Review vs. Home-Operations Repos (October 2026)

Scope: every Cilium object in this repository, compared against the Cilium
v1.20.4 chart (`install/kubernetes/cilium/values.yaml`), the v1.20.4 tuning guide
(`Documentation/operations/performance/tuning.rst`) and the Cilium values of six
widely copied home-operations repositories, read at their `main` on 2026-10-29:

| Repository | Commit | Cilium | OS / ingress |
|---|---|---|---|
| onedr0p/home-ops | `f36ee9f` | 1.20.4 | Talos, Envoy Gateway |
| bjw-s-labs/home-ops | `a2f5f47` | 1.20.4 | Talos, Envoy Gateway |
| buroa/k8s-gitops | `91f7ccc` | 1.20.4 | Talos, Envoy Gateway |
| joryirving/home-ops | `f2fe242` | 1.20.4 | Talos, Envoy Gateway |
| szinn/k8s-homelab | `88f2de3` | 1.20.4 | Talos, Envoy Gateway |
| mirceanton/home-ops | `523cc11` | 1.20.4 | Talos, Envoy Gateway |

This complements `PERF_DEEP_DIVE_2026-10.md` §4 (PERF-03), which already
evaluated and applied the bandwidth manager, BBR, rollouts and resources. Those
verdicts are not repeated here unless the comparison changes them.

Files reviewed:

- `gitops/infrastructure/controllers/cilium/{release,repository}.yaml`
- `gitops/infrastructure/configs/cilium/{ippool,l2announcement-policy,abuseipdb-ingress-deny}.yaml`
- `gitops/infrastructure/configs/gatewayclass.yaml`, `gitops/apps/taskflow/gateway.yaml`
- the 7 `CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` files, `modules/proxmox/main.tf`

## 0. Summary

**For a single-node k3s VM with virtio-net, the configuration is already close to
the best you can get without rebuilding the node.** The chart is current (1.20.4,
same as all six repositories). Kube-proxy replacement, socket LB, eBPF host routing,
eBPF masquerading, tcx, the bandwidth manager with BBR, config-checksum rollouts and
no CPU limits are all in place. That is the core of Cilium's own "recommended
performance profile".

The six repositories look very different, but almost all of the difference comes
from **Talos + bare metal + several nodes + Envoy Gateway**, not from tuning this
cluster lacks. Copying their values one-to-one would break things here (see §3).

What is left, by priority:

| # | Change | Gain here | Cost / risk | When |
|---|---|---|---|---|
| 1a | `routingMode: native` + `bpfClockProbe: true` (§4.2) | Pod route MTU 1450 → 1500. No VXLAN device. Cheaper CT timestamps. Measured same-node gain elsewhere: none (§7); mostly prep for a second node | Agent restart; existing connections may reset. WAF trusted-proxy IP must be checked again | Planned window |
| 1b | `bpf.datapathMode: netkit` (§4.2) | Lowest per-packet cost Cilium offers | **Not in place.** The 1.20 agent refuses to start while veth pods exist, so the switch is a node reboot. Open netkit policy bug ([cilium#47913](https://github.com/cilium/cilium/issues/47913)). Gateway-on-netkit is not proven by any reference repo | Next node rebuild, after #47913 ships a fix |
| 2 | virtio-net multiqueue on the VM NIC (§4.3) | RX/TX softirq spread over 6 vCPUs instead of one; `fq` gets one leaf per queue | NIC hot-replug or VM reboot; slightly more CPU per packet | Optional, with the next planned reboot |
| 3 | Cilium agent/operator Grafana dashboards (§4.1) | Visibility to prove items 1–2 (BPF map pressure, regeneration time, drops) | Bootstrap-ordering trap (see §4.1) | Any time |
| 4 | Longer L2-announcement lease timers (§4.1) | ~5× fewer Lease writes to k3s's SQLite (kine) | Agent restart (seconds) | Optional |
| 5 | `gatewayAPI.enableAlpn` (HTTP/2 from Cloudflare to Envoy) | Multiplexed edge→origin connections | Needs Cloudflare "HTTP/2 to Origin" | With SEC-01, as already planned |

Nothing in the table is a large win for human-scale traffic. Item 1 is the only
one that changes the datapath itself. §6 summarises what the community ran into
with these settings between May and October 2026.

## 1. What is configured today

| Area | Value | Assessment |
|---|---|---|
| Chart | 1.20.4 via `OCIRepository` | Current; Renovate-tracked |
| Service handling | `kubeProxyReplacement: true` (k3s `--disable-kube-proxy`), socket LB for pods and host | Optimal. Connect-time translation, no per-packet DNAT |
| API server | `k8sServiceHost: ${NODE_IP}:6443` | Correct for k3s; does not depend on the ClusterIP Cilium provides |
| Devices | `devices: eth0` | Correct; keeps `tailscale0` out |
| Routing | `routingMode` unset → **tunnel (VXLAN)** | Works, but see §4.2 (route MTU) |
| Pod devices | `bpf.datapathMode` unset → **veth** | See §4.2 |
| Host routing | eBPF (`hostLegacyRouting: false`) | Optimal; required for BBR on pods and for netkit |
| Masquerade | eBPF | Optimal |
| Attach | tcx (chart default) | Optimal on this kernel |
| Bandwidth | `bandwidthManager` + `bbr` | Optimal (PERF-03) |
| Encryption | off | Correct for one node |
| Rollouts | `rollOutCiliumPods`, operator/envoy/relay/ui `rollOutPods` | Correct |
| Resources | requests set, memory limits only | Correct (PERF-02) |
| Gateway | Cilium Gateway API, per-node `cilium-envoy` DaemonSet, `xdsMode: split` | Fine. The separate DaemonSet keeps the Gateway up while the agent restarts |
| LB IPs | LB-IPAM pool `.200–.250`, L2 announcements on `^eth`/`^enp`, node selector `region=homelab` | Correct. Node selector prevents future ARP conflicts |
| Hubble | relay + UI, metrics `dns,drop,tcp,flow,icmp,httpV2`, file export of DROPPED/ERROR only | Reasonable; overhead is low at this traffic |
| Policies | 7 CNP/CCNP. FQDN policy (DNS proxy) only for `abuseipdb-sync`. AbuseIPDB `CiliumCIDRGroup` deny on `reserved:ingress` | DNS-proxy load is minimal; the CIDR group is an LPM lookup, cheap |

## 2. Side-by-side with the reference repositories

`✓` = set the same way as here, `—` = not set (chart default).

| Setting | Here | onedr0p | bjw-s | buroa | jory | szinn | mirceanton |
|---|---|---|---|---|---|---|---|
| `kubeProxyReplacement` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `bpf.masquerade` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `bandwidthManager.bbr` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | off |
| `rollOutCiliumPods` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `routingMode` | tunnel | native | native | native | native | native | tunnel |
| `bpf.datapathMode` | veth | veth¹ | veth¹ | **netkit** | **netkit** | **netkit** | veth |
| `bpfClockProbe` | — | ✓ | — | ✓ | ✓ | — | — |
| `bpf.preallocateMaps` | — | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `enableIPv4BIGTCP` | — | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `loadBalancer` maglev + DSR | — | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `endpointRoutes.enabled` | — | ✓ | — | ✓ | ✓ | ✓ | — |
| `socketLB.hostNamespaceOnly` | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `envoy.enabled` | ✓ (DaemonSet) | off | off | off | off | off | off |
| Cilium Gateway API | ✓ | — | — | — | — | — | — |
| `hubble.enabled` | ✓ | off | ✓ | off | ✓ | ✓ | ✓ |
| `dashboards.enabled` | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| L2 announcements | ✓ | BGP | BGP | BGP | ✓ + BGP | BGP | ✓ |
| `cgroup.autoMount: false`, trimmed capabilities | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `k8sServiceHost` | node IP | KubePrism | KubePrism | KubePrism | KubePrism | KubePrism | KubePrism |

¹ Only because netkit is incompatible with their Kata / gVisor sandboxes.

## 3. Differences that should not be copied

| Setting | Why the repositories have it | Why not here |
|---|---|---|
| `socketLB.hostNamespaceOnly: true` | Needed for Kata/gVisor sandboxes, Istio-style redirection, or cluster-wide consistency | Turns **off** connect-time service translation inside pods, so pods fall back to per-packet tc LB. That is slower. Leave it unset |
| `enableIPv4BIGTCP` | Bare-metal mlx5/ice NICs (tuning guide: "Supported NICs: mlx4, mlx5, ice"); also needs tunnelling off | The VM has virtio-net. Not applicable |
| `loadBalancer.mode: dsr`, `algorithm: maglev` | Multi-node; replies skip the ingress node, and backend choice stays consistent across nodes | One node, every backend is local. Gateway traffic ends at Envoy (L7), which DSR never touches |
| `endpointRoutes.enabled: true` | Common with native routing on multi-node | **Would likely change the source address the host-network Envoy uses to reach pods.** Today that address is `cilium_host` (`10.42.0.148`), and the WAFs trust exactly that `/32` (`backend-waf.yaml` `trusted_proxies`). If the peer changes, Caddy stops trusting X-Forwarded-For, and every visitor falls into one rate-limit bucket. Do not enable without re-running the WAF runbook Stage 0 |
| `bpf.preallocateMaps: true`, `distributedLRU` + `mapDynamicSizeRatio: 0.08` | Large bare-metal nodes (64–128 GiB). Lower tail latency under heavy CT churn | 14 GiB VM that runs everything. A 0.08 ratio sizes the maps against ~1.1 GiB of RAM. The gain cannot be measured at this connection rate, and switching recreates the maps (drops in-flight CT state) |
| `envoy.enabled: false` | They use Envoy Gateway, so they only need the agent's embedded L7 proxy | Here, the `cilium-envoy` DaemonSet *is* the Gateway data plane. Embedding it would restart the Gateway on every agent restart |
| `cgroup.autoMount: false`, `hostRoot: /sys/fs/cgroup`, capability list without `SYS_MODULE` | Talos: immutable, cgroup2 pre-mounted, no module loading | Ubuntu 26.04 works with the defaults. Dropping `SYS_MODULE` is optional hardening; run `lsmod` first to confirm every module the agent needs is already loaded |
| `k8sServiceHost: 127.0.0.1:7445` | Talos KubePrism | k3s has no KubePrism; node IP is right for one server |
| `hubble.enabled: false` (onedr0p, buroa) | Remove the 1–15 % Hubble overhead | The drop export feeds `blocked-sources` / `abuseipdb-security` and SEC-04a. Keep it |

The broader trend in the references is **Envoy Gateway instead of Cilium Gateway
API**, with Cilium reduced to CNI + LB. That is an architectural choice, not a
performance one. Cilium's Gateway is on Gateway API v1.6.3 (same as the CRDs here),
and nothing in this review argues for migrating.

## 4. Recommendations

### 4.1 Any time (no pod restarts)

**Grafana dashboards for agent and operator.** The metrics are scraped already
(`vmservicescrapes.yaml`), but no Cilium dashboard is provisioned. The chart's
`cilium-dashboard.json` and `cilium-operator-dashboard.json` use only a
`${DS_PROMETHEUS}` datasource variable and the `pod` label, so they work with
VictoriaMetrics as-is. **Trap:** the Grafana sidecar searches only `monitoring`
(`monitoring/platform/release.yaml`). Setting `dashboards.namespace: monitoring` on
the Cilium release would make the *CNI install* fail on a fresh bootstrap, because
that namespace does not exist yet when `infra-controllers` runs. Pick one of these:

- vendor the two JSON files into `gitops/monitoring/app/dashboards/`, following the
  existing `SOURCE.md` convention (recommended: consistent, no ordering issue); or
- leave the ConfigMaps in `kube-system` (`dashboards.enabled: true`,
  `operator.dashboards.enabled: true`, `annotations.grafana_folder: Cilium`) and add
  `kube-system` to `sidecar.dashboards.searchNamespace`.

The Hubble per-namespace and L7 dashboards need `labelsContext` on the Hubble
metrics (e.g. `drop:labelsContext=source_namespace,destination_namespace`) and a
`cluster` label. Without both they render empty, so leave them for later.

**L2-announcement lease timers (optional).** client-go renews a held lease every
`leaseRetryPeriod`, which defaults to 2 s. With one LoadBalancer Service (the
Gateway), that is a Lease PUT into k3s's SQLite every 2 s, forever. On one node
nothing fails over, and a restarted agent re-acquires its own lease at once (same
holder identity). So longer timers cost nothing until a second node joins:

```yaml
    l2announcements:
      enabled: true
      leaseDuration: 30s       # failover time once a second node exists
      leaseRenewDeadline: 20s
      leaseRetryPeriod: 5s     # renew interval: 0.5 → 0.2 writes/s
```

This is a small, free reduction in datastore churn, not a latency fix.

**Not worth changing:** `hubble.eventQueueSize` (only if the agent logs "hubble
events queue is full"), `bpf.monitorAggregation` (already `medium`),
`pmtuDiscovery` (`blackhole` mode is the right default), and the Envoy timeouts
(`idleTimeoutDurationSeconds: 60` is the *upstream* Envoy→WAF pool timeout. A
reconnect to a local pod costs microseconds, and it stays below Caddy's idle
timeout, so Envoy closes first: the right order).

### 4.2 Datapath changes (window or rebuild)

Cilium's tuning guide: these "change the underlying datapath fundamentals and
therefore require Pod or even node restarts". On a single node there is nothing to
drain to. They split into two steps with different risk:

- **Step A, a planned window:** native routing + clock probe. No pod-device change.
- **Step B, the next node rebuild:** netkit. It is the default for a fresh node, and
  an in-place switch needs a reboot anyway (see below). Wait until
  [cilium#47913](https://github.com/cilium/cilium/issues/47913) has a released fix.

```yaml
    routingMode: native
    ipv4NativeRoutingCIDR: 10.42.0.0/16   # k3s cluster-cidr
    autoDirectNodeRoutes: true            # nodes share the 192.168.50.0/24 L2 segment
    bpfClockProbe: true                   # jiffies instead of ktime for CT timestamps
    bpf:
      datapathMode: netkit                # step B only: L3 mode; kernel >= 6.8, eBPF host routing
      masquerade: true
      hostLegacyRouting: false
```

What each one buys:

- **Native routing.** In tunnel mode Cilium sets the pod route MTU to the device MTU
  minus the VXLAN overhead (1500 → 1450), even with one node. Every pod connection,
  including Envoy → WAF and pod → Internet, uses a 1410-byte MSS instead of 1460.
  Native routing removes `cilium_vxlan` and restores 1500. It is also the documented
  prerequisite for netkit and for adding the second node cleanly. Verify before and
  after on the node with `ip route | grep cilium_host` (host → pod routes, which
  Envoy uses), and inside a pod with
  `kubectl -n taskflow debug -it deploy/taskflow-backend-waf --image=nicolaka/netshoot -- ip route`.
  Expect `mtu 1450` today and no `mtu` afterwards.
- **netkit.** The pod's BPF program runs inside the netkit peer instead of a
  host-side veth tc hook. Cilium describes this as reducing namespace overhead
  "down to zero", which is the largest per-packet saving left. Three of the six
  references run it.
- **bpfClockProbe.** Cheaper timestamp reads on every CT lookup. Off by default only
  because existing CT entries would be misread, which does not matter once
  everything restarts anyway.

Pre-checks, in this order:

1. `uname -r` ≥ 6.8 (Ubuntu 26.04's kernel is well past that), and
   `cilium-dbg status | grep 'Host Routing'` shows `BPF`.
2. **Gateway on netkit is not proven by the references.** All netkit users among
   them run Envoy Gateway, not Cilium's Gateway with the host-network Envoy and L7
   redirects. Also, netkit "is incompatible with TPROXY (`bpf.tproxy`)", which is
   off here. Test it on the rebuilt node before cutting DNS over.
3. **Keep `endpointRoutes` and `socketLB.hostNamespaceOnly` unset.** The open bug
   cilium#47913 (1.20.x, reproduced by a maintainer on 2026-10-26) is reported for
   netkit *combined with* both. Same-node Service replies are reclassified as new
   flows and dropped by ingress policies (Postgres SYN-ACKs, DNS answers). This
   cluster has ingress policies everywhere, and all its traffic is same-node. The
   minimal trigger is not established, so this lowers the risk without removing it.
4. Write down `ip -4 addr show cilium_host` before the change, and compare it after
   (WAF `trusted_proxies 10.42.0.148/32`). Cilium normally restores the router IP
   from its state directory, but a rebuild or a state wipe gives a new one. If it
   changes, update both WAF ConfigMaps (the image test suite checks they match).

**Why netkit cannot be switched in place on 1.20.** On restore the agent checks
every pod endpoint whose host interface still exists, and exits fatally if any
uses another device type (`daemon/cmd/endpoint_restore.go`,
`validateDatapathModeCompatibility`):

> Cannot start cilium-agent with datapath-mode=netkit: detected N existing
> endpoint(s) using incompatible datapath-modes … Please delete these pods or
> correct the cilium-agent operational datapath-mode.

The same check blocks a rollback (netkit → veth). A homelab hit exactly this on
2026-10-28 (jimmy-ungerman/pork3s#2999): agents crash-looped, two Ceph OSDs went
down, and recovery meant suspending the HelmRelease and restoring the old mode.
Here, with one node, a crash-looping agent means the whole site is down. Also, the
HelmRelease's `upgrade.remediation` would roll back to veth mid-incident, which
fails the same check. On a running node, the only clean in-place path is a
reboot: `/var/run/cilium` is tmpfs, so the endpoints and their links are gone on
boot. In practice that is a rebuild without the reinstall, which is why step B
belongs to the rebuild.

Runbook for step A (native routing + clock probe):

1. Push the values. Flux upgrades; `rollOutCiliumPods` restarts the agent (seconds;
   connections may reset because existing CT timestamps are reinterpreted).
2. Restart workloads at leisure so pod routes lose `mtu 1450`
   (`kubectl -n <ns> rollout restart deploy,sts`), and restart `ds/cilium-envoy`.
3. Verify: `cilium-dbg status` shows `Routing: Network: Native` and
   `Clock Source for BPF: jiffies`. `ip route | grep cilium_host` shows no `mtu`.
   `cilium_host` still has `10.42.0.148`. Smoke-test Gateway HTTPS, WAF → backend,
   backend → Postgres/Redis, DNS, the FQDN policy of `abuseipdb-sync`, and Hubble
   drops still arriving in Loki.
4. Rollback: revert the commit; the agent restarts in tunnel mode.

Step B on the rebuilt node: put `datapathMode: netkit` in the values before
the first Cilium install, check `cilium-dbg status` for `Device Mode: netkit`,
then run the same smoke tests.

### 4.3 VM layer: virtio-net multiqueue

`modules/proxmox/main.tf` creates the NIC without `queues`, so virtio-net runs a
single queue pair. All RX interrupts and softirq work land on one vCPU, and the
bandwidth manager's `mq`/`fq` setup has a single leaf. The bpg provider supports it
directly:

```hcl
  network_device {
    bridge = var.network_bridge
    queues = var.cpu_cores
  }
```

Proxmox applies the change as a NIC hot-replug, or at the next reboot, so do it
together with a planned reboot. Check afterwards with `ethtool -l eth0`. If
"Current hardware settings → Combined" is below the pre-set maximum, set it with
`ethtool -L eth0 combined 6`, as the Proxmox docs instruct (recent guest kernels
normally enable all queues on their own). Then check `tc qdisc show dev eth0`: one
`fq` per queue under `mq`. The Proxmox docs recommend multiqueue for VMs that
"process a great number of incoming connections", such as a reverse proxy. They
warn that it raises host and guest CPU load as traffic grows, so at this traffic
it is a nice-to-have, not a fix.

### 4.4 With SEC-01 or Cloudflare "HTTP/2 to Origin"

`gatewayAPI.enableAlpn: true` lets Cloudflare multiplex requests over HTTP/2 to
Envoy. Note that it also enables `appProtocol` handling. The WAF Services have no
`appProtocol`, so Envoy → WAF stays HTTP/1.1. The backend Service's
`kubernetes.io/h2c` is not on the Gateway path (Caddy proxies to it over HTTP/1.1).
This verdict is unchanged from PERF-03.

## 5. Minor observations

- `release.yaml`'s `hostLegacyRouting` comment explains `false` as avoiding routing
  loops for host-network Envoy. The stronger reason to keep it `false` is that eBPF
  host routing is a hard requirement for BBR on pods (and for netkit later).
- `hubble.export.static` now supports `fieldAggregate` + `aggregationInterval`.
  This could collapse repeated scanner drops before they reach Loki. Check how
  aggregated records count per IP before using it, because `blocked-sources` counts
  log lines.

## 6. Community experience, May–October 2026

Reddit could not be read from the research environment: it blocks both the HTTP
client and the search crawler. The sources below are the community's public record
instead: the reference repositories' commit history since March 2026, cilium/cilium
issues and release discussions, other homelab repositories' PRs, and blog write-ups.

### 6.1 What the reference repositories changed and reverted

| When | Repository | Change | Take-away |
|---|---|---|---|
| 2026-03-02 | bjw-s | Downgraded 1.19.1 → 1.18.7, back on 1.19.x a week later | Even the most-copied repos roll back minor releases; let x.y.0/x.y.1 soak |
| 2026-05-13 | bjw-s | "Simplify towards defaults": dropped netkit, `bpfClockProbe`, `endpointRoutes`, XDP acceleration, `pmtuDiscovery`, `localRedirectPolicies` | The trend is fewer knobs, not more |
| 2026-07-19 → 07-26 | onedr0p | netkit → veth → netkit the same day, then veth for good, only because Kata cannot use netkit | netkit ran there for months without datapath complaints |
| 2026-08-18 | buroa | Tried `loadBalancer.acceleration: native` + `dsrDispatch: opt`, reverted the same day | XDP/DSR tuning is fragile even on bare metal; irrelevant on a VM |
| 2026-10-23 | onedr0p | Fixed `cgroup.automount` → `autoMount`. The misspelt key had been silently ignored (joryirving still carries it) | The Cilium chart schema does not reject unknown keys. This repo had the same class of bug (`hubble.ui.resources`, PERF-02 §1.5). A check against the 1.20.4 `values.yaml` found **no unknown keys** in `release.yaml` today |
| 2026-10-24/25 | onedr0p, buroa, szinn | Removed values equal to chart defaults | Explicit defaults are not wrong here (several are documented decisions), but the direction is clear |

### 6.2 Issues reported against 1.20.x, and whether they apply here

| Issue | Status | Applies here? |
|---|---|---|
| Agent ↔ Envoy xDS livelock, 85–100 % CPU on every node after 1.20.0 ([cilium#47624](https://github.com/cilium/cilium/issues/47624)); reported with a separate Envoy DaemonSet too | Fixed in 1.20.1 (#47899) | No, on 1.20.4. If agent/Envoy CPU ever pins, this is the first suspect |
| 1.20.3: BackendTLSPolicy handling caused high CPU and stopped Gateway forwarding | Reverted in 1.20.4 ([release discussion](https://github.com/cilium/cilium/discussions/49581)) | No BackendTLSPolicy in this repo; on 1.20.4. Renovate's `minimumReleaseAge: 3 days` would not have caught it (the fix took ~8 days), so read the Gateway section of each Cilium release note |
| 1.20.4 behaviour change: CiliumEnvoyConfig redirects only Services in its own namespace | Shipped | No CiliumEnvoyConfig here |
| netkit + `endpointRoutes` + `hostNamespaceOnly` drops same-node Service replies ([cilium#47913](https://github.com/cilium/cilium/issues/47913)) | Open; fix PR #47914 in draft | Only once netkit is enabled; see §4.2. At least two homelabs reverted to veth over it in October |
| 1.20 agent refuses to start when the datapath mode changes under existing pods ([pork3s#2999](https://github.com/jimmy-ungerman/pork3s/pull/2999)) | By design | Shapes the §4.2 plan |
| CPU lockup after Cilium start ([cilium#49370](https://github.com/cilium/cilium/issues/49370)) | Open; maintainer suspects kernel/hardware | No: bare-metal `qede` NICs, one node in ~95 |
| CVE-2026-49445: world-accessible Envoy `admin.sock` with L7 enabled | Fixed in 1.19.2 | No, on 1.20.4 |
| CVE-2026-56742: HTTPRoute mirroring into other namespaces, bypassing ReferenceGrant | Fixed in 1.17.17 / 1.18.11 / 1.19.5 | Probably not: the advisories found list no 1.20 range, but none confirms 1.20 explicitly (check GHSA-w7c2-w76w-5hmj). Low impact here regardless: every HTTPRoute is written by the repo owner |
| 1.20.4 security release: Go 1.26.10, distrust of a compromised eMudhra intermediate CA | Shipped | Already on it |

### 6.3 Cilium Gateway API in practice

There is no consensus to leave it. One homelab moved *from* Cilium Gateway to Envoy
Gateway in October, citing a "same-node proxy/host-firewall failure"
(bart-kochanowicz/homelab#88). Host firewall is off here. Another moved the other
way, from Envoy Gateway to Cilium Gateway, to simplify the stack
(rciliberto/lab-gitops#76). A 1.19.5 → 1.20.1 upgrade write-up reports a smooth
upgrade with Gateway API 1.6, and the Gateway finally showing
`PROGRAMMED=True` (enaplo.hu, 2026-09-11). Nothing found argues against staying on
Cilium's Gateway for this cluster.

### 6.4 Sources

- Reference repositories' history: `git log` of the Cilium paths of onedr0p/home-ops,
  bjw-s-labs/home-ops, buroa/k8s-gitops, joryirving/home-ops, szinn/k8s-homelab,
  mirceanton/home-ops, fetched 2026-10-29
- https://github.com/cilium/cilium/issues/47624
- https://github.com/cilium/cilium/issues/47913
- https://github.com/cilium/cilium/issues/49370
- https://github.com/cilium/cilium/discussions/49581
- https://github.com/jimmy-ungerman/pork3s/pull/2999
- https://github.com/jsimcina/k8s-home/pull/3461
- https://github.com/bart-kochanowicz/homelab/pull/88
- https://github.com/rciliberto/lab-gitops/pull/76
- https://enaplo.hu/2026/09/11/cilium-gateway-api-the-1-20-update/
- https://osv.dev/vulnerability/CVE-2026-49445
- https://osv.dev/vulnerability/CVE-2026-56742
- https://pve.proxmox.com/wiki/Qemu/KVM_Virtual_Machines (virtio-net multiqueue)
- Cilium v1.20.4 source: `daemon/cmd/endpoint_restore.go`, `install/kubernetes/cilium/values.schema.json`

## 7. Published benchmarks, and how far they transfer

No benchmark compares "everything Cilium supports". What exists, by area:

| Area | Best available source | What it shows | Relevance to this node |
|---|---|---|---|
| CNI datapath (Cilium vs Calico, eBPF vs legacy host routing, encryption) | Cilium's own [CNI benchmark](https://docs.cilium.io/en/stable/operations/performance/benchmark/) (`benchmark.rst`). **Still Cilium 1.9.6 on kernel 5.10, 2021**, two bare-metal hosts with 100 Gbit E810 NICs, netperf | eBPF host routing beats legacy host routing and Calico, most clearly on connection rate (TCP_CRR, 32 processes). WireGuard needs less CPU than IPsec per Gbit | Confirms the settings already here (eBPF host routing, KPR). Says nothing about netkit, BIG TCP or 1.20 |
| Independent CNI comparison | InfraBuilder/Ducastel series, last edition **August 2020** (Cilium 1.8.2, 10 Gbit) | Historical only | None |
| Tunnel (VXLAN) vs native routing | [Talos hybrid cluster test](https://dev.to/bnovickovs/comparing-cilium-networking-setups-on-a-talos-hybrid-kubernetes-cluster-3gdk) (Sep 2025, `cilium connectivity perf`) | Cross-node: native ~7–8 % lower RR/CRR latency, throughput mixed. **Same-node: identical** (TCP_RR ~34 µs, TCP_CRR ~67 µs in both modes) | All traffic here is same-node, so expect no measurable gain from native routing beyond the MTU |
| netkit vs veth | Vendor material only: Meta's [FOSDEM 2025 slides](https://fosdem.org/2025/events/attachments/fosdem-2025-4045-an-introduction-to-netkit-the-bpf-programmable-network-device/slides/237196/An_Introd_TgFgOaU.pdf) (p99 > 12 s → ~100 ms in a 4× stacking test with heavy softirq); ByteDance case study (~10 %) | Large wins under extreme softirq pressure | Not this cluster's regime. No independent benchmark exists |
| kube-proxy modes | Kubernetes blog (nftables ≈ IPVS), AKS (nftables p50 ≈ iptables p01 at 5k–10k Services); Isovalent (eBPF > IPVS > iptables) | Differences matter at thousands of Services | ~40 Services here; KPR is already on |
| Gateway API implementations | [howardjohn/gateway-api-bench](https://github.com/howardjohn/gateway-api-bench) Part 1 (Cilium 1.17.2, single-node kind, 16-core) | Cilium: ~20k qps ceiling regardless of connections ("bottlenecked to single core"; others 130k–400k at 16–512 conns), p99 0.118 ms at 1 conn, 503s during route changes, Envoy config update stops silently past ~1.5 MB (one CEC per Gateway), highest control-plane CPU at route scale | The qps ceiling is ~1000× above this site's traffic. Route changes cause brief 503s: deploy route changes off-peak. 6 HTTPRoutes are far below the 1.5 MB limit. Part 2 dropped Cilium; [cilium#39974](https://github.com/cilium/cilium/issues/39974) has only a partial 1.19 rerun ("CPU and memory quite a bit better") and no full rerun |
| BBR | Google/Isovalent material (Internet-path gains); no Cilium-specific 2026 benchmark | Gains on lossy, long paths | Cloudflare → origin over a home uplink is exactly that path; keep it |
| Hubble overhead | Tuning guide: 1–15 % depending on traffic and aggregation | — | Small at this traffic; measure agent CPU before turning anything off |

Several 2026 blog "benchmarks" (Cilium vs Calico vs Flannel with Gbps and p99 tables) publish no hardware, versions or method, and contradict each other. Ignore them.

Two open Gateway issues read close to this setup:

- [cilium#47940](https://github.com/cilium/cilium/issues/47940) (open; 1.19.6–1.20.3): Envoy's connections to **same-node** backends get an RST, so requests alternate 200/503. It is nondeterministic across reboots. The original report is Ubuntu 26.04 + k3s + KPR + VXLAN + Envoy DaemonSet; a second report adds Tailscale in netfilter mode. Not seen here, but every backend is same-node and this node runs Tailscale. If alternating 503s with rising `upstream_cx_connect_timeout` appear after a reboot, check `sysctl net.ipv4.conf.all.src_valid_mark` first (the maintainer's lead, unverified).
- [cilium#48367](https://github.com/cilium/cilium/issues/48367) (fixed by PR #48951, merged 2026-10-12; release not confirmed): CiliumEnvoyConfig rewritten every ~1 s, causing 403s. The trigger is several HTTPRoutes on the **same hostname and listener** with equal-length path prefixes. Here, the two routes on the apex domain sit on different listeners (`http` vs `https`), so it does not trigger. `kubectl get cec -A -w` should show a stable generation.

### 7.1 Measuring this node instead

Generic numbers do not transfer to a 6-vCPU virtio VM. Before and after any §4 change, run:

```bash
# pod↔pod and host↔pod on the single node: throughput, RR, CRR, 3 samples
cilium connectivity perf --other-node=false --crr --samples 3 --duration 10s --report-dir ./perf-$(date +%F)
```

For the Gateway path, compare Envoy downstream p95/p99 from the existing `cilium-envoy` scrape (PERF deep dive §2.3) over the same weekday window. Optionally, run a short load test from a LAN host against `https://192.168.50.201` with the `Host` header set (for example `oha -z 30s -c 16 -H 'Host: www.jokelab.dev'`). Keep it short and off-peak: the WAF rate limits apply.
