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
| 1 | Maintenance-window bundle: `routingMode: native`, `bpf.datapathMode: netkit`, `bpfClockProbe: true` (§4.2) | Lowest per-packet cost Cilium offers. Pod route MTU 1450 → 1500. No VXLAN device. Cheaper CT timestamps | Every pod must restart. WAF trusted-proxy IP must be checked again. Gateway-on-netkit is not proven by any reference repo | Planned window or next node rebuild |
| 2 | virtio-net multiqueue on the VM NIC (§4.3) | RX/TX softirq spread over 6 vCPUs instead of one; `fq` gets one leaf per queue | NIC hot-replug or VM reboot | With the next planned reboot |
| 3 | Cilium agent/operator Grafana dashboards (§4.1) | Visibility to prove items 1–2 (BPF map pressure, regeneration time, drops) | Bootstrap-ordering trap (see §4.1) | Any time |
| 4 | Longer L2-announcement lease timers (§4.1) | ~5× fewer Lease writes to k3s's SQLite (kine) | Agent restart (seconds) | Optional |
| 5 | `gatewayAPI.enableAlpn` (HTTP/2 from Cloudflare to Envoy) | Multiplexed edge→origin connections | Needs Cloudflare "HTTP/2 to Origin" | With SEC-01, as already planned |

Nothing in the table is a large win for human-scale traffic. Item 1 is the only
one that changes the datapath itself.

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

### 4.2 Maintenance-window bundle

Cilium's tuning guide: these "change the underlying datapath fundamentals and
therefore require Pod or even node restarts". On a single node there is nothing to
drain to, so do them **together**, once, either in a planned window or as the
first-boot configuration of the next node rebuild (preferred; backlog item 12,
3-node HA, brings one anyway).

```yaml
    routingMode: native
    ipv4NativeRoutingCIDR: 10.42.0.0/16   # k3s cluster-cidr
    autoDirectNodeRoutes: true            # nodes share the 192.168.50.0/24 L2 segment
    bpf:
      datapathMode: netkit                # L3 mode; kernel >= 6.8, eBPF host routing
      masquerade: true
      hostLegacyRouting: false
    bpfClockProbe: true                   # jiffies instead of ktime for CT timestamps
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
2. **Gateway on netkit is not proven by the references.** All three netkit users
   run Envoy Gateway, not Cilium's Gateway with the host-network Envoy and L7
   redirects. Also, netkit "is incompatible with TPROXY (`bpf.tproxy`)", which is
   off here. Test in the window and keep the rollback ready.
3. Write down `ip -4 addr show cilium_host` before the change, and compare it after
   (WAF `trusted_proxies 10.42.0.148/32`). Cilium normally restores the router IP
   from its state directory, but a rebuild or a state wipe gives a new one. If it
   changes, update both WAF ConfigMaps (the image test suite checks they match).

Runbook:

1. Push the values. Flux upgrades; `rollOutCiliumPods` restarts the agent.
2. Immediately restart every pod that is not host-network:
   `kubectl get ns -o name | cut -d/ -f2 | xargs -I{} kubectl -n {} rollout restart deploy,sts,ds`,
   then delete any leftover bare pods. Old veth pods and new netkit pods cannot run
   side by side.
3. Restart `ds/cilium-envoy` so its sockets pick up the new routes.
4. Verify: `cilium-dbg status` shows `Device Mode: netkit`, `Routing: Network:
   Native`, `Clock Source for BPF: jiffies`. `ip route` in a pod shows no `mtu 1450`.
   Smoke-test Gateway HTTPS, WAF → backend, backend → Postgres/Redis, DNS, the
   FQDN policy of `abuseipdb-sync`, and Hubble drops still arriving in Loki.
5. Rollback: revert the commit, then repeat step 2 (the same full restart is needed
   going back).

Expect several minutes of full outage. That is why the node rebuild is the better
moment.

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

The guest driver enables all queues by default. Proxmox applies the change as a NIC
hot-replug, or at the next reboot, so do it together with a planned reboot (or §4.2).
Check afterwards with `ethtool -l eth0` and `tc qdisc show dev eth0` (one `fq` per
queue under `mq`).

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
