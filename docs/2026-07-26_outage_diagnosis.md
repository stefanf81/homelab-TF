# Outage & Diagnosis — 2026-07-26 (`www.jokelab.dev`, `grafana.jokelab.dev`)

This file records the investigation and remediation performed on 2026-07-26 after both public hostnames stopped serving traffic "since today".

> Status at end of session: **cluster recovered, but the Cilium Envoy L7LB upstream ACK regression still returns HTTP 503 for all gateway traffic under every Cilium version/config tested.** This is fully reproducible, traced, and persists in the canonical pre-struggle git state. See §6 for todos.

---

## 1. Layer-by-layer findings at the start

| Layer | State | Evidence |
|---|---|---|
| Public DNS (`dig @1.1.1.1`) | ✅ healthy | All three hostnames → `84.194.170.2` (WAN IP). Cloudflare-DDNS pod logs *"A records already up to date"*, `Detected IPv4 address: 84.194.170.2` |
| TLS cert (`Certificate/taskflow-jokelab-cert`) | ✅ healthy | `Ready`, valid until `2026-10-11`, `notBefore 2026-07-13` |
| GitOps/Flux controllers | ❌ all CrashLoopBackOff or `0/1` at start | `source-controller`, `image-automation-controller`, `image-reflector-controller` CrashLoopBackOff; `helm-controller`, `kustomize-controller`, `notification-controller` `0/1 Running` with high restart counts |
| Cilium agent DaemonSet | ❌ **entirely absent** | `kubectl -n kube-system get ds` → *No resources*; only the `cilium-operator` Deployment existed; node bore taint `node.cilium.io/agent-not-ready:NoSchedule` |
| Cilium operator | ✅ Running | `cilium-operator-5bdbf7d9b4-hjx7w 1/1 Running` (kept running via Tailscale) |
| Gateway / HTTPRoutes | ✅ Accepted/Programmed/ResolvedRefs at the object level | but useless without the agent datapath |
| Taskflow pods | ✅ all `1/1 Running` | but pod→pod and host→pod reachability was broken |
| Mac (`/etc/hosts: 192.168.50.201 → jokelab.dev`) | ❌ `No route to host` 0 ms | because nothing on the LAN answered ARP for `.201` (Cilium L2-announce off) |

External / cellular traffic was also dead (router `80/443` port-forward → `192.168.50.201` had no listener), confirming a **global** outage rather than a client-only Wi-Fi / VPN isolation (guide [`archive/DuckDNS_HTTPS_Migration_Guide.md`](archive/DuckDNS_HTTPS_Migration_Guide.md) §3.3/§3.4).

---

## 2. Root cause of "outage since today"

The Flux `infra-controllers` Kustomization triggered a Cilium HelmRelease reconcile **today at 18:25Z** (helm release `cilium.v1` install, `cilium.v2` upgrade at 18:28Z — both chart `cilium@1.19.6`). After this upgrade the **`cilium` agent DaemonSet was deleted from the cluster** (`kubectl get ds -n kube-system` returned *No resources*; only the cilium-operator Deployment remained). The HelmRelease itself reported `UpgradeSucceeded`, but the agent DS — and hence the entire Cilium eBPF datapath — was gone.

Cascade:
1. Cilium eBPF on `eth0` of the K3s VM (192.168.50.55) torn down → no BPF LB, no L2-announce.
2. The Cilium LoadBalancer IP `192.168.50.201` (the ASUS router's port-forward target *and* the Mac's `/etc/hosts` target) no longer answered ARP on the LAN.
3. → Both external (WAN/cellular) and LAN clients died — `www.jokelab.dev` and `grafana.jokelab.dev` unreachable for everyone.
4. The Flux controller pods (which themselves run as pods needing Cilium networking) went CrashLoopBackOff → chicken-and-egg, cluster could not self-heal. NetworkPolicy `default-deny-all-ingress` (added today 17:27Z) and CNP `allow-gateway-to-app` (added today 18:13Z via commit `ab2ece5`/`13cbb50`) remained but were **collateral, not the cause** — Cilium's policy engine was offline anyway.

The cilium-operator log showed the flap that preceded the disappearance:
```
19:54:09  Cilium pod scheduled but not running for node; setting taint
19:54:22  Cilium pod running for node; marking accordingly
19:55:38  Cilium pod scheduled but not running for node; setting taint
```

---

## 3. Recovery actions performed

Tested/observed in chronological order:

1. **Restored the deleted `cilium` agent DaemonSet** — bypassed the broken Flux loop with a direct `helm upgrade --install cilium cilium/cilium --version 1.19.6 --reuse-values --force-conflicts --take-ownership -n kube-system`.
   - First attempt aborted on SSA conflicts (`cilium-operator.spec...readinessProbe.initialDelaySeconds` owned by `helm-controller`, `gatewayclass.spec.description` owned by `kustomize-controller`), but the cilium-agent DS was *created server-side before the abort succeeded*. So the abort was harmless to the recovery.
   - `--force-conflicts` resolved the remaining field-manager conflicts on the next pass.
2. **Restarted cilium-agent + cilium-envoy** → BPF attached to `eth0`, taint `node.cilium.io/agent-not-ready` cleared, Cilium L2-announce working (`arp .201 → bc:24:11:a8:3d:ba`), Cilium BPF LB rules for `192.168.50.201:443 → 127.0.0.1:15529 (l7-load-balancer)` programmed.
3. **All six Flux controllers recovered to `1/1 Running`** once Cilium datapath was back (no more CrashLoopBackOff). This unblocked GitOps entirely.
4. **Re-applied git HEAD's `bpf.masquerade=false`** (commit `9e3fc11`, never reconciled because Flux was down): ran `helm upgrade ... --set bpf.masquerade=false` (verified `enable-bpf-masquerade: false` in `cilium-config`).
5. **Tried Cilium 1.20.0-rc.1** (per user request):
   - `helm pull cilium/cilium --version 1.20.0-rc.1` (the stable repo `helm.cilium.io` does *not* index RCs; pulled the tarball directly).
   - First attempt failed chart rendering because the 1.20 chart added a new `envoy.nodeLocality.enabled` key absent from `--reuse-values`; reran with `--reset-then-reuse-values` and `--force-conflicts`.
   - Operator log: `error: CRD "referencegrants.gateway.networking.k8s.io" does not have version "v1"`. Cilium 1.20.0-rc.1 requires `ReferenceGrant` to be served at `v1` (only available in Gateway API v1.2+; cluster had only `v1beta1`).
   - Added a `v1` *stub* version (served=true, storage=false, schema mirrored from `v1beta1`) following the user's established pattern from commit `9ce5ac4` (which did the same for `tlsroutes`). After this, operator reconciled GatewayClass + Gateway cleanly and **Envoy loaded the TLS cert** (`cilium-dbg envoy admin certs` showed a populated `certificates`).
6. **Reverted repo to `7cc295b`** ("last known working", per user). Steps:
   - `git branch -f backup/pre-revert-20260726 HEAD` — preserved today's 16 commits in case they need to be re-examined.
   - `git reset --hard 7cc295b29f3c945b9b4225ef322c364a1812652f`.
   - `git push --force-with-lease origin main` (rewound origin/main from `35638e5` to `7cc295b`).
   - Annotated Flux controllers/GitRepository to force-reconcile. Flux cleanly applied and **downgraded Cilium chart from 1.20.0-rc.1 (helm rev 7) back to 1.19.6 (rev 8)**, set `enable-bpf-masquerade: true` (matching `7cc295b`'s release.yaml) and pruned the ReferenceGrant v1 stub (back to `v1beta1` only). All Flux Kustomizations converged to `main@sha1:7cc295b...`.

---

## 4. Residual issue: Envoy L7LB upstream ACK regression (the 503)

After full recovery and after reverting to `7cc295b`, the gateway still serves a **`503` after a 5s `upstream_cx_connect_timeout`** for every HTTPS request to `www.jokelab.dev`, `grafana.jokelab.dev`, and `/api*`. The regression is identical across **all three configurations** tested in this session:

| Cilium | `bpf.masquerade` | ReferenceGrant | Result |
|---|---|---|---|
| 1.19.6 | `true` (helm rev 8 via Flux) | `v1beta1` | 503 / 5 s |
| 1.19.6 | `false` (helm rev 6 manual) | `v1beta1` | 503 / 5 s |
| 1.20.0-rc.1 | `false` (helm rev 7 manual) | `v1beta1` + `v1` stub | TLS handshake works (cert loaded) — but upstream connect still 503 / 5 s |

### 4.1 Reproduction (definitive `cilium monitor` trace)

Pick the frontend pod's Cilium endpoint ID, fire one HTTPS request through `127.0.0.1:15529` (envoy direct) or `192.168.50.201:443` (LB), and run:

```bash
kubectl -n kube-system exec <cilium-agent-pod> -- \
  cilium-dbg monitor -t trace -v --related-to <frontend-ep-id>
```

Observed packets (every time, under every config):
```
-> endpoint 1968, identity ingress->3969 state new     … 10.42.0.148:54276 -> 10.42.0.219:8080 tcp SYN     (Envoy's upstream SYN, source identity=reserved:ingress, source IP=cilium_host)
-> stack        , identity 3969->host    state reply   … 10.42.0.219:8080 -> 10.42.0.148:54276     tcp SYN, ACK  (frontend pod SYN-ACK reaches cilium_host)
(retransmitted SYN-ACK — host never acknowledged it)
-> endpoint 1968, identity host->3969    state established … 10.42.0.148:54276 -> 10.42.0.219:8080  tcp RST   (Envoy's connect() times out after 5s, RST to clear)
```

For comparison, *separate* flows to the same pod with **source identity `host`** (e.g. kubelet/Envoy health-check probes) complete the full three-way handshake:
```
identity host->3969 … SYN → SYN, ACK → ACK → … → FIN
```

### 4.2 What this means

Cilium's L7LB Envoy (hostNetwork, listens `127.0.0.1:15529`) marks its upstream TCP connects with the special `reserved:ingress` source identity. The SYN is delivered to the backend pod (foothold in `cilium monitor`). The backend responds with SYN-ACK to `cilium_host` (`10.42.0.148`). The reverse-translation that should deliver that SYN-ACK back to Envoy's socket **does not happen** — Envoy's socket never sees a SYN-ACK, never sends the third ACK, the connect times out at 5 s and the cluster emits `upstream_cx_connect_timeout`. Meanwhile non-`ingress`-identity host connections to the same pod complete in < 1 ms.

This matches exactly what the user had already diagnosed earlier today in commit `a5ce9fb`:

> "Cilium 1.19.6 has a datapath regression that breaks Envoy upstream connections in the Gateway API L7 proxy path. Envoy (running in host network at 127.0.0.1) cannot establish TCP connections to backend pods — SYN reaches pod, SYN-ACK returns, but ACK never completes, causing upstream_cx_connect_timeout and 503 Service Unavailable."

That commit's note also lists options that **did not** cure it: `bpf.hostRouting`, `EnableEndpointRoutes`, `enable-bpf-tproxy`. My session adds to that list: `--reset-then-reuse-values`, Cilium `1.20.0-rc.1`, `bpf.masquerade=false` — none fixed the reverse delivery. Reverting the repo to `7cc295b`'s pre-struggle config and letting Flux cleanly converge to it also did **not** fix it.

### 4.3 Things that worked and isolated the issue

- ✅ `host -> pod IP` direct (e.g. `10.42.0.237:8080` → 401; `10.42.0.219:8080` → 200) from a hostNetwork pod (`nicolaka/netshoot`) — sub-3ms. So the Cilium datapath and identity cache are functional for normal host-originated traffic. The breakage is specific to Envoy's *L7LB-tagged* source identity.
- ✅ L2 announce + Cilium LB programming: `192.168.50.201:443 → 127.0.0.1:15529` is present in `cilium bpf lb list`.
- ✅ Under `1.20.0-rc.1` (after the ReferenceGrant v1 stub), Envoy's TLS Secret SDS delivered and `cilium-dbg envoy admin certs` shows the Let's Encrypt cert chain. So the 503 under 1.20 was *after* a successful TLS handshake (real HTTP 503), confirming this is purely an Envoy-upstream problem.
- ❌ Todo: under 1.19.6 in the current session, the same SDS Secret xDS stream also succeeded pre-today but now is again unverified (we didn't retest SDS specifically after the 1.19.6 downgrade — retest if needed).

### 4.4 Likely root cause (hypothesis)

Cilium's `bpf_sock_addr` / `bpf_sock_ops` cgroup BPF programs, attached at root cgroup by the cilium-agent, handle reverse NAT for socket-LB (Envoy L7LB) traffic. The trace proves the *response* path back to Envoy's socket isn't being applied for packets whose original SYN carried source identity `reserved:ingress`. Whether this is a Cilium 1.19.6 bug (the same code path that produced the user's earlier commit `a5ce9fb` "1.16.1 was last known working") or a side-effect of the cascade-and-restore (stale conntrack or BPF map state that cycling the agent does not clear), GitOps reconciliation alone cannot fix — the cluster was running cleanly pre-today on the same helm/chart/values.

---

## 5. State at end of session

- Git:
  - Local HEAD: `7cc295b chore: automated TaskFlow image update`.
  - Remote `origin/main`: rewound from `35638e5` → `7cc295b` via `git push --force-with-lease`.
  - Backup branch `backup/pre-revert-20260726` points at `9e3fc11` (today's pre-revert HEAD) — preserves all 16 discarded commits (`a5ce9fb`, `022be3e`, `9e3fc11`, `4514b81`, `13cbb50`, `ab2ece5`, `caad89e`, `70991fc`, `346c521`, `65140d5`, `5de5ef4`, `2f3e0df`, `597abdd`, `23b014b`, `5e5d4ba`, `62cc4df`) for forensics.
- Cluster:
  - Cilium helm release `cilium` rev `8`, chart `cilium-1.19.6`, `enable-bpf-masquerade: true`, `bpf.hostRouting: false`, `devices: eth0`, `gatewayAPI.enabled: true`, `l2announcements.enabled: true` (matches `7cc295b`'s `gitops/infrastructure/controllers/cilium/release.yaml`).
  - `cilium` and `cilium-envoy` DaemonSets both `1/1 Ready`, node untainted.
  - ReferenceGrant CRD at `v1beta1` (the `v1` stub added during testing was pruned by Flux's standard-install apply).
  - All Flux `Kustomization`s converged to `main@sha1:7cc295b...` (`taskflow-app` was still `Reconciliation in progress` at end of session; `policy-reporter` blocked pending that dependency).
  - Flux `<helmrelease cilium>` reports `Ready=True UpgradeSucceeded` for rev 8.
- Untracked support files left at the repo root: none of mine left (the temporary `cilium-1.20.0-rc.1.tgz` was removed).
- **Symptom**: a request to `https://192.168.50.201/...` from a host-network pod still returns `503 Service Unavailable` after 5 s upstream connect timeout — both `www.jokelab.dev` and `grafana.jokelab.dev`. Mac clients using `/etc/hosts` override return `No route to host` 0–3 ms (this is the **separate** Mac-specific LAN issue, guide §3.3/§3.4, not yet investigated as user deferred this until the cluster serves).

---

## 6. Recommended next steps (for the user's continued debugging)

1. **Verify the residual after `taskflow-app` fully reconciles.** Re-run:
   ```
   kubectl get pods -n kube-system -l 'k8s-app in (cilium, cilium-envoy)'
   kubectl -n taskflow get ciliumnetworkpolicy allow-gateway-to-app -o yaml
   kubectl -n kube-system exec <cilium-agent> -- \
     curl -sk -m 6 -o /dev/null -w '%{http_code} %{time_total}\n' \
     -H 'Host: www.jokelab.dev' https://192.168.50.201/
   ```
2. **Hypothesis-1 (BPF/conntrack leftover state after the cascade):** try a deeper datapath reset:
   ```
   kubectl -n kube-system delete pod -l k8s-app=cilium   # force cleanCiliumState (NET_ADMIN already in chart)
   ```
   If still 503, try a real `cilium-dbg cleanup --all-state` from inside the agent pod (cleans conntrack + BPF maps), then restart. If still failing, a **Proxmox VM reboot** would clear all kernel BPF state in one shot — likely worth trying if upstream ACK still fails after a clean restart.
3. **Hypothesis-2 (Cilium 1.19.6 datapath bug that 7cc295b state doesn't avoid):** the user's commit `a5ce9fb` notes 1.16.1 was last-known-working. The 1.16.1 downgrade hit "Gateway endpoint errors" in commit `022be3e`, but in the cluster's now-clean state that may not recur — worth a clean retry of pinning `release.yaml` to `1.16.1` with the existing TLSRoute `v1alpha2` patch (commits `9ce5ac4` / ea8ee06).
4. **Hypothesis-3 (single-node + EnvoyhostNetwork-on-eth0 + Tailscale routing-loop artefact):** the user already narrowed `devices: eth0` (exclude `tailscale0`) per commit `43588c7`. Consider testing whether disabling Tailscale on the K3s VM briefly (so it can't affect the routing table during a single request) changes the trace pattern.
5. **Re-enable the Mac `/etc/hosts` testing only after the gateway serves a 200/302 internally**, then resolve the `No route to host` 0 ms (guide [`archive/DuckDNS_HTTPS_Migration_Guide.md`](archive/DuckDNS_HTTPS_Migration_Guide.md) §3.3 / §3.4).
6. **Keep `backup/pre-revert-20260726` for at least one month** — it preserves today's debugging history; don't delete.
7. **If recovery is urgent and the user accepts downtime:** consider bypassing the Envoy gateway entirely and exposing the frontend via a NodePort or a Cilium L4 (non-L7) LoadBalancer service as a temporary bridge while the L7LB regression is worked out.

---

## 7. Key commands used / reproducible

```bash
# Verify cluster state
helm history cilium -n kube-system
kubectl -n kube-system get ds,pods -l 'k8s-app in (cilium, cilium-envoy)'
kubectl get node ubuntu -o jsonpath='{.spec.taints}'
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-bpf-masquerade}'

# Reproduce the residual 503
kubectl -n kube-system exec <cilium-agent-pod> -- \
  cilium-dbg envoy admin clusters | grep -E ':8080::10.42.0.(219|237):8080::cx_(active|connect_fail|connect_timeout)'

# Capture the failing handshake (reserved:ingress source)
FEP=$(kubectl -n kube-system exec <cilium-agent-pod> -- \
       cilium-dbg endpoint list | awk '/10.42.0.219/ {print $1}')
kubectl -n kube-system exec <cilium-agent-pod> -- \
  cilium-dbg monitor -t trace -v --related-to $FEP
```
