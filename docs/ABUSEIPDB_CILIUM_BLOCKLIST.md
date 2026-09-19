# AbuseIPDB → Cilium + Cloudflare Ingress Denylist

Runtime-managed IP reputation blocking fed by the
[AbuseIPDB blacklist API](https://docs.abuseipdb.com/#blacklist-endpoint). One
synchronizer maintains two enforcement sinks from the same validated list:

* **Cilium** (`CiliumCIDRGroup` + `CiliumClusterwideNetworkPolicy`) for traffic
  that reaches the cluster directly (direct-to-origin, LAN).
* **Cloudflare** (account IP list + one zone WAF custom rule) for the proxied
  public hostnames, where Cloudflare sees the real client IP.

The feed is **not** stored in Caddy, Coraza or Git.

```text
                       AbuseIPDB blacklist
                              │
                              ▼
                     abuseipdb-sync (in-cluster)
                     validate → normalize → exceptions → dedupe/sort
                       │                              │
                       ▼                              ▼
          CiliumCIDRGroup/abuseipdb          Cloudflare IP list "abuseipdb"
                       │                              │
          CCNP deny on reserved:ingress      Zone WAF custom rule:
          (direct-to-origin / LAN)           ip.src in $abuseipdb → Block
                       │                              │
                       ▼                              ▼
                  Cilium Gateway ─────────────► Cloudflare edge
                                                       │
                                                       ▼
                                                Caddy → Coraza → app
```

Caddy + Coraza remain responsible for application-layer protections (SQLi, XSS,
LFI/RFI, RCE, OWASP CRS). The AbuseIPDB feed is an **IP reputation control**,
not a WAF replacement, and it is never duplicated into Caddy/Coraza.

## Components

| Component | Location | Notes |
|---|---|---|
| Synchronizer image | `gitops/images/abuseipdb-sync/` + `.github/workflows/build-abuseipdb-sync.yaml` | Go, distroless, public GHCR package `ghcr.io/stefanf81/abuseipdb-sync` |
| Controller manifests | `gitops/infrastructure/controllers/abuseipdb/` | Deployment, SA, RBAC, config, secret, Service, network policies |
| Flux Kustomization | `gitops/clusters/taskflow/abuseipdb.yaml` | `dependsOn: infra-controllers`, SOPS decryption |
| Deny policy (staged) | `gitops/infrastructure/configs/cilium/abuseipdb-ingress-deny.yaml` | **Not yet referenced by its kustomization** — see Stage 4 |
| Cloudflare edge sink | managed by the synchronizer via the Cloudflare API | IP list `abuseipdb` + zone rule `ref: abuseipdb` |
| Scrape + dashboard | `gitops/monitoring/app/abuseipdb.yaml` | `VMServiceScrape` + Grafana dashboard `AbuseIPDB Security` |
| Logs | `gitops/monitoring/logging/alloy-release.yaml` | Alloy ships namespace `abuseipdb` to Loki |

The dynamic `CiliumCIDRGroup/abuseipdb` is created and updated **only** by the
synchronizer. It is deliberately absent from Git and from every Flux inventory,
so `prune` can never delete it and no reconciliation can fight the controller.
The Cloudflare list and rule are likewise runtime-managed (the rule uses a
stable `ref` so only that rule is ever touched).

## Source IP and enforcement split (Cloudflare proxy)

All five public hostnames are Cloudflare-proxied (`PROXIED=true` in
`gitops/apps/taskflow/cloudflare-ddns.yaml`; verified with DNS lookups returning
Cloudflare anycast addresses). The real path is:

```text
real client → Cloudflare edge → WAN port-forward → Cilium LB (192.168.50.201)
```

Consequences:

* **Cloudflare sees the real client IP.** The Cloudflare edge sink (IP list +
  `ip.src in $abuseipdb → Block` rule) is therefore the enforcement point that
  actually protects proxied Internet traffic. Blocked requests are rejected at
  the Cloudflare edge and never reach the origin at all.
* **Cilium/Envoy sees Cloudflare edge IPs** for proxied traffic, so the Cilium
  denylist can only match addresses that actually arrive at the Cilium LB:
  direct-to-origin traffic (e.g. scanners hitting the WAN address with a forged
  `Host: www.jokelab.dev` header) and LAN/future non-proxied listeners. This is
  why both sinks exist.
* Cilium L7 header matching cannot substitute for the edge sink: it does not
  support CIDR/regex and one rule per IP is explicitly out of scope.
* The real client IP remains visible downstream via `CF-Connecting-IP` /
  `X-Forwarded-For` and is used by Caddy/Coraza and the Taskflow WAF dashboards.

TLS terminates **at the Cilium Gateway** (`mode: Terminate`, cert
`taskflow-tls-secret` managed by cert-manager/Let's Encrypt HTTP-01). Caddy
receives plain HTTP from Envoy; Envoy appends the visible source address to
`X-Forwarded-For` and passes `CF-Connecting-IP` through. The WAFs trust the pod
CIDR (`10.42.0.0/16`) and prefer `CF-Connecting-IP`; never widen that without
also tightening the WAF ingress policy.

## Synchronizer behavior

Pipeline per cycle:

```text
GET /api/v2/blacklist?plaintext=true&limit=…   (Accept: text/plain)
  → strict validation (any malformed line aborts the whole update)
  → canonicalize IP→/32,/128 and mask CIDRs
  → drop internal/reserved ranges (built-in + protected-cidrs.txt)
  → subtract trusted exceptions (exceptions.txt)
  → deduplicate + deterministic sort
  → sanity checks (non-empty, min entries, shrink guard)
  → atomic in-place create/update of CiliumCIDRGroup/abuseipdb
```

* The first synchronization runs **immediately at startup**, then every
  `ABUSEIPDB_SYNC_INTERVAL` (default 6h).
* The same validated list is then applied to each enabled sink:
  * **Cilium:** atomic in-place create/update of `CiliumCIDRGroup/abuseipdb`,
    never delete/recreate, respecting `resourceVersion` (no enforcement gap).
  * **Cloudflare:** resolve-or-create the account IP list, compare items and
    only replace them when changed (`PUT .../items` is one atomic asynchronous
    bulk operation; the controller waits for completion and never issues a
    second pending operation), then ensure the managed zone rule exists with
    `ref: abuseipdb` (`ip.src in $abuseipdb`, action `block`). Existing
    customer rules are never modified.
* Sinks fail independently: a Cloudflare API/rate-limit failure never prevents
  the Cilium update and vice versa. `abuseipdb_sync_success` is `1` only when
  all enabled sinks succeed.
* On any feed failure the **last known good list is retained in both sinks**;
  error metrics and structured logs are emitted. A truncated or malformed
  response is never applied.
* `abuseipdb.io/last-success` (Cilium) and
  `abuseipdb.io/cloudflare-last-success` are stored on the CIDR group, so feed
  age survives pod restarts.
* When a sink's feed is older than `ABUSEIPDB_MAX_STALE_AGE` (default 24h), the
  documented stale behavior runs per sink: `fail-open` (default) empties that
  sink (Cilium group / Cloudflare list) so no address is blocked on very old
  data; `retain` keeps the last-known-good list. Either way the corresponding
  `*_feed_stale` metric is visible on the dashboard.

### Configuration (`abuseipdb-sync-config`)

| Key | Default | Meaning |
|---|---|---|
| `ABUSEIPDB_LIMIT` | `10000` | Blacklist size cap (Individual 10k, Basic 100k, Premium 500k) |
| `ABUSEIPDB_SYNC_INTERVAL` | `6h` | Minimum 5m; free tier allows 5 blacklist calls/day |
| `ABUSEIPDB_CONFIDENCE_MINIMUM` | *unset* | Subscriber feature (25–100); unset uses the API default (100) |
| `ABUSEIPDB_MAX_STALE_AGE` | `24h` | Age after which the feed counts as stale |
| `ABUSEIPDB_STALE_BEHAVIOR` | `fail-open` | `fail-open` or `retain` |
| `ABUSEIPDB_MIN_ENTRIES` | `1` | Validated results below this are rejected |
| `ABUSEIPDB_MAX_SHRINK_PERCENT` | `50` | Reject lists that shrink by more than this (when previous ≥ 100) |
| `ABUSEIPDB_CIDRGROUP_NAME` | `abuseipdb` | Runtime group name |
| `CLOUDFLARE_SYNC_ENABLED` | `false` | Enable the Cloudflare edge sink |
| `CLOUDFLARE_ACCOUNT_ID` | — | Cloudflare account owning the IP list |
| `CLOUDFLARE_ZONE_ID` | — | Zone of `jokelab.dev` (the WAF rule lives here) |
| `CLOUDFLARE_LIST_NAME` | `abuseipdb` | Account IP list resolved/created by name |
| `CLOUDFLARE_MAX_ENTRIES` | `10000` | Sink rejects larger lists (free plan cap; Cilium unaffected) |
| `CLOUDFLARE_RULE_REF` | `abuseipdb` | Stable rule reference; only this rule is ever modified |

The exception and protected-range lists live in `abuseipdb-sync-files` and are
re-read on every cycle, so Git edits apply without a restart.

### Metrics

`abuseipdb_entries`, `abuseipdb_entries_added`, `abuseipdb_entries_removed`,
`abuseipdb_exceptions_removed`, `abuseipdb_protected_removed`,
`abuseipdb_invalid_entries_total`, `abuseipdb_sync_success`,
`abuseipdb_sync_errors_total{reason}`, `abuseipdb_sync_duration_seconds`,
`abuseipdb_last_http_status`, `abuseipdb_last_success_timestamp_seconds`,
`abuseipdb_feed_age_seconds`, `abuseipdb_feed_stale`, `abuseipdb_build_info`.

Cloudflare sink: `abuseipdb_cloudflare_sync_success`, `_entries`,
`_last_success_timestamp_seconds`, `_feed_age_seconds`, `_feed_stale`,
`_sync_errors_total{reason}`, `_bulk_operation_pending`, `_rule_present`.

All labels are bounded; individual IPs are never metric labels. Use Loki
(`{namespace="abuseipdb"}`) and Hubble for per-IP investigation.

## RBAC, secrets and egress

* ServiceAccount `abuseipdb-sync` + ClusterRole limited to `get`, `create`,
  `update`, `patch` on `ciliumcidrgroups`. No `delete`, no wildcards, no
  cluster-admin.
* Secrets: SOPS-encrypted Secret `abuseipdb-sync` (`.sops.yaml` matches
  `*-secrets.yaml`) holding `ABUSEIPDB_API_KEY` and `CLOUDFLARE_API_TOKEN`.
  Edit with `sops gitops/infrastructure/controllers/abuseipdb/abuseipdb-secrets.yaml`;
  never commit plaintext.
* The Cloudflare token is a **separate least-privilege token** (do not reuse the
  DDNS token): `Account Filter Lists: Edit` + `Zone WAF: Edit`, scoped to the
  `jokelab.dev` account/zone. Leave Client IP filtering and TTL unset (dynamic
  WAN IP; no expiry).
* Egress: DNS, `api.abuseipdb.com:443` and `api.cloudflare.com:443` (Cilium
  FQDN policy) and the `kube-apiserver` entity only. Ingress: Prometheus scrape
  from namespace `monitoring` only. The pod runs non-root, read-only rootfs, all
  capabilities dropped, `RuntimeDefault` seccomp, no host access.

## Staged rollout

### Stage 1 — build and review

```bash
cd gitops/images/abuseipdb-sync && go vet ./... && go test ./...
# push to main triggers .github/workflows/build-abuseipdb-sync.yaml
# optionally pin the digest printed in the workflow summary into deployment.yaml
```

### Stage 2 — deploy the synchronizer (Cloudflare edge sink activates)

The secret file is already SOPS-encrypted; set the AbuseIPDB API key (still a
placeholder) with:

```bash
sops gitops/infrastructure/controllers/abuseipdb/abuseipdb-secrets.yaml
# commit, then:
flux reconcile kustomization flux-system --with-source
flux get kustomizations | grep abuseipdb
kubectl -n abuseipdb get pods
kubectl get ciliumcidrgroups
kubectl get ccg abuseipdb -o yaml
```

Because `CLOUDFLARE_SYNC_ENABLED=true`, the first successful sync also creates
the account IP list and the zone WAF custom rule. Verify in the dashboard
(`AbuseIPDB Security` → Cloudflare row) or directly:

```bash
# from inside the network with the token available
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/rules/lists" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[] | {name, kind, numitems}'
curl -s "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result.rules[] | {ref, action, expression, enabled}'
```

Verify: entry count, `abuseipdb.io/last-success` and
`abuseipdb.io/cloudflare-last-success` annotations, exceptions and protected
ranges subtracted, metrics scraped (`abuseipdb_entries`,
`abuseipdb_feed_age_seconds`, `abuseipdb_cloudflare_*`), Flux inventory does
**not** contain the CCG:

```bash
flux get kustomization abuseipdb -o yaml | grep -i inventory -A5
# expected: no CiliumCIDRGroup in the inventory
```

### Stage 3 — controlled deny tests (do NOT skip)

**Cloudflare edge (real client IP).** Temporarily add the controlled client's
public IP to the runtime Cloudflare list (e.g. via the Cloudflare dashboard or
the API), then request the site. Expected: a Cloudflare block response and **no
request in the origin logs / WAF dashboards**. Remove the temporary item
afterwards and let the next sync reconcile it (or clear it via the API).

**Cilium (direct path).** From a client whose source IP reaches Cilium directly
(bypassing Cloudflare, e.g. `curl --resolve www.jokelab.dev:443:192.168.50.201`
from the LAN with a public source), temporarily add that IP to the runtime Cilium
group only (not to Git):

```bash
kubectl patch ccg abuseipdb --type=merge -p '{"spec":{"externalCIDRs":["<TEST-CLIENT-IP>/32"]}}'
curl -sS -o /dev/null -w '%{http_code}\n' https://www.jokelab.dev/   # expect 403 from Envoy
hubble observe --last 20 --verdict DROPPED
```

Then restore by triggering a synchronization (`kubectl -n abuseipdb rollout
restart deploy/abuseipdb-sync`) and confirm 200 again. If the test IP cannot
reach Cilium directly, verify at least that the deny matches nothing while the
group is empty.

### Stage 4 — enable the real deny policy

`abuseipdb-ingress-deny.yaml` is listed in
`gitops/infrastructure/configs/cilium/kustomization.yaml` (Stage 4 applied).
Verify the policy and that legitimate traffic still works:

```bash
kubectl get ciliumclusterwidenetworkpolicies
kubectl get cciliumclusterwidenetworkpolicy deny-abuseipdb-ingress -o yaml | head -40
# proxied path (real client through Cloudflare) and direct-to-LB path
curl -s -o /dev/null -w '%{http_code}\n' https://www.jokelab.dev/
curl --resolve www.jokelab.dev:443:192.168.50.201 -o /dev/null -w '%{http_code}\n' https://www.jokelab.dev/
```

To prove the Cilium deny mechanism itself without touching the 10,000-entry
group, apply a temporary deny for a controlled LAN source, test, then delete it
(keep `enableDefaultDeny: false` so it cannot flip the ingress endpoint into
default-deny):

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: abuseipdb-test-deny
spec:
  endpointSelector:
    matchExpressions:
      - key: reserved:ingress
        operator: Exists
  ingressDeny:
    - fromCIDRSet:
        - cidr: 192.168.50.43/32   # the controlled test client
  ingress:
    - fromEntities: [all]
  enableDefaultDeny:
    ingress: false
```

Direct requests from that client must return Envoy `403`; deleting the test
policy restores `200` immediately.

## Acceptance checks

| Scenario | Expected |
|---|---|
| Source not listed | reaches Gateway → Caddy → Coraza → app |
| Source listed, proxied traffic | Cloudflare edge Block; request never reaches origin |
| Source listed, direct path after Stage 4 | Envoy 403 before Caddy/Coraza; app untouched |
| Listed in feed but in `exceptions.txt` | removed by the synchronizer from both sinks; allowed |
| AbuseIPDB API failure | last-known-good list retained in both sinks; error metric/log; dashboard shows failure |
| AbuseIPDB works but Cloudflare API fails | Cilium sink still updates; `abuseipdb_cloudflare_sync_success=0` and reason counter increments |
| Feed older than `ABUSEIPDB_MAX_STALE_AGE` | corresponding `*_feed_stale=1`; `fail-open` clears that sink |
| Malformed/truncated response | both sinks unchanged; `abuseipdb_invalid_entries_total` increments |
| Cloudflare bulk operation pending | `abuseipdb_cloudflare_bulk_operation_pending=1`; next update waits/retries |
| Flux reconcile | dynamic CCG untouched (never in inventory) |
| Pod restart | immediate synchronization; feed ages preserved from annotations |

## Rollback

Fastest enforcement rollbacks (effective immediately, no restarts):

```bash
# Cilium side (after Stage 4)
kubectl delete ciliumclusterwidenetworkpolicy deny-abuseipdb-ingress

# Cloudflare side: disable/delete the managed custom rule (dashboard or API).
# The rule is identified by ref "abuseipdb"; deleting only the list leaves a
# dangling reference, so remove/disable the rule first.
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/rulesets/$RULESET_ID/rules/$RULE_ID" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

To stop feed updates without changing enforcement: set
`CLOUDFLARE_SYNC_ENABLED: "false"` (and/or `ABUSEIPDB_STALE_BEHAVIOR`), commit,
reconcile. To remove the Cloudflare rule and list entirely, delete the rule
first, then the list (the list cannot be deleted while referenced).

GitOps rollback: remove `- abuseipdb-ingress-deny.yaml` from
`gitops/infrastructure/configs/cilium/kustomization.yaml`; Flux prunes the CCNP.

Full removal: delete `gitops/clusters/taskflow/abuseipdb.yaml`, its entry in
`gitops/clusters/taskflow/kustomization.yaml`, the
`gitops/infrastructure/controllers/abuseipdb/` directory and the monitoring
entry, then delete the leftover runtime objects manually:
`kubectl delete ccg abuseipdb`, and the Cloudflare rule + list.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pod `CrashLoopBackOff` with "ABUSEIPDB_API_KEY is empty" | Secret not populated; run `sops <secret file>` |
| Pod `CrashLoopBackOff` with "CLOUDFLARE_API_TOKEN is empty" | Same secret, `CLOUDFLARE_API_TOKEN` key |
| `abuseipdb_last_http_status=401/422` | Bad AbuseIPDB key or unsupported `ABUSEIPDB_CONFIDENCE_MINIMUM` (<100 requires subscription) |
| `abuseipdb_last_http_status=429` | Daily API limit reached (free tier 5/day); next window resets at 00:00 UTC |
| `abuseipdb_cloudflare_sync_errors_total{reason="http"}` | Token missing `Account Filter Lists: Edit` / `Zone WAF: Edit`, wrong account/zone ID, or a list name collision with a non-IP list |
| `abuseipdb_cloudflare_sync_errors_total{reason="rate_limited"}` | A bulk operation is still pending (only 1 per account); the next sync retries |
| `abuseipdb_cloudflare_sync_errors_total{reason="bulk"}` | Bulk operation failed or exceeded the 2m wait; check the Cloudflare audit log and the next sync |
| `abuseipdb_cloudflare_sync_errors_total{reason="validation"}` | List exceeds `CLOUDFLARE_MAX_ENTRIES` (free plan: 10,000) |
| Sync errors `kube` | Cilium CRDs missing or RBAC; check `kubectl auth can-i create ciliumcidrgroups --as=system:serviceaccount:abuseipdb:abuseipdb-sync` |
| DNS/FQDN egress failures | CoreDNS labels changed, or Cilium DNS proxy blocked |
| Envoy 403 for everyone | CCNP references the group but group is misconfigured; check `cilium-dbg policy get` and the group contents |
| Group owned by something else | Synchronizer refuses to overwrite a group without `app.kubernetes.io/managed-by=abuseipdb-sync` |
| Cloudflare rule does not block | Rule disabled, expression drifted, or another zone rule skips/challenges first; check the entry point ruleset order |

## Scalability notes

Since Cilium 1.17 a `CiliumCIDRGroup` allocates a single security identity for
the whole group and integrates with the ipcache, so lists of ~100k CIDRs are
supported. The dashboard surfaces `cilium_bpf_map_pressure`,
`cilium_controllers_failing` and `cilium_policy_endpoint_enforcement_status` so
impact can be measured before any tuning; do not tune Cilium preemptively.
