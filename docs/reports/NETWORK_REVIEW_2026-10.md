# Network Configuration Review — Edge to Pod (October 2026)

Scope: every network setting on the request path and the DNS path **above** the
Cilium datapath. That covers Cloudflare → Gateway, the Envoy listener and route
settings Cilium generates, the WAF (Caddy) proxy hop, the application servers'
keep-alive, CoreDNS and pod DNS, node sysctls and the Proxmox NIC. The datapath
itself (routing mode, netkit, BBR, multiqueue, L2 announcements) is covered in
`CILIUM_REVIEW_2026-10.md` and `PERF_DEEP_DIVE_2026-10.md` §4. Their verdicts are
not repeated here.

Static review of this repository at `7f1c70c` (2026-10-30). Nothing was run
against the live cluster. Items marked **verify** depend on live state or on the
separate frontend/backend repositories.

Compared against:

| Source | Version read |
|---|---|
| onedr0p/home-ops | `012c5b9` (2026-10-30) |
| bjw-s-labs/home-ops | `7ae2101` (2026-10-29) |
| buroa/k8s-gitops | `09a35cc` (2026-10-30) |
| Cilium source (operator Gateway translation, chart) | `v1.20.4` (`beb276d`) |
| oauth2-proxy source (`pkg/upstream/http.go`) | `master` (`bea3f04`) |
| Go `net/http` Transport retry rules (`transport.go`) | `master` |
| Official docs | Caddy `reverse_proxy` and global options, Envoy timeouts FAQ and `RouteAction`, Cloudflare connection limits, CoreDNS `cache`/`autopath`/`kubernetes`, Tomcat 11 HTTP connector, Kubernetes DNS for Pods, oauth2-proxy flags, bpg Proxmox provider |

All three reference repositories use Envoy Gateway, Talos and bare metal, so
their gateway policies are translated to this setup rather than copied.

## 0. Summary

**The datapath is well tuned. The remaining issues sit in the layers above it:
timeouts that are not ordered correctly between hops, an implicit Envoy default,
and CoreDNS defaults.** None of them limits throughput. They cause occasional
502/504 responses, cut long responses, and generate DNS chatter.

| # | Change | Gain | Disruption | § |
|---|---|---|---|---|
| 1 | `keepalive 50s` on both WAF upstreams | Removes a race that turns a POST/PUT/PATCH into a 502 when it lands on a connection the backend is closing. Most likely at low traffic | WAF rollout via Reloader (surge, seconds) | 2.1 |
| 2 | `timeouts.request: "0s"` on the Grafana and Hubble UI routes | Removes Envoy's implicit **15 s** route timeout: no more 504s on slow Grafana queries, and the Hubble flow stream is no longer cut | None (Envoy config push) | 2.2 |
| 3 | Confirm the SSE endpoint sends data at least every ~60 s (**verify**) | The 31-minute route timeout only holds if Cloudflare (125 s read timeout) and Envoy (300 s stream idle) see data | Check only; app repo if missing | 2.3 |
| 4 | CoreDNS: `prefetch`/`serve_stale`/`servfail 0`, `pods verified` + `autopath @kubernetes`, error logging (PERF-08 plus autopath) | Hot names refreshed before expiry, answers survive an upstream outage, `ndots:5` search walks collapse to one round trip | CoreDNS surge rollout | 2.4 |
| 5 | `net.ipv4.tcp_mtu_probing = 1` on the node | Recovers from PMTU black holes on the uplink path to Cloudflare | sysctl, no restart | 2.5 |
| 6 | Correct `docs/PERFORMANCE.md` §3.3 | It claimed the Gateway multiplexes h2c to the backend. Gateway traffic never reaches the backend directly | — (done in this commit) | 2.7 |

Earlier network recommendations that are still open are listed in §3. The
suggested order is in §4.

**Status (2026-10-30, later the same day):** items 1, 2 and 4 are applied in Git.
They were validated with `caddy validate` and `tests/run-tests.sh` on a Caddy
2.11.7 build with the image's two plugins, a CoreDNS 1.15.0 start-up on the
rendered chart 1.49.0 Corefile, and `scripts/validate-gitops.sh`. Items 3 and 5
were still open at that point. From §3, the Cilium agent and Hubble dashboards,
the longer L2-announcement lease timers and the ECDSA key on the current
certificate are applied as well.

**Follow-up checks (2026-10-30):**

- **Item 3 is closed, nothing to change.** The backend (`taskflow-enterprise`)
  sends a `: keepalive` comment every 20 s (`app.sse.heartbeat-interval-ms=20000`),
  sets `Cache-Control: no-cache` and `X-Accel-Buffering: no`, and its 30-minute
  emitter timeout sits inside the route's 31 minutes.
- **The frontend's nginx** uses `keepalive_timeout 65`, confirming the §1.1 row.
- **Cloudflare already caches the hashed bundles** (`cf-cache-status: MISS`, then
  `HIT`; HTML is `DYNAMIC`), so no cache rule is needed. What remains is Smart
  Tiered Cache (§2.6).
- **HTTP/2 to the origin does not need SEC-01** (§2.6).
- Item 5 is still open.

## 1. The request path and every timer on it

```
visitor ─▶ Cloudflare ─▶ router :443 ─▶ 192.168.50.201 ─▶ cilium-envoy (hostNetwork)
        ─▶ taskflow-{backend,frontend}-waf (Caddy + Coraza) ─▶ backend (Tomcat) | frontend (nginx)
        ─▶ postgres / redis / jaeger
```

### 1.1 Connection reuse (idle timers)

A pooled connection is safe only if the side that **reuses** it gives up before
the side that **closes** it. Otherwise the client sometimes sends a request into
a connection the server has just closed.

| Hop | Reusing side gives up after | Closing side gives up after | Ordered correctly? |
|---|---|---|---|
| Cloudflare → Envoy | 900 s (Cloudflare "Proxy idle timeout") | 1 h: Cilium sets no HCM `idle_timeout`, so Envoy's default applies (`envoy_http_connection_manager.go`) | ✅ |
| Envoy → WAF | 60 s (`proxy-idle-timeout-seconds`, chart `envoy.idleTimeoutDurationSeconds`) | 5 min (Caddy server `idle` default) | ✅ |
| WAF → backend | **2 min** (Caddy `keepalive` default) | **60 s** (`SERVER_TOMCAT_KEEP_ALIVE_TIMEOUT`, `configmap.yaml:55`) | ❌ §2.1 |
| WAF → frontend | **2 min** (Caddy default) | 65 s (`keepalive_timeout 65` in the frontend repo's `nginx.conf`) | ❌ §2.1 |
| backend → Postgres / Redis | Hikari / Lettuce pools | Neither server closes idle clients | ✅ |

### 1.2 Request and stream timers

| Timer | Value | Applies to |
|---|---|---|
| Cloudflare proxy read timeout | **125 s** (HTTP 524; configurable on Enterprise only) | Waiting for the origin. Cloudflare does not document how it treats a streaming response that has already started |
| Envoy route `timeout` when an HTTPRoute sets none | **15 s** (Envoy default; Cilium only sets `MaxStreamDuration: 0`) | `monitoring-routes` (Grafana), `hubble-ui`, `policy-reporter-ui`, and the taskflow `/` rule. §2.2 |
| Envoy HCM `stream_idle_timeout` | 300 s, from the **operator** flag `proxy-stream-idle-timeout-seconds` | Every Gateway stream, including the SSE route. §2.3 |
| taskflow `/api` | 10 s (`backendRequest`) | Fail-fast API calls. Fine |
| taskflow `/api/v1/appointments/events` | 31 min (`request` + `backendRequest`) | SSE. Only effective with a heartbeat, §2.3 |
| oauth2-proxy `--upstream-timeout` | 30 s, applied as `ResponseHeaderTimeout` | Response **headers** only; streaming bodies are not cut |
| Caddy server timeouts | `read_header` 1 min; no `write` or `read_body` timeout | ✅ No write timeout is the right choice for SSE |
| Caddy flushing | `text/event-stream` is flushed immediately | ✅ No `flush_interval` needed |

## 2. Findings

### 2.1 WAF → app: Caddy keeps idle connections longer than the apps do (new)

**Evidence.** Neither `reverse_proxy` block sets `keepalive`
(`backend-waf.yaml:131-139`, `frontend-waf.yaml`), so Caddy keeps idle upstream
connections for its default `2m`. Tomcat closes an idle keep-alive connection
after 60 s (`SERVER_TOMCAT_KEEP_ALIVE_TIMEOUT: "60000"`). nginx's stock
`nginx.conf` uses `keepalive_timeout 65`.

**Why it matters.** Go's Transport (which Caddy uses) notices most server-side
closes in its background read loop and drops the connection from the pool. The
gap is the moment when Tomcat's FIN and a new request cross. Go then retries the
request only if it is replayable. Per `transport.go`, that means `GET`, `HEAD`,
`OPTIONS`, `TRACE` or a request with an `Idempotency-Key` header ("Don't retry
non-idempotent requests"). A booking `POST`, `PUT` or `PATCH` that hits the
window comes back to the visitor as a 502, and Caddy's error log shows `EOF` or
`connection reset by peer`. The window opens every time a connection has been
idle for exactly 60 s, so it is **more** likely at homelab traffic levels than
under load. This is the classic "upstream drops idle connections sooner than the
proxy" pattern (iximiuz, "Reverse proxy, HTTP keep-alive timeout, and sporadic
HTTP 502s"). All three reference gateways avoid it the same way: upstream idle
timeout well below the backends' keep-alive (`connectionIdleTimeout: 4s` at
onedr0p and buroa, `15s` at bjw-s), plus a `reset-before-request` retry.
HTTPRoute `retry` is not in the Gateway API v1.6.3 standard channel installed
here, and the race is at the Caddy hop anyway. So the ordering fix is the lever.

**Change** (the image test suite renders these ConfigMaps with a real Caddy, so
`gitops/images/taskflow-caddy-coraza/tests/run-tests.sh` validates the syntax):

```caddyfile
# backend-waf.yaml
            reverse_proxy http://backend.taskflow.svc.cluster.local:8080 {
                transport http {
                    versions 1.1
                    # Retire idle connections before Tomcat does
                    # (server.tomcat.keep-alive-timeout = 60s, configmap.yaml).
                    keepalive 50s
                }
                header_up Host {http.request.host}
                ...

# frontend-waf.yaml
            reverse_proxy http://frontend.taskflow.svc.cluster.local:8080 {
                transport http {
                    # Below nginx's keepalive_timeout (65s in the stock nginx.conf).
                    keepalive 50s
                }
                header_up Host {http.request.host}
                ...
```

Fixing it on the Caddy side covers both upstreams in one place. Raising Tomcat's
timeout above 2 min would fix only the backend. Optionally, raise
`SERVER_TOMCAT_MAX_KEEP_ALIVE_REQUESTS` from 100 to 1000. Caddy is the only
client, so the cap only forces reconnects; Tomcat announces the close with
`Connection: close`, so the cap itself does not cause the race.

**Verify.** Compare the 502 count before and after
(`loki_process_custom_taskflow_waf_requests_total` is derived by Alloy from the
Caddy access logs):

```promql
sum by (application, method) (increase(loki_process_custom_taskflow_waf_requests_total{status="502"}[7d]))
```

```logql
{job="coraza-waf", container="waf"} |~ "EOF|connection reset by peer"
```

### 2.2 Envoy's implicit 15 s route timeout on the admin UIs (new)

**Evidence.** In Cilium v1.20.4, `timeoutMutation`
(`operator/pkg/model/translation/envoy_virtual_host.go`) sets only
`MaxStreamDuration: 0` when an HTTPRoute rule has no `timeouts`, and leaves
`RouteAction.timeout` unset. Envoy: "If not specified, the default is 15s". The
timeout runs from the end of the request until the upstream response has been
"completely processed". The Gateway API leaves the unset case
implementation-specific. `httproute.yaml` already notes this for SSE, but the
other routes never got a timeout:

| Route | Effect of 15 s |
|---|---|
| `monitoring-routes` (Grafana) | Panel queries longer than 15 s return 504 `upstream request timeout`, although Grafana's own data-proxy timeout allows 30 s |
| `hubble-ui` | The flow view is a long-lived streaming response through oauth2-proxy. Envoy ends it every 15 s and the UI re-subscribes (**verify**: periodic "reconnecting" or a stalling flow list). oauth2-proxy's 30 s `upstream-timeout` is header-only, so it is not the limit |
| `policy-reporter-ui` | Plain requests; 15 s is fine |
| taskflow `/` (frontend) | Static files; 15 s is fine |

**Change.** `"0s"` disables the route timeout. The installed CRD says the zero
duration "SHOULD disable the timeout completely", and Cilium maps it to Envoy
`timeout: 0`. Requests stay bounded: Envoy's 300 s stream idle timeout still
ends idle streams, and Grafana's data proxy still stops queries at 30 s.

```yaml
# gitops/monitoring/platform/routes.yaml and gitops/platform/hubble-ui/route.yaml
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      # No route timeout: Envoy's implicit 15s cut slow Grafana queries and
      # streaming responses. Envoy's 300s stream idle timeout still applies.
      timeouts:
        request: "0s"
      backendRefs: ...
```

**Verify.** The counter should stop growing for the two clusters (Cilium names
them `<namespace>:<service>:<port>`):

```promql
sum by (envoy_cluster_name) (increase(envoy_cluster_upstream_rq_timeout[7d]))
```

### 2.3 The SSE stream depends on a heartbeat (verified: 20 s, see the status note in §0)

The events route allows 31 minutes, but two idle timers sit in front of it. Both
are satisfied as long as the backend writes something (an event or a `:`
comment line) regularly:

- **Cloudflare:** 125 s proxy read timeout (524). Cloudflare does not document
  how it applies to a response that is already streaming, so the safe
  assumption is "send data more often than that".
- **Envoy:** a 300 s stream idle timeout on every Gateway listener.

Check in the backend repository that the emitter sends a heartbeat. A 30–60 s
interval is common. On the live site, Caddy's access-log `duration` for
`/api/v1/appointments/events` shows the truth: streams that end at ~125 s are
being cut by Cloudflare, and streams that end at ~300 s by Envoy. EventSource
reconnects automatically, so this costs reconnects and missed events during the
gap, not an outage.

**Gotcha if you ever want to raise Envoy's limit instead:** the chart value
`envoy.streamIdleTimeoutDurationSeconds` becomes the agent's
`http-stream-idle-timeout`, which is used for L7-policy listeners. The Gateway
listeners take the **operator** flag `proxy-stream-idle-timeout-seconds`
(default 300, `operator/pkg/ciliumenvoyconfig/cell.go`), which the chart does
not template. It would have to go in through `extraConfig`. A heartbeat is the
better fix, because Cloudflare's limit cannot be raised on this plan.

### 2.4 CoreDNS: PERF-08 is still open; add autopath

**Today:** `cache 30`, `pods insecure`, no `autopath`, no `log`
(`coredns/release.yaml`).

| Setting | Here | onedr0p | bjw-s | buroa | CoreDNS docs |
|---|---|---|---|---|---|
| `cache` | `30` (max TTL 30 s) | `prefetch 20`, `serve_stale`, `servfail 0` | `prefetch 20`, `serve_stale` | as onedr0p | `serve_stale` default: up to 1 h stale, refresh `immediate`. `servfail 0` disables SERVFAIL caching (default 5 s) |
| `kubernetes` pods | `insecure` | `verified` | `verified` | `verified` | `insecure` exists "for backward compatibility with kube-dns". `verified` "requires substantially more memory … since it will maintain a watch on all pods" (tens of MiB at most for a cluster this size) |
| `autopath @kubernetes` | — | ✓ | — | ✓ | Requires `pods verified`. Exports `coredns_autopath_success_total` |
| `log { class error }` | — | ✓ | ✓ | ✓ | — |
| `forward` | `. /etc/resolv.conf` | same | same | same | — |

**Why autopath matters here.** Pods get `options ndots:5` and the search list
`<ns>.svc.cluster.local svc.cluster.local cluster.local` plus the node's own
domain. A name with fewer than five dots walks the search list first, and every
attempt is an A and an AAAA query. `api.cloudflare.com` from `cloudflare-ddns`
or `abuseipdb-sync`, `ghcr.io` from Flux and Renovate, and
`acme-v02.api.letsencrypt.org` from cert-manager each cost up to four rounds of
NXDOMAIN before the real answer. So does the WAFs' own upstream
`backend.taskflow.svc.cluster.local` (four dots), on every new upstream
connection. With autopath, CoreDNS answers the first, namespace-suffixed query
with a CNAME to the final answer: one round trip instead of up to five.
Renovate and the Flux source/image controllers are the heaviest external
resolvers on this node.

**Change** (plugin order in the list is cosmetic; CoreDNS runs plugins in its
compiled order):

```yaml
          - name: kubernetes
            parameters: cluster.local in-addr.arpa ip6.arpa
            configBlock: |-
              pods verified
              fallthrough in-addr.arpa ip6.arpa
          - name: autopath
            parameters: "@kubernetes"
          - name: cache
            configBlock: |-
              prefetch 20
              serve_stale
              servfail 0
          - name: log
            configBlock: |-
              class error
          # unchanged: errors, health (lameduck 10s), ready, hosts, prometheus,
          # loop, reload, loadbalance, forward
```

Dropping the `30` matches the references: answers are then cached for their own
TTL (capped at 3600 s, or 1800 s for denials). The hairpin `hosts` entries carry
their own `ttl 60`, and cluster names use the kubernetes plugin's 5 s, so
nothing local becomes stickier. The surge rollout (`maxSurge: 1`,
`maxUnavailable: 0`) keeps DNS up during the change.

**Caveats.**

- **FQDN policy.** autopath answers `abuseipdb-sync` with a CNAME chain. Cilium's
  DNS proxy should associate the IPs with `api.abuseipdb.com`, but test it: the
  next sync must succeed and
  `hubble observe -n abuseipdb --verdict DROPPED` must stay empty.
- **Namespace guess.** The docs warn autopath "can derive the wrong namespace"
  when a pod IP is reused before the watch updates. The result is a normal
  search walk, not a wrong answer.
- **Negative answers.** When the final answer is NXDOMAIN, the client still walks
  the whole list. No gain there, no loss either.

**Also verify the upstreams.** `forward . /etc/resolv.conf` uses the resolv.conf
k3s hands to `dnsPolicy: Default` pods. On a systemd-resolved host that is
`/run/systemd/resolve/resolv.conf`, which lists the DNS servers of every link.
On the node, run `cat /run/systemd/resolve/resolv.conf`. If it contains
`100.100.100.100` (Tailscale MagicDNS) or anything else a pod cannot reach,
replace the `forward` parameters with explicit LAN/public resolvers.

**Verify.**

```promql
# share of NXDOMAIN answers (search-path walks), before vs after
sum(rate(coredns_dns_responses_total{rcode="NXDOMAIN"}[1h])) / sum(rate(coredns_dns_responses_total[1h]))
# cache hit ratio
sum(rate(coredns_cache_hits_total[1h])) / (sum(rate(coredns_cache_hits_total[1h])) + sum(rate(coredns_cache_misses_total[1h])))
sum(rate(coredns_autopath_success_total[1h]))
# memory headroom after `pods verified` (limit 170Mi)
max_over_time(container_memory_working_set_bytes{namespace="kube-system", container="coredns"}[1d])
```

### 2.5 Node and VM

**Sysctls.** The Cilium agent already sets `default_qdisc=fq`,
`tcp_congestion_control=bbr`, `tcp_slow_start_after_idle=0` and a 4096 backlog
(PERF-03). The reference repos set the same values in Talos, plus the following:

| Sysctl (references) | Transfers here? |
|---|---|
| `net.ipv4.tcp_mtu_probing: 1` (all three) | **Yes.** Envoy talks to Cloudflare from the host namespace, over the home uplink. If an ICMP "fragmentation needed" message is dropped on the way (common with PPPoE/DS-Lite links), probing lets the connection recover instead of stalling. It only activates after a black hole is detected |
| `net.ipv4.tcp_notsent_lowat: 131072` (all three) | Optional. It lowers send-buffer latency for HTTP/2 multiplexing, and Envoy → Cloudflare is HTTP/1.1 until `enableAlpn` (§3) |
| `rmem_max`/`wmem_max` 64 MiB, `tcp_rmem`/`tcp_wmem` | No. Sized for 10 GbE and QUIC; a home uplink's bandwidth-delay product is far smaller |
| `somaxconn` 65535, `netdev_max_backlog` 50000 | No. The agent's 4096 is ample at this connection rate |
| `neigh.default.gc_thresh*` | No. Needed for large L2 segments with many neighbours |
| `tcp_fastopen: 3` | No. Cloudflare reuses origin connections for up to 900 s, so saving one RTT on SYN does not matter |

```yaml
# modules/proxmox/main.tf, /etc/sysctl.d/99-kubernetes.conf in the cloud-init snippet
      # PMTU black-hole recovery for host-namespace sockets (Envoy -> Cloudflare).
      net.ipv4.tcp_mtu_probing = 1
```

The snippet only reaches new nodes (REL-00). On the running node:
`echo 'net.ipv4.tcp_mtu_probing = 1' | sudo tee /etc/sysctl.d/90-network.conf && sudo sysctl --system`.
The existing `net.bridge.bridge-nf-call-*` lines are harmless leftovers: with
Cilium there is no Linux bridge on the pod path.

**Proxmox NIC.** virtio (provider default) ✅. Proxmox firewall off (provider
default `false`), which avoids the extra `fwbr` bridge and veth pair per NIC ✅.
Multiqueue is still unset; see `CILIUM_REVIEW_2026-10.md` §4.3. Note that Proxmox
applies a `queues` change to a running VM as a NIC hot-replug, which means a
brief network outage on a single-node cluster.

### 2.6 Edge: TLS, HTTP/2, compression

- **ECDSA certificate.** `certificate.yaml` sets no `privateKey`, so the key is
  RSA-2048. All three references use ECDSA. REL-05 plans the switch together with
  DNS-01 and a wildcard. It can also be done on its own now
  (`privateKey: {algorithm: ECDSA, size: 256}`; cert-manager re-issues when the
  stored key no longer matches the spec). The gain is small, though: Cloudflare
  reuses origin connections for up to 900 s, so full handshakes are rare.
- **HTTP/2 to the origin.** Cloudflare's "HTTP/2 to Origin" is on by default on
  every plan (up to 200 streams per connection) and falls back to HTTP/1.1
  because Envoy advertises no ALPN. `gatewayAPI.enableAlpn: true` alone switches
  it, independent of SEC-01. The flag also turns on `appProtocol` handling, but
  Cilium 1.20.4 only switches a backend to HTTP/2 for `kubernetes.io/h2c`
  (`envoy_cluster.go`), and no route backend uses that, so Envoy → backends
  stays HTTP/1.1. Small gain: Cloudflare already reuses HTTP/1.1 connections.
  The references all advertise `h2, http/1.1`.
- **Smart Tiered Cache** (free, dashboard: Caching → Tiered Cache → Smart).
  Each Cloudflare data center currently fetches every bundle from the origin
  once; with tiered cache only one upper-tier location does. This is the
  largest remaining edge gain.
- **Compression.** The references compress at the gateway (Envoy Gateway
  `compressor`: zstd, brotli, gzip). Cilium's Gateway has no compression filter,
  and none is needed: the backend compresses responses of 1 KiB and larger
  (`SERVER_COMPRESSION_*`), and the frontend's nginx serves precompressed Brotli and gzip files.
  Cloudflare re-encodes for visitors anyway. Spring's MIME list correctly leaves
  out `text/event-stream`: compressing SSE would buffer events.
- **Client IP chain.** Envoy appends the Cloudflare edge address
  (`use_remote_address: true`). Caddy walks X-Forwarded-For past the Cloudflare
  ranges and `cilium_host`, and Tomcat reads the validated `X-Real-IP` ✅.

### 2.7 Considered and not recommended

| Idea | Why not |
|---|---|
| h2c from the WAF to the backend (the Service already says `kubernetes.io/h2c`) | One pooled client at human request rates gains nothing from multiplexing. HTTP/1.1 keeps SSE and Coraza body handling simple |
| Caddy `lb_try_duration` | One replica behind a ClusterIP. Dial failures only happen while the backend is down, which takes longer than a retry window to fix |
| `encode` in Caddy | The apps already compress (§2.6) |
| NodeLocal DNSCache | One node, and CoreDNS is already local. It would add a hop and a DaemonSet for no gain; autopath plus prefetch addresses the real cost |
| Raising `envoy.streamIdleTimeoutDurationSeconds` for SSE | It does not reach Gateway listeners (§2.3) |
| HTTPRoute `retry` | Not in the v1.6.3 standard channel; would need the experimental CRDs |

**Documentation drift** (fixed in this commit): `docs/PERFORMANCE.md` §3.3 said
the backend Service's `appProtocol: kubernetes.io/h2c` makes "Cilium Gateway
multiplex to the backend". The Gateway routes to the WAFs, the WAF pins
`versions 1.1`, and `gatewayAPI.enableAppProtocol` is off. The `appProtocol`
only matters if a route ever targets `backend` directly (`backend.yaml:267-271`
says so correctly).

## 3. Earlier network recommendations: status in Git

| Item | Source | Status at `7f1c70c` |
|---|---|---|
| Disable k3s kube-proxy | PERF-01 | ✅ `--disable-kube-proxy` in the Terraform install line. Live node: **verify** with `sudo iptables-save \| grep -c KUBE` (expect 0) |
| `rollOutCiliumPods`, Envoy resources, BBR | PERF-03 | ✅ Applied |
| Scrape the Gateway's Envoy | PERF deep dive §2.1 | ✅ `cilium-envoy` VMServiceScrape |
| CoreDNS cache block, `pods verified` | PERF-08 | ❌ Open; §2.4 extends it with autopath |
| ECDSA, DNS-01, wildcard certificate | REL-05, PERF-09 | ❌ Open (HTTP-01 issuers, RSA key) |
| Cloudflare Tunnel; then `enableAlpn` | SEC-01 | ❌ Open (router port-forward) |
| Native routing + `bpfClockProbe` | Cilium review 1a | ❌ Open (planned window) |
| virtio-net multiqueue | Cilium review #2 | ❌ Open (`queues` unset) |
| Cilium agent/operator dashboards | Cilium review #3 | ❌ Open (none in `monitoring/app/dashboards/`) |
| Longer L2-announcement lease timers | Cilium review #4 | ❌ Open |
| L2 interface regex `eno*`/`ens*`; Gateway IP in its own pool | Backlog #10 | ❌ Open (`^eth`/`^enp`; `.201` inside the shared `.200–.250` pool) |

## 4. Order of work

1. **No restarts, any time:** route timeouts (§2.2). Check the SSE heartbeat
   (§2.3) and the CoreDNS upstreams (§2.4).
2. **One PR, rolling restarts:** WAF `keepalive 50s` (§2.1; Reloader rolls both
   WAFs) and the CoreDNS block (§2.4). Take the Prometheus/Loki baselines first,
   compare after a week.
3. **Next node maintenance:** `tcp_mtu_probing` (§2.5), together with the
   multiqueue NIC and native routing from the Cilium review.
4. **With REL-05 / SEC-01:** ECDSA wildcard certificate, Cloudflare Tunnel,
   `enableAlpn`.

## 5. Sources

- Caddy `reverse_proxy`: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy (`keepalive` default `2m`, `versions` default `1.1 2`, retries disabled by default and "only `GET` requests are retried", `text/event-stream` flushed immediately)
- Caddy global options: https://caddyserver.com/docs/caddyfile/options (server `idle` default 5 min, `read_header` 1 min, no `write` timeout)
- Envoy timeouts FAQ: https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts (HCM idle timeout default 1 h, stream idle default 5 min)
- Envoy `RouteAction.timeout`: https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto ("If not specified, the default is 15s")
- Cloudflare connection limits: https://developers.cloudflare.com/fundamentals/reference/connection-limits/ (proxy idle 900 s, proxy read 125 s)
- CoreDNS: https://coredns.io/plugins/cache/, https://coredns.io/plugins/autopath/, https://coredns.io/plugins/kubernetes/
- Kubernetes DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ (`ndots:5` default)
- Tomcat 11 HTTP connector: https://tomcat.apache.org/tomcat-11.0-doc/config/http.html (`keepAliveTimeout`, `maxKeepAliveRequests` default 100)
- oauth2-proxy flags: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview (`--upstream-timeout` 30 s); source `pkg/upstream/http.go` (`transport.ResponseHeaderTimeout`)
- Go `net/http` `transport.go`, `shouldRetryRequest` (no retry of non-idempotent requests)
- iximiuz, "Reverse proxy, HTTP keep-alive timeout, and sporadic HTTP 502s": https://iximiuz.com/en/posts/reverse-proxy-http-keep-alive-and-502s/
- bpg Proxmox provider, `network_device` (`firewall` default `false`, `queues`): https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md
- Cilium v1.20.4: `operator/pkg/model/translation/{envoy_http_connection_manager,envoy_virtual_host,envoy_listener,envoy_cluster_mutator}.go`, `operator/pkg/ciliumenvoyconfig/cell.go`, `operator/pkg/gateway-api/cell.go`, `install/kubernetes/cilium/{values.yaml,templates/cilium-configmap.yaml}`
- Reference repositories: `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`; Envoy Gateway `ClientTrafficPolicy`/`BackendTrafficPolicy` (onedr0p `network/envoy-gateway/app/envoy.yaml`, bjw-s `network/envoy-gateway/gateway/shared/`, buroa `networking/envoy-gateway/proxy/envoy.yaml`); Talos sysctls in `talos/cluster.yaml.j2`; onedr0p `network/cloudflare-tunnel/app/helmrelease.yaml`
