# Taskflow WAF Runbook

## Components

- `taskflow-frontend-waf` receives `www.jokelab.dev/` traffic.
- `taskflow-backend-waf` receives `www.jokelab.dev/api` traffic.
- Both WAFs use Caddy `2.11.4`, Coraza Caddy `v2.6.0`, OWASP CRS, and `caddy-ratelimit` (single container, no sidecars).
- Both WAFs run with `SecRuleEngine On` and paranoia level 2.
- Per-client HTTP rate limiting (staged; enforcement is off in Git until the "Rate limiting" procedure passes): frontend `general` 180/min, backend `api` 300/min, key `{client_ip}`, IPv6 grouped per `/64` (429 + `Retry-After` when exceeded).
- Coraza audit JSON goes straight to stdout; Alloy redacts credentials at ingest.
- Loki runs as one monolithic replica in `monitoring` with 30-day retention.
- Alloy collects WAF logs plus all other Taskflow workload logs and sends them to Loki.
- Grafana dashboards at `https://grafana.jokelab.dev/d/taskflow-waf` and `https://grafana.jokelab.dev/d/taskflow-rate-limits`.

## Build the WAF image

The image is built automatically by
`.github/workflows/build-taskflow-caddy-coraza.yaml` when
`gitops/images/taskflow-caddy-coraza/` changes. The manual steps below are a
fallback.

The published tag should use the version and revision declared by
`CADDY_VERSION`, `CORAZA_CADDY_VERSION`, and `IMAGE_REVISION` in the Dockerfile.
Increment `IMAGE_REVISION` when the image recipe changes without either upstream
version changing; published revision tags must not be overwritten.
`RATE_LIMIT_VERSION` pins the `mholt/caddy-ratelimit` module to an immutable
commit (no tagged release has the required options).

CI builds the image, runs the identity and rate-limit suite in
`gitops/images/taskflow-caddy-coraza/tests/` on every PR, and **skips the push**
if the revision tag is already published (bump `IMAGE_REVISION`) so published
tags are never overwritten. Run the suite locally with:

```bash
TEST_IMAGE=ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 \
  gitops/images/taskflow-caddy-coraza/tests/run-tests.sh
```

For a manual publish, the account or token used by `docker push` needs package
write permission. The cluster's `ghcr-pull-secret` needs only package read
permission.

### Manual Local Build (Alternative)

Build and publish the image locally if needed:

```bash
# Build for linux/amd64 (k3s node architecture)
docker buildx build --platform linux/amd64 --load \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 \
  gitops/images/taskflow-caddy-coraza

# Authenticate to GHCR (requires write:packages; prefer a classic PAT — gho_ tokens may lack GHCR scopes)
read -r -s GITHUB_TOKEN
echo "$GITHUB_TOKEN" | docker login ghcr.io -u stefanf81 --password-stdin
unset GITHUB_TOKEN

# Push the image
docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3

# Verify both modules are present
docker run --rm ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 list-modules \
  | grep -E 'http.handlers.waf|http.handlers.rate_limit'

# Get digest for pinning
docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3
```

Replace the image reference in both WAF Deployments with the digest returned by
`docker inspect` before relying on the deployment in production.

**Important**: The image MUST be built for `linux/amd64` — the k3s node is amd64,
not arm64 (even if your development machine is Apple Silicon).

## Reconcile

```bash
flux reconcile kustomization taskflow-app -n flux-system --with-source
flux reconcile kustomization monitoring -n flux-system --with-source
flux reconcile kustomization monitoring-logging -n flux-system --with-source
```

Check readiness:

```bash
kubectl -n taskflow get deploy,svc,pod taskflow-frontend-waf taskflow-backend-waf
kubectl -n monitoring get helmrelease loki alloy
kubectl -n monitoring get pvc,pod -l app.kubernetes.io/part-of=taskflow-observability
kubectl get httproute -n taskflow taskflow-route -o yaml
```

The route must report `Accepted=True` and `ResolvedRefs=True`.

## Apply Caddyfile changes (manual reload)

Both WAFs run Caddy with `admin off`, so editing the ConfigMap does **not** reload
the running config. After changing `Caddyfile` or `*-exclusions.conf` in Git:

```bash
flux reconcile kustomization taskflow-app -n flux-system --with-source
kubectl -n taskflow rollout restart deployment/taskflow-backend-waf deployment/taskflow-frontend-waf
kubectl -n taskflow rollout status deployment/taskflow-backend-waf
kubectl -n taskflow rollout status deployment/taskflow-frontend-waf
```

Verify the new rule set is live by sending a canary request that the new rule
should match (or confirm fresh audit timestamps in Loki).

## Rate limiting

Caddy carries per-client HTTP rate limits (HTTP 429 + `Retry-After`) via the
`caddy-ratelimit` module, keyed on the resolved `{client_ip}`. **Enforcement is
OFF in Git** (`rate-limit.conf` is comments-only) until the steps below pass.
Coraza always runs before the limiter; `/waf-healthz` is never rate limited.

Target zones (see `gitops/apps/taskflow/*-waf.yaml`, `rate-limit.conf` key):

| WAF | Zone | Limit | Window | Key |
|-----|------|-------|--------|-----|
| `taskflow-frontend-waf` | `general` | 180 | 60s | `{client_ip}` (IPv6 `/64`) |
| `taskflow-backend-waf` | `api` | 300 | 60s | `{client_ip}` (IPv6 `/64`) |

### Prerequisite — Cloudflare settings

Confirm the zone does **not** use Pseudo IPv4 in *Overwrite Headers* mode: that
replaces `X-Forwarded-For` (and `CF-Connecting-IP`) with a per-address
pseudo-IPv4 value, which changes the resolved identity and defeats the IPv6
`/64` grouping. "Off" (the default) or "Add Header" is fine. Also confirm no
Worker or Transform Rule rewrites `X-Forwarded-For`.

### Stage 0 — record the current peer address (before changing anything)

The Caddyfile resolves the visitor from `X-Forwarded-For`, right-to-left,
skipping trusted hops. The trusted list already contains the Cloudflare ranges
plus an **interim** `10.42.0.0/16`. That interim entry must become the exact
Cilium Envoy source address, otherwise a pod that reaches the Gateway could be
skipped as a trusted hop. Collect it from the currently running WAFs:

```bash
for d in taskflow-frontend-waf taskflow-backend-waf; do
  kubectl -n taskflow logs deploy/$d --since=24h \
    | jq -r 'select(.msg=="handled request" and .request.uri != "/waf-healthz") | .request.remote_ip' \
    | sort | uniq -c | sort -rn | head
done
```

Every request here is proxied by the Cilium Gateway, so the dominant address is
the Envoy/peer source. (Health-check probes are excluded; they originate from
the node and may show the same address.) If more than one address appears,
confirm each one (e.g. with
`kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,INGRESS4:.spec.ingress.ipv4,INGRESS6:.spec.ingress.ipv6`)
and trust only the addresses that actually originate Gateway traffic. Record the
result as `<PEER_CIDR>`.

### Stage 1 — narrow the trusted proxy range (enforcement still off)

1. Replace `10.42.0.0/16` in the `trusted_proxies` line of both WAF ConfigMaps
   with `<PEER_CIDR>` (keep the Cloudflare ranges).
2. Reconcile and roll: `flux reconcile kustomization taskflow-app -n flux-system --with-source`
   then `kubectl -n taskflow rollout restart deployment/taskflow-backend-waf deployment/taskflow-frontend-waf`.
3. Run the identity checks below.

### Stage 2 — verify the client identity (required before enforcement)

```bash
# 1) Different external clients must resolve to different client_ip values
#    (query Loki or the Taskflow Access Logs dashboard). Expect the real
#    visitor addresses, not Cloudflare/Envoy/peer addresses:
#    topk(10, sum by (client_ip) (
#      count_over_time({job="coraza-waf", container="waf"} | json
#        | msg="handled request" | client_ip != "" [1h])))

# 2) A spoofed forwarding header must NOT become the client identity.
#    Bypass Cloudflare and talk to the origin directly; the access log must
#    show the real source address, not 1.2.3.4/5.6.7.8:
curl -s -H 'X-Forwarded-For: 1.2.3.4' -H 'CF-Connecting-IP: 5.6.7.8' \
  --resolve www.jokelab.dev:443:192.168.50.201 \
  -o /dev/null -w '%{http_code}\n' https://www.jokelab.dev/

# 3) Through Cloudflare the forwarding headers are set by Cloudflare, so the
#    logged client_ip must still be the real client:
curl -s -H 'X-Forwarded-For: 1.2.3.4' -H 'CF-Connecting-IP: 5.6.7.8' \
  -o /dev/null -w '%{http_code}\n' https://www.jokelab.dev/

# 4) In-cluster pod path: a pod reaching the Gateway must resolve to its own
#    pod address, not a forged value to its left. Pods cannot reach the WAF
#    Service directly (`allow-gateway-to-waf` admits only the Gateway/Envoy
#    identity), so send the canary through the Gateway VIP like any client.
#    With <PEER_CIDR> narrowed to the Envoy /32 the logged client_ip is the pod
#    address; with 10.42.0.0/16 it is the forged value — that is the signal to
#    complete Stage 1 first.
kubectl run rl-canary --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sk --resolve www.jokelab.dev:443:192.168.50.201 \
    -H 'X-Forwarded-For: 1.2.3.4' -o /dev/null -w '%{http_code}\n' \
    https://www.jokelab.dev/
```

Confirm on the Taskflow Access Logs dashboard (or via the LogQL above) that
`client_ip` is the real visitor for external requests. If `client_ip` shows a
`10.42.x.x`/peer address, the trust list is wrong — stop and fix it before
enabling enforcement.

### Stage 3 — enable enforcement

1. **Prerequisite: Stage 1 and Stage 2 must have passed** (trust list narrowed to
   the observed Envoy `/32` and the identity canaries verified). Do not enable
   enforcement while the interim `10.42.0.0/16` is still trusted.
2. Put the zone block into the `rate-limit.conf` key of each WAF ConfigMap
   (frontend `general` 180/min, backend `api` 300/min; the exact block is in the
   comments of that key).
3. Reconcile and roll (same commands as Stage 1).
4. Verify enforcement from one external client:

```bash
# Expect normal statuses until the window fills, then 429 with Retry-After.
# The unique query string bypasses the Cloudflare edge cache so every request
# reaches the origin.
for i in $(seq 1 220); do
  curl -s -o /dev/null -w '%{http_code}\n' "https://www.jokelab.dev/?rl-test=$i"
done | sort | uniq -c

curl -sI "https://www.jokelab.dev/?rl-test=9999" | grep -Ei 'HTTP/|retry-after'
```

Confirm in Loki that 429s appear while the window is full and stop afterwards:

```logql
sum by (rate_limit_zone) (
  count_over_time({job="coraza-waf", container="waf"} | json | __error__=""
    | msg="handled request" | status=429 | rate_limit_zone=~".+" [5m]))
```

Then confirm that a second client is unaffected and that `403` Coraza blocks
still occur (`is_interrupted:true` audit records).

### Tune or disable

- **Tune:** edit the zone `events` in the `rate-limit.conf` key, reconcile, and
  roll. A ConfigMap edit alone changes nothing in the running pods.
- **Disable:** restore the comments-only `rate-limit.conf`, reconcile, and roll.
  The `r3` image can stay; the module is simply unused. Keep the narrowed
  trusted-proxy configuration.

### Rate-limit troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `client_ip` in access logs is a `10.42.x.x`/peer address | The trusted proxy list does not match the actual Envoy source, so Caddy ignores XFF. Re-run Stage 0 and fix `<PEER_CIDR>` before enabling enforcement. |
| Legitimate clients receive 429 | Limit too low for the workload (shared NAT/CGNAT, polling clients, large SPA reloads). Raise the zone `events` and observe; the 429 access logs include `client_ip`, path, host, and `rate_limit_zone`. |
| 429s exist but every one has an empty `rate_limit_zone` | They come from the application/upstream, not the limiter (see the "Rejection mix" dashboard panel). |
| `unrecognized directive: rate_limit` at startup | The pod runs an image without the module. Pin both WAF Deployments to the `r3` digest. |

## Internal tests

Test each WAF before relying on the public route. A test pod cannot reach the
WAF Services directly: `allow-gateway-to-waf` admits only the Gateway/Envoy
(`reserved:ingress`) identity. Use `kubectl port-forward` instead (node-originated
traffic is allowed by the network policy):

```bash
kubectl -n taskflow port-forward svc/taskflow-frontend-waf 8080:8080 &
PF=$!; sleep 1
curl -i http://localhost:8080/
kill "$PF"

kubectl -n taskflow port-forward svc/taskflow-backend-waf 8081:8080 &
PF=$!; sleep 1
curl -i http://localhost:8081/api
kill "$PF"
```

Use the public route to exercise representative CRS rule families. These payloads
are inert query parameters; run them only against the Taskflow WAF. Because the
engine is in blocking mode, malicious test payloads may return a WAF block status
instead of the upstream API's usual `401`:

```bash
curl --silent --show-error --max-time 15 --get \
  --data-urlencode 'q=1 UNION SELECT 1' \
  --output /dev/null --write-out 'sqli %{http_code}\n' \
  'https://www.jokelab.dev/api'

curl --silent --show-error --max-time 15 --get \
  --data-urlencode 'q=<script>alert(1)</script>' \
  --output /dev/null --write-out 'xss %{http_code}\n' \
  'https://www.jokelab.dev/api'

curl --silent --show-error --max-time 15 --get \
  --data-urlencode 'file=../../../../etc/passwd' \
  --output /dev/null --write-out 'traversal %{http_code}\n' \
  'https://www.jokelab.dev/api'

curl --silent --show-error --max-time 15 --get \
  --data-urlencode 'q=; cat /etc/passwd' \
  --output /dev/null --write-out 'command %{http_code}\n' \
  'https://www.jokelab.dev/api'

curl --silent --show-error --max-time 15 \
  --user-agent 'sqlmap/1.8.12#stable (https://sqlmap.org)' \
  --output /dev/null --write-out 'scanner %{http_code}\n' \
  'https://www.jokelab.dev/api'
```

The verified matches are SQL injection (`942100`, `942190`, `942360`), XSS
(`941100`, `941110`, `941160`, `941390`), path traversal (`930100`, `930110`,
`930120`), command execution (`932160`), and scanner detection (`913100`). A
single payload can match multiple CRS rules, including `949110` anomaly-score
evaluation.

Inspect logs separately:

```bash
kubectl logs -n taskflow deploy/taskflow-frontend-waf
kubectl logs -n taskflow deploy/taskflow-backend-waf
kubectl logs -n monitoring deploy/alloy
```

In Grafana Explore, select the `Loki` datasource and query:

```logql
{job="coraza-waf", application="taskflow-frontend"}
{job="coraza-waf", application="taskflow-backend"}

# Only audit records containing a matched Coraza rule.
# This excludes relevant HTTP responses such as 401s that Coraza audits without a match.
{job="coraza-waf"} |= "\"messages\""

# Top rule IDs and source IPs over the selected period.
topk(10, sum by (rule_id) (count_over_time({job="coraza-waf", rule_id=~".+"}[1h])))
topk(10, sum by (transaction_client_ip) (
  count_over_time({job="coraza-waf"} |= "\"messages\"" | json [1h])
))
```

## Blocking and tuning

Blocking is enabled independently in each WAF. To tune one application without
changing the other, temporarily set only that WAF's `SecRuleEngine` to
`DetectionOnly`, observe and add narrow exclusions, then restore `On` and replay
the tests before proceeding to the other WAF.

### Source-IP reputation (not a WAF concern)

Known-malicious source IPs never reach these WAFs: the AbuseIPDB denylist is
enforced at the Cloudflare edge (proxied traffic) and by Cilium on the
`reserved:ingress` identity (direct-to-origin traffic). Do not add IP denylists
to Caddy/Coraza. To pause or roll back the IP layer, see
`docs/ABUSEIPDB_CILIUM_BLOCKLIST.md` §Rollback. Per-IP block lists for operators
live on the `Blocked Sources` Grafana dashboard (Cloudflare + Cilium), not in
the WAF dashboards.

## Rollback

To roll back public traffic while keeping the WAF workloads available, restore the
three route backends in `gitops/apps/taskflow/httproute.yaml`:

- `/api/v1/appointments/events` -> `backend:8080` (preserve its separate `31m` timeout)
- `/api` -> `backend:8080`
- `/` -> `frontend:8080`

Then reconcile `taskflow-app`. To disable one WAF without changing the other, restore
only its route backend and leave the other WAF route unchanged.

To roll back **rate limiting only**, restore the comments-only `rate-limit.conf`
in the WAF ConfigMap(s), reconcile `taskflow-app`, and rollout restart both WAF
Deployments (see "Rate limiting" -> "Tune or disable"). This does not affect
Cilium, the Gateway, Coraza, CRS, or the applications. Keep the narrowed
trusted-proxy configuration. To also roll back the image, restore the previous
digest in both WAF Deployments.

To remove logging, remove `monitoring-logging.yaml` from the cluster Kustomization
and reconcile after verifying that Loki data retention requirements are understood.
The Loki PVC uses the `proxmox-csi` reclaim policy and is retained independently of
the Helm release.

## Security notes

- Original application Services remain ClusterIP.
- Gateway access is allowed only to the WAF workloads.
- Each WAF can reach only its corresponding application Service and cluster DNS.
- Coraza audit parts exclude request bodies; Alloy removes credential headers and sensitive query parameters at ingest.
- Caddy access logs redact credentials and selected sensitive query parameters.
- Loki and Alloy have no Gateway, LoadBalancer, or public route.

---

## Troubleshooting

### Image Pull Errors

#### `401 Unauthorized` on image pull

**Cause**: The `ghcr-pull-secret` doesn't exist or contains invalid credentials.

**Fix**:
```bash
# Create the secret with a PAT that has read:packages scope
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace=taskflow \
  --docker-server=ghcr.io \
  --docker-username=stefanf81 \
  --docker-password="ghp_YOUR_PAT_HERE"

# Delete stuck pods to retry
kubectl delete pods -n taskflow -l app.kubernetes.io/component=waf
```

#### `403 Forbidden` on blob fetch

**Cause**: The PAT lacks `read:packages` scope, or the image doesn't exist at that digest.

**Fix**: Use a PAT with `read:packages` scope. Verify the image exists:
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $(gh auth token)" \
  https://ghcr.io/v2/stefanf81/taskflow-caddy-coraza/manifests/<digest>
```

#### `no match for platform in manifest: not found`

**Cause**: Image was built for arm64 (Apple Silicon) but k3s node is amd64.

**Fix**: Rebuild for the correct platform:
```bash
docker buildx build --platform linux/amd64 --load \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 \
  gitops/images/taskflow-caddy-coraza
docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3
# Update digest in frontend-waf.yaml and backend-waf.yaml
```

#### `gh auth token` returns empty password for docker login

**Cause**: `gh auth token` returns a `gho_` OAuth token, not a PAT. The `gho_` token may not have GHCR scopes.

**Fix**: Use a PAT directly:
```bash
export GITHUB_TOKEN="ghp_YOUR_PAT_HERE"
echo $GITHUB_TOKEN | docker login ghcr.io -u stefanf81 --password-stdin
```

### Container Runtime Errors

#### `exec /usr/bin/caddy: operation not permitted`

**Cause**: The Caddy binary has file capabilities (`cap_net_bind_service`) set by `xcaddy build`. With `allowPrivilegeEscalation: false`, the kernel blocks execution of capability-enhanced binaries for non-root users.

**Fix**: Strip file capabilities in the Dockerfile:
```dockerfile
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN setcap -r /usr/bin/caddy 2>/dev/null || true
```

#### `container has runAsNonRoot and image has non-numeric user (caddy)`

**Cause**: The security context has `runAsNonRoot: true` but no `runAsUser` specified. Kubernetes can't verify the numeric UID.

**Fix**: Add `runAsUser: 100` (caddy user UID) to the security context:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 100
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

#### `CreateContainerConfigError`

**Cause**: Usually a ConfigMap reference issue or volume mount mismatch.

**Fix**:
1. Check events: `kubectl describe pod <pod-name> -n taskflow`
2. Verify ConfigMap exists: `kubectl get cm -n taskflow | grep waf`
3. Verify keys match volume mount items

### Flux Reconciliation Issues

#### Kustomization stuck in "Reconciliation in progress"

**Cause**: Dependency chain not satisfied, or health checks failing.

**Fix**:
```bash
# Check dependency status
flux get kustomizations -n flux-system

# Force reconcile from root
flux reconcile kustomization flux-system -n flux-system --with-source
sleep 10
flux reconcile kustomization infra-configs -n flux-system
sleep 10
flux reconcile kustomization taskflow-app -n flux-system --with-source
```

#### SOPS decryption fails

**Cause**: `sops-age` secret missing or age key doesn't match.

**Fix**:
```bash
kubectl get secret sops-age -n flux-system
# Verify the key matches .sops.yaml recipients
```

### Logging Issues

#### No logs in Loki

**Cause**: Alloy not collecting, or Loki not receiving.

**Fix**:
```bash
# Check Alloy is running
kubectl get pods -n monitoring | grep alloy

# Check Alloy config
kubectl get cm alloy -n monitoring -o jsonpath='{.data.config\.alloy}'

# Check Alloy logs
kubectl logs -n monitoring deploy/alloy -c alloy | tail -20

# Test Loki connectivity
kubectl run loki-query --image=curlimages/curl --rm -i --restart=Never -n monitoring -- \
  curl -s 'http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/labels'
```

#### Grafana dashboard shows no data

**Cause**: Loki datasource not provisioned, or dashboard not loaded.

**Fix**:
```bash
# Check datasource ConfigMap exists
kubectl get cm -n monitoring -l grafana_datasource

# Check dashboard ConfigMap exists
kubectl get cm -n monitoring -l grafana_dashboard

# Check sidecar loaded them
kubectl logs deployment/victoria-metrics-k8s-stack-grafana -n monitoring -c grafana-sc-datasources | grep loki
kubectl logs deployment/victoria-metrics-k8s-stack-grafana -n monitoring -c grafana-sc-dashboard | grep taskflow
```

#### Caddy access logs but no Coraza audit logs

**Cause**: The `/waf-healthz` endpoint bypasses the WAF (handled before `coraza_waf` directive). Only real app traffic triggers Coraza rules.

**Fix**: Send actual traffic to the app endpoints, not just health checks. Coraza audit logs are generated when CRS rules match (or when `SecAuditEngine` is `On`).

#### Audit events appear, but detection panels are empty

**Cause**: `SecAuditEngine RelevantOnly` also audits relevant response statuses. These records contain `transaction` but no `messages` array, so they are audit events rather than WAF rule detections.

**Fix**: Use `{job="coraza-waf"} |= "\"messages\""` to view actual matched rules. After deploying the Alloy pipeline, verify that a new detection also has `method` and `rule_id` labels in Grafana Explore. Historic records will not gain those labels.

#### Detection category slices show `Value #A`, `Value #B`, or similar

**Cause**: Grafana pie charts name instant-query result fields by reference ID unless
the dashboard supplies display-name overrides.

**Fix**: Reconcile `monitoring-logging` from a revision containing the Taskflow WAF
dashboard overrides. The pie slices are named SQL injection, Cross-site scripting,
Path traversal, and Command injection.

### Network Policy Issues

#### Pod stuck in `ContainerCreating`

**Cause**: CiliumNetworkPolicy blocking traffic.

**Fix**:
```bash
# Check policy status
kubectl get ciliumnetworkpolicy -n taskflow

# Verify policies are VALID
kubectl get ciliumnetworkpolicy -n taskflow -o custom-columns="NAME:.metadata.name,VALID:.status.conditions[?(@.type=='Valid')].status"

# Check Cilium agent logs
kubectl logs -n kube-system -l k8s-app=cilium | grep -i "policy\|denied"
```

---

## Known Issues

### GHCR PAT Rotation

The `ghcr-pull-secret` is created manually with `kubectl create secret`. It's not
managed by GitOps. When the PAT expires:

1. Create a new PAT with `read:packages` scope at https://github.com/settings/tokens
2. Recreate the secret:
   ```bash
   kubectl delete secret ghcr-pull-secret -n taskflow
   kubectl create secret docker-registry ghcr-pull-secret \
     --namespace=taskflow \
     --docker-server=ghcr.io \
     --docker-username=stefanf81 \
     --docker-password="ghp_NEW_TOKEN"
   ```
3. Consider using Sealed Secrets or External Secrets Operator for proper GitOps management.

### Sealed Secrets Helm Repo 404

The `sealed-secrets` Helm repository returns 404 on `helm repo update`. This is
non-blocking but should be investigated if you want to use Sealed Secrets for
secret management.

### Coraza Audit Log Parts

Current setting: `ABFHZ` (request headers, response headers, matched-rule metadata,
and end marker). It excludes request bodies. Coraza writes records directly to
container stdout; Alloy sanitizes credential headers and sensitive query values at
ingest before they reach Loki. Do not add a blocking FIFO/file sink to
`SecAuditLog` — a stalled reader can block every audited request.

---

## Reference Links

- [Coraza WAF Documentation](https://coraza.io/docs/)
- [OWASP CRS Documentation](https://coreruleset.org/docs/)
- [Caddy Documentation](https://caddyserver.com/docs/)
- [Grafana Loki Documentation](https://grafana.com/docs/loki/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Coraza-Caddy GitHub](https://github.com/corazawaf/coraza-caddy)
- [OWASP CRS Tuning Guide](https://coreruleset.org/docs/usage-tuning/)
