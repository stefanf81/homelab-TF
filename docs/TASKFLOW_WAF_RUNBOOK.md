# Taskflow WAF Runbook

## Components

- `taskflow-frontend-waf` receives `www.jokelab.dev/` traffic.
- `taskflow-backend-waf` receives `www.jokelab.dev/api` traffic.
- Both WAFs use Caddy `2.11.4`, Coraza Caddy `v2.5.0`, OWASP CRS, and an audit-log redactor sidecar.
- Both WAFs start with `SecRuleEngine DetectionOnly` and paranoia level 1.
- Loki runs as one monolithic replica in `monitoring` with 30-day retention.
- Alloy collects only pods labelled as Taskflow WAFs and sends them to Loki.
- Grafana dashboard at `https://grafana.jokelab.dev/d/taskflow-waf`.

## Build the WAF image

The repository intentionally contains only the Dockerfile, not a CI workflow.
Build and publish the image manually:

```bash
# Build for linux/amd64 (k3s node architecture)
docker build --platform linux/amd64 \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1 \
  gitops/images/taskflow-caddy-coraza

# Authenticate to GHCR (requires write:packages scope)
echo $(gh auth token) | docker login ghcr.io -u stefanf81 --password-stdin

# Push the image
docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1

# Get digest for pinning
docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1
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

## Internal tests

Test each WAF before relying on the public route:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -i http://taskflow-frontend-waf.taskflow.svc.cluster.local:8080/

kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -i http://taskflow-backend-waf.taskflow.svc.cluster.local:8080/api
```

Use the public route to exercise representative CRS rule families. These payloads
are inert query parameters; run them only against the Taskflow WAF. DetectionOnly
must return the upstream response rather than block it (the unauthenticated API
currently returns `401`):

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
kubectl logs -n taskflow deploy/taskflow-frontend-waf -c audit-log-redactor
kubectl logs -n taskflow deploy/taskflow-backend-waf -c audit-log-redactor
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

## Blocking rollout

Blocking is intentionally independent. Tune and enable one application at a time:

1. Observe frontend detections and add narrow frontend exclusions only.
2. Change only the frontend `SecRuleEngine` to `On`.
3. Observe frontend behavior and roll back if required.
4. Tune backend detections and add narrow backend exclusions only.
5. Change only the backend `SecRuleEngine` to `On`.

## Rollback

To roll back public traffic while keeping the WAF workloads available, restore only
the two `backendRefs` in `gitops/apps/taskflow/httproute.yaml`:

- `/api` -> `backend:8080`
- `/` -> `frontend:8080`

Then reconcile `taskflow-app`. To disable one WAF without changing the other, restore
only its route backend and leave the other WAF route unchanged.

To remove logging, remove `monitoring-logging.yaml` from the cluster Kustomization
and reconcile after verifying that Loki data retention requirements are understood.
The Loki PVC uses the `proxmox-csi` reclaim policy and is retained independently of
the Helm release.

## Security notes

- Original application Services remain ClusterIP.
- Gateway access is allowed only to the WAF workloads.
- Each WAF can reach only its corresponding application Service and cluster DNS.
- Coraza audit parts exclude request bodies; the audit-log redactor removes credential headers and sensitive query parameters before stdout.
- Caddy access logs redact credentials and selected sensitive query parameters.
- Loki and Alloy have no Gateway, LoadBalancer, or public route.

---

## Troubleshooting

### Image Pull Errors

#### `401 Unauthorized` on image pull

**Cause**: The `ghcr-pull-secret` doesn't exist or contains invalid credentials.

**Fix**:
```bash
# Create the secret with a PAT that has write:packages scope
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

**Fix**: Use a PAT with `write:packages` scope (includes read). Verify the image exists:
```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $(gh auth token)" \
  https://ghcr.io/v2/stefanf81/taskflow-caddy-coraza/manifests/<digest>
```

#### `no match for platform in manifest: not found`

**Cause**: Image was built for arm64 (Apple Silicon) but k3s node is amd64.

**Fix**: Rebuild for the correct platform:
```bash
docker build --platform linux/amd64 \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1 \
  gitops/images/taskflow-caddy-coraza
docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1
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

1. Create a new PAT with `write:packages` scope at https://github.com/settings/tokens
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
and end marker). It excludes request bodies. Coraza writes raw records to a named pipe,
and the `audit-log-redactor` sidecar sanitizes inbound credentials and sensitive query
values before records reach stdout, Alloy, or Loki. Do not bypass the sidecar by
sending `SecAuditLog` directly to stdout.

---

## Reference Links

- [Coraza WAF Documentation](https://coraza.io/docs/)
- [OWASP CRS Documentation](https://coreruleset.org/docs/)
- [Caddy Documentation](https://caddyserver.com/docs/)
- [Grafana Loki Documentation](https://grafana.com/docs/loki/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [Coraza-Caddy GitHub](https://github.com/corazawaf/coraza-caddy)
- [OWASP CRS Tuning Guide](https://coreruleset.org/docs/usage-tuning/)
