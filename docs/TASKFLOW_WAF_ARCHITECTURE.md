# Taskflow WAF & Logging Architecture

## Overview

Taskflow uses a **Caddy + Coraza WAF** (Web Application Firewall) to inspect all incoming HTTP traffic before it reaches the application services. Coraza runs as a Coraza-Caddy plugin, using the **OWASP Core Rule Set (CRS)** to detect and optionally block common web attacks (SQL injection, XSS, path traversal, etc.).

Audit logs from the WAF are collected by **Grafana Alloy**, stored in **Grafana Loki** (30-day retention), and visualized in a **Grafana dashboard**.

```
                    ┌──────────────┐
                    │   Gateway    │  Cilium Gateway API
                    │ taskflow-gw  │  TLS termination
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              /api         /            │
              │            │            │
         ┌────▼─────┐ ┌───▼──────┐    │
         │ Backend  │ │ Frontend │    │
         │   WAF    │ │   WAF    │    │
         │ Caddy +  │ │ Caddy +  │    │
         │ Coraza   │ │ Coraza   │    │
         │ + CRS    │ │ + CRS    │    │
         └────┬─────┘ └───┬──────┘    │
              │            │           │
         ┌────▼─────┐ ┌───▼──────┐   │
         │ Backend  │ │ Frontend │   │
         │   App    │ │   App    │   │
         │ :8080    │ │ :8080    │   │
         └──────────┘ └──────────┘   │
                                     │
              ┌──────────────────────┘
              │
         ┌────▼─────────────────────────────┐
         │  Observability Stack             │
         │  Alloy → Loki → Grafana         │
         │  (job="coraza-waf")              │
         │  Dashboard: /d/taskflow-waf      │
         └─────────────────────────────────┘
```

## Components

| Component | Namespace | Version | Purpose |
|-----------|-----------|---------|---------|
| Caddy | `taskflow` | 2.11.4 | HTTP server + reverse proxy |
| Coraza | `taskflow` | v2.5.0 | WAF engine (OWASP ModSecurity compatible) |
| OWASP CRS | `taskflow` | v4.25.0 | Core Rule Set for attack detection |
| Alloy | `monitoring` | v1.18.0 | Log collection agent |
| Loki | `monitoring` | 18.7.1 (chart) | Log aggregation and storage |
| Grafana | `monitoring` | via victoria-metrics-k8s-stack | Dashboard visualization |

## Traffic Flow

```
Internet → Cloudflare DNS → Port Forward → 192.168.50.201 (L2 announcement)
    → Cilium Gateway (TLS termination)
    → HTTPRoute (path-based routing)
    → WAF Service (ClusterIP)
    → WAF Pod (Caddy + Coraza CRS inspection)
    → Application Service (ClusterIP)
    → Application Pod
```

### Path-Based Routing

| Path | Backend | Service |
|------|---------|---------|
| `/api*` | taskflow-backend-waf | `taskflow-backend-waf:8080` |
| `/*` | taskflow-frontend-waf | `taskflow-frontend-waf:8080` |

### WAF-to-Application Flow

| WAF Pod | Connects To | Protocol |
|---------|-------------|----------|
| `taskflow-frontend-waf` | `frontend.taskflow.svc.cluster.local:8080` | HTTP/1.1 |
| `taskflow-backend-waf` | `backend.taskflow.svc.cluster.local:8080` | HTTP/1.1 (h2c backend) |

## Image

The custom Caddy+Coraza image is built manually and pushed to GHCR:

- **Repository**: `ghcr.io/stefanf81/taskflow-caddy-coraza`
- **Tag**: `2.11.4-coraza2.5.0-r1`
- **Dockerfile**: `gitops/images/taskflow-caddy-coraza/Dockerfile`
- **Platform**: `linux/amd64` (k3s node architecture)
- **Digest**: Pinned in both WAF Deployments

### Build & Push

```bash
docker build --platform linux/amd64 \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1 \
  gitops/images/taskflow-caddy-coraza/

# Authenticate to GHCR (requires write:packages scope)
echo $(gh auth token) | docker login ghcr.io -u stefanf81 --password-stdin

docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1

# Get digest for pinning
docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1
```

### Image Build Details

The Dockerfile uses a multi-stage build:

1. **Builder stage**: Uses `caddy:2.11.4-builder-alpine` to compile Caddy with the Coraza WAF plugin via `xcaddy`
2. **Runtime stage**: Based on `caddy:2.11.4-alpine`, copies the compiled binary
3. **Key steps**:
    - `setcap -r /usr/bin/caddy` — strips file capabilities (required for `allowPrivilegeEscalation: false`)
    - Creates `caddy` user (UID 100) for non-root execution
    - Adds `jq`, used by the audit-log redactor sidecar
    - Exposes port 8080

## Kubernetes Resources

### WAF Deployments

| Resource | Frontend | Backend |
|----------|----------|---------|
| Deployment | `taskflow-frontend-waf` | `taskflow-backend-waf` |
| Service | `taskflow-frontend-waf` (ClusterIP:8080) | `taskflow-backend-waf` (ClusterIP:8080) |
| ConfigMap | `taskflow-frontend-waf-config` | `taskflow-backend-waf-config` |
| Security Context | runAsUser: 100, readOnlyRootFilesystem, drop ALL | runAsUser: 100, readOnlyRootFilesystem, drop ALL |
| Resources | 50m-500m CPU, 96Mi-512Mi memory | 100m-750m CPU, 128Mi-768Mi memory |
| Probes | /waf-healthz (readiness + liveness) | /waf-healthz (readiness + liveness) |

### ConfigMap Structure

Each WAF ConfigMap contains:

| Key | Content |
|-----|---------|
| `Caddyfile` | Main configuration with inline Coraza directives |
| `*-exclusions.conf` | CRS exclusion rules (initially empty) |
| `audit-redactor.sh` | Sanitizes Coraza audit JSON before it reaches stdout |

### Volume Mounts

| Mount Path | Source | Purpose |
|------------|--------|---------|
| `/etc/caddy` | ConfigMap (Caddyfile) | Caddy configuration |
| `/etc/coraza` | ConfigMap (exclusions) | Coraza exclusion rules |
| `/data` | emptyDir | Caddy data storage |
| `/config` | emptyDir | Caddy runtime config |
| `/tmp` | emptyDir | Temporary files |
| `/var/run/coraza` | emptyDir | Named pipe carrying raw Coraza audit records to the redactor |

### Image Pull Secret

A `ghcr-pull-secret` Docker registry secret is required in the `taskflow` namespace for pulling the private GHCR image:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace=taskflow \
  --docker-server=ghcr.io \
  --docker-username=stefanf81 \
  --docker-password="$GITHUB_TOKEN"
```

## Cilium Network Policies

| Policy | Effect |
|--------|--------|
| `allow-gateway-to-waf` | Allows Gateway (Cilium Envoy) → WAF pods on port 8080 |
| `allow-frontend-waf-to-frontend` | Allows frontend WAF → frontend app on port 8080 |
| `allow-backend-waf-to-backend` | Allows backend WAF → backend app on port 8080 |
| `isolate-taskflow-frontend-waf` | Isolates frontend WAF pod (default deny) |
| `isolate-taskflow-backend-waf` | Isolates backend WAF pod (default deny) |

## Coraza WAF Configuration

### Directive Load Order

```
directives `
    Include @coraza.conf-recommended     # Coraza base config
    Include @crs-setup.conf.example      # CRS setup (tunable knobs)
    Include /etc/coraza/*-exclusions.conf # Before-CRS exclusions

    SecRuleEngine DetectionOnly          # Engine mode
    SecAction "id:1000001,..."           # Paranoia level + tuning
    SecRequestBodyAccess On              # Body inspection
    SecResponseBodyAccess Off            # Response buffering off
    SecAuditEngine RelevantOnly          # Audit logging
    SecAuditLog /var/run/coraza/audit.pipe # Private audit pipe (JSON)
    SecAuditLogParts ABFHZ               # Includes matched-rule metadata
    SecRequestBodyLimit 10485760         # 10 MB max body
    SecRequestBodyNoFilesLimit 1048576   # 1 MB max non-file body

    Include @owasp_crs/*.conf            # CRS rules (embedded)
`
```

### SecRuleEngine Modes

| Mode | Effect |
|------|--------|
| `DetectionOnly` | Logs matches but never blocks (current setting) |
| `On` | Enables blocking (deny/drop/redirect) |

### Paranoia Level

| Level | Description |
|-------|-------------|
| 1 | Minimal rules, low false-positive rate (current) |
| 2 | More exotic attack detection, moderate false-positive risk |
| 3 | Aggressive, high false-positive rate |
| 4 | Maximum, not recommended for production |

### Audit Log Parts

Current: **ABFHZ** (request headers, response headers, matched-rule metadata, end
marker). It excludes request bodies. The audit-log redactor sidecar removes inbound
credential headers and sensitive query parameter values before writing JSON to stdout.

| Part | Content |
|------|---------|
| A | Audit log header |
| B | Request headers |
| C | Request body |
| K | Matched rule IDs |
| Z | End of audit log entry |

## Logging Stack

### Alloy Configuration

Alloy discovers WAF pods in the `taskflow` namespace using Kubernetes service discovery. Caddy access logs and redacted Coraza audit records share pod stdout, so a `loki.process` pipeline runs only on records containing `"transaction"`.

The pipeline extracts `method` from the transaction JSON and the first matched CRS `rule_id` from Coraza's `messages[]` array. Both are bounded values and are stored as Loki labels. Client IPs, URIs, transaction IDs, and other request-specific values remain in the log body and are parsed at query time to avoid high-cardinality labels.

Loki's `json` parser skips arrays, so `messages[]` cannot be fully flattened with LogQL. The raw JSON audit record is retained for investigation; dashboard detection queries require `"messages"` and therefore exclude relevant HTTP responses that did not trigger a WAF rule.

Alloy configuration:

```alloy
discovery.kubernetes "pods" {
  role = "pod"
  namespaces {
    names = ["taskflow"]
  }
}

discovery.relabel "taskflow_wafs" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component"]
    regex = "waf"
    action = "keep"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_part_of"]
    regex = "taskflow"
    action = "keep"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_protects"]
    target_label = "application"
    action = "replace"
  }

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label = "namespace"
    action = "replace"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label = "pod"
    action = "replace"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label = "container"
    action = "replace"
  }

  rule {
    target_label = "job"
    replacement = "coraza-waf"
    action = "replace"
  }
}

loki.source.kubernetes "taskflow_wafs" {
  targets = discovery.relabel.taskflow_wafs.output
  forward_to = [loki.process.coraza_audit.receiver]
}

loki.process "coraza_audit" {
  forward_to = [loki.write.local.receiver]

  stage.match {
    selector = "{job=\"coraza-waf\"} |= \"\\\"transaction\\\"\""

    stage.json {
      expressions = {
        method = "transaction.request.method",
      }
    }

    stage.regex {
      expression = `"messages":\[.*?\[id [^0-9]*(?P<rule_id>[0-9]+)`
    }

    stage.labels {
      values = {
        method  = "method",
        rule_id = "rule_id",
      }
    }
  }
}

loki.write "local" {
  endpoint {
    url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
  }

  external_labels = {
    cluster = "homelab",
    source = "coraza",
  }
}
```

### Loki Configuration

- **Mode**: Monolithic (single binary)
- **Retention**: 30 days (720 hours)
- **Storage**: 10Gi PVC (`proxmox-csi` StorageClass)
- **Caches**: Disabled (chunk cache, result cache)
- **Canary/Test**: Disabled

### Log Labels

| Label | Value |
|-------|-------|
| `job` | `coraza-waf` |
| `application` | `taskflow-frontend` or `taskflow-backend` |
| `namespace` | `taskflow` |
| `pod` | Pod name |
| `container` | `waf` for Caddy access logs; `audit-log-redactor` for Coraza audit logs |
| `cluster` | `homelab` |
| `source` | `coraza` |
| `method` | HTTP request method from a Coraza audit transaction |
| `rule_id` | First matched CRS rule ID, present only when the audit record has `messages[]` |

`client_ip`, `uri`, and transaction identifiers are deliberately not Loki labels. Use `| json` in LogQL to extract them for an individual query or a bounded aggregation.

### Grafana Datasource

The Loki datasource is provisioned via a ConfigMap with label `grafana_datasource: "1"`:

```yaml
apiVersion: 1
datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki-gateway.monitoring.svc.cluster.local
    isDefault: false
    editable: false
```

## Grafana Dashboard

**Dashboard**: "Taskflow WAF" (`/d/taskflow-waf`)

### Panels

| Panel | Type | Data Source | Query |
|-------|------|-------------|-------|
| WAF audit events | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf"} |= "\"transaction\"" [5m]))` |
| WAF rule detections | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf"} |= "\"messages\"" [5m]))` |
| Top triggered CRS rules | bar gauge | Loki | `topk(10, sum by (rule_id) (count_over_time({job="coraza-waf", rule_id=~".+"}[${__range}])))` |
| Detection categories | pie chart | Loki | Named SQL injection (`94[0-9]{4}`), Cross-site scripting (`941[0-9]{3}`), Path traversal (`93[0-1][0-9]{3}`), and Command injection (`93[2-4][0-9]{3}`) slices |
| Detections by HTTP method | timeseries | Loki | `sum by (method) (count_over_time({job="coraza-waf", method=~".+"} |= "\"messages\"" [5m]))` |
| Top source IPs | table | Loki | `topk(10, sum by (transaction_client_ip) (count_over_time({job="coraza-waf"} |= "\"messages\"" | json [${__range}])))` |
| Recent WAF detections | logs | Loki | `{job="coraza-waf"} |= "\"messages\"" | json | line_format ...` |
| SQL injection detections | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf", rule_id=~"94[0-9]{4}"}[5m]))` |
| XSS, command injection, path traversal | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf", rule_id=~"941[0-9]{3}|93[0-4][0-9]{3}"}[5m]))` |
| WAF pod CPU | timeseries | VictoriaMetrics | `rate(container_cpu_usage_seconds_total{...}[5m])` |
| WAF pod memory | timeseries | VictoriaMetrics | `container_memory_working_set_bytes{...}` |
| WAF pod restarts | timeseries | VictoriaMetrics | `increase(kube_pod_container_status_restarts_total{...}[1h])` |
| Loki ingester append timeouts | stat | VictoriaMetrics | `sum(rate(loki_distributor_ingester_append_timeouts_total[5m]))` |
| Alloy forwarding errors | stat | VictoriaMetrics | `sum(rate(loki_write_dropped_bytes_total[5m]))` |

### Template Variables

| Variable | Type | Values |
|----------|------|--------|
| `application` | query | `label_values({job="coraza-waf"}, application)` — filters by `taskflow-frontend` / `taskflow-backend` |

### Access Logs Dashboard

**Dashboard**: "Taskflow Access Logs" (`/d/taskflow-access-logs`)

This dashboard uses only Caddy access logs from `container="waf"`; it excludes
`/waf-healthz` probes and keeps normal traffic separate from Coraza audit records.
It provides request volume by application, response status and method trends, top
sanitized request URIs, request outcomes, and recent access logs. Filters are
available for `application` and `pod`; `namespace` is fixed to `taskflow` and
`container` is fixed to `waf`.

Each WAF uses `log_append <client_ip {client_ip}` before `coraza_waf`, so Caddy
access logs include the resolved visitor IP even when Coraza blocks the request.
The value is derived only from `X-Forwarded-For` received from the trusted Cilium
Gateway Pod CIDR. It is parsed at query time and is not a Loki label. Coraza audit
records continue to expose the same value as `transaction_client_ip` for
`RelevantOnly` transactions.

### Access

- **URL**: `https://grafana.jokelab.dev/d/taskflow-waf`
- **Credentials**: SOPS-encrypted admin password

### LogQL Queries

```logql
# All WAF logs
{job="coraza-waf"}

# Frontend only
{job="coraza-waf", application="taskflow-frontend"}

# Backend only
{job="coraza-waf", application="taskflow-backend"}

# Coraza audit events only (excluding health probes)
{job="coraza-waf"} |= "\"transaction\""

# Actual rule detections only (excludes relevant HTTP responses without a rule match)
{job="coraza-waf"} |= "\"messages\""

# Top matched CRS rules (newly ingested records after the Alloy pipeline rollout)
topk(10, sum by (rule_id) (count_over_time({job="coraza-waf", rule_id=~".+"}[1h])))

# Client IPs with the most detections; parsed at query time, not indexed
topk(10, sum by (transaction_client_ip) (
  count_over_time({job="coraza-waf"} |= "\"messages\"" | json [1h])
))

# Client IPs across all Caddy access logs, including requests that do not produce
# a Coraza audit event.
topk(10, sum by (client_ip) (
  count_over_time({job="coraza-waf", container="waf"} | json | __error__="" |
    client_ip != "" [1h])
))

# SQL injection detections
{job="coraza-waf"} |= "\"messages\"" |~ "\"id\":94[0-9]{4}"

# XSS detections
{job="coraza-waf"} |= "\"messages\"" |~ "\"id\":941[0-9]{3}"
```

## Caddy Access Logs

Caddy logs all requests to stdout in JSON format with sensitive fields redacted:

```json
{
  "level": "info",
  "ts": 1785750131.7725415,
  "logger": "http.log.access.log0",
  "msg": "handled request",
  "request": {
    "remote_ip": "10.42.0.148",
    "proto": "HTTP/1.1",
    "method": "GET",
    "uri": "/waf-healthz",
    "headers": { ... }
  },
  "status": 200,
  "resp_headers": { "Server": ["Caddy"] }
}
```

### Redacted Fields

The Caddyfile uses `format filter` to redact sensitive query parameters and headers:

| Redacted Query Params | Deleted Headers |
|-----------------------|-----------------|
| `access_token` | `Authorization` |
| `refresh_token` | `Proxy-Authorization` |
| `id_token` | `Cookie` |
| `code` | |
| `state` | |
| `password` | |
| `secret` | |

## Flux Kustomization Dependencies

```
flux-system
    │
    ▼
infra-controllers ──▶ infra-configs ──▶ taskflow-app
                                         (WAF + app manifests)
    │
    ▼
monitoring ──▶ monitoring-logging
               (Loki + Alloy + Grafana provisioning)
```

## Operational Commands

### Check WAF Status

```bash
# Pod status
kubectl get pods -n taskflow -l app.kubernetes.io/component=waf

# Deployment status
kubectl get deployment -n taskflow | grep waf

# Service endpoints
kubectl get svc -n taskflow | grep waf

# HTTPRoute status
kubectl get httproute taskflow-route -n taskflow

# Network policies
kubectl get ciliumnetworkpolicy -n taskflow
```

### Check Logging Stack

```bash
# Loki pods
kubectl get pods -n monitoring | grep loki

# Alloy pods
kubectl get pods -n monitoring | grep alloy

# Loki health
kubectl exec -n monitoring loki-0 -- wget -qO- http://localhost:3100/ready

# Query Loki labels
kubectl run loki-query --image=curlimages/curl --rm -i --restart=Never -n monitoring -- \
  curl -s 'http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/labels'

# Query WAF logs
kubectl run loki-query --image=curlimages/curl --rm -i --restart=Never -n monitoring -- \
  curl -s -G 'http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/query_range' \
  --data-urlencode 'query={job="coraza-waf"}' \
  --data-urlencode 'limit=5' \
  --data-urlencode "start=$(date -v-1H +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000"
```

### Test WAF Internally

```bash
# Frontend WAF health
kubectl run curl-test --rm -i --restart=Never -n taskflow --image=curlimages/curl -- \
  curl -s http://taskflow-frontend-waf.taskflow.svc.cluster.local:8080/waf-healthz

# Backend WAF health
kubectl run curl-test --rm -i --restart=Never -n taskflow --image=curlimages/curl -- \
  curl -s http://taskflow-backend-waf.taskflow.svc.cluster.local:8080/waf-healthz

# SQL injection test (DetectionOnly mode - should pass through)
kubectl run curl-test --rm -i --restart=Never -n taskflow --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}" \
  'http://taskflow-backend-waf.taskflow.svc.cluster.local:8080/api?test=1%20UNION%20SELECT%201'
```

### Reconcile

```bash
# WAF + app manifests
flux reconcile kustomization taskflow-app -n flux-system --with-source

# Logging stack
flux reconcile kustomization monitoring-logging -n flux-system --with-source

# Full stack
flux reconcile kustomization flux-system -n flux-system --with-source
```

### View Logs

```bash
# Frontend WAF logs
kubectl logs -n taskflow deploy/taskflow-frontend-waf

# Backend WAF logs
kubectl logs -n taskflow deploy/taskflow-backend-waf

# Alloy logs
kubectl logs -n monitoring deploy/alloy -c alloy
```

## Troubleshooting

### Image Pull Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `401 Unauthorized` | No pull secret or wrong credentials | Create `ghcr-pull-secret` with valid PAT |
| `403 Forbidden` | PAT lacks `read:packages` scope | Use PAT with `write:packages` scope |
| `no match for platform` | Image built for wrong architecture | Rebuild with `--platform linux/amd64` |
| `ImagePullBackOff` | Stale image reference | Delete pods to force re-pull |

### Container Runtime Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `exec /usr/bin/caddy: operation not permitted` | File capabilities on binary | Add `setcap -r /usr/bin/caddy` to Dockerfile |
| `container has runAsNonRoot and image has non-numeric user` | Missing `runAsUser` | Add `runAsUser: 100` to securityContext |
| `CreateContainerConfigError` | Volume mount or config issue | Check ConfigMap exists and keys match |

### Flux Reconciliation Issues

| Issue | Fix |
|-------|-----|
| Kustomization stuck | Check dependency chain: `flux get kustomizations` |
| SOPS decryption fails | Verify `sops-age` secret exists in `flux-system` namespace |
| Health check timeout | Check pod logs for startup errors |

### Logging Issues

| Issue | Fix |
|-------|-----|
| No logs in Loki | Verify Alloy is running and configured correctly |
| Dashboard shows no data | Check Loki datasource is provisioned (sidecar logs) |
| Missing labels | Verify Alloy relabel rules match pod labels |

## Security Considerations

- **Private GHCR image**: The WAF image is in a private repository, requiring authentication
- **Non-root execution**: WAF pods run as UID 100 (caddy user)
- **Read-only filesystem**: All containers use `readOnlyRootFilesystem: true`
- **Dropped capabilities**: All capabilities are dropped (`drop: ALL`)
- **Network isolation**: Each WAF can only reach its corresponding application service
- **No public exposure**: Loki and Alloy have no Gateway, LoadBalancer, or public route
- **Sensitive data redaction**: Caddy access logs redact credentials and tokens
- **Audit log privacy**: Coraza audit parts exclude request bodies and headers

## File Reference

| File | Purpose |
|------|---------|
| `gitops/images/taskflow-caddy-coraza/Dockerfile` | Custom Caddy+Coraza image build |
| `gitops/apps/taskflow/frontend-waf.yaml` | Frontend WAF ConfigMap, Deployment, Service |
| `gitops/apps/taskflow/backend-waf.yaml` | Backend WAF ConfigMap, Deployment, Service |
| `gitops/apps/taskflow/httproute.yaml` | HTTPRoute routing through WAF services |
| `gitops/apps/taskflow/namespace-default-deny.yaml` | CiliumNetworkPolicies for WAF |
| `gitops/monitoring/logging/repositories.yaml` | HelmRepos for Loki and Alloy |
| `gitops/monitoring/logging/loki-release.yaml` | Loki HelmRelease |
| `gitops/monitoring/logging/alloy-release.yaml` | Alloy HelmRelease with log collection |
| `gitops/monitoring/logging/grafana-provisioning.yaml` | Loki datasource + WAF and access-log dashboards |
| `gitops/monitoring/logging/vmservicescrapes.yaml` | VMServiceScrape for Loki/Alloy metrics |
| `gitops/clusters/taskflow/monitoring-logging.yaml` | Flux Kustomization for logging stack |
| `docs/TASKFLOW_WAF_RUNBOOK.md` | Operational runbook |
| `docs/CORAZA_CONFIGURATION.md` | Coraza/CRS tuning reference |
| `docs/TASKFLOW_WAF_ARCHITECTURE.md` | This document |
