# Taskflow WAF & Logging Architecture

## Overview

Taskflow uses a **Caddy + Coraza WAF** (Web Application Firewall) to inspect all incoming HTTP traffic before it reaches the application services. Coraza runs as a Coraza-Caddy plugin, using the **OWASP Core Rule Set (CRS)** to detect and optionally block common web attacks (SQL injection, XSS, path traversal, etc.). Caddy additionally enforces **per-client HTTP rate limiting** (HTTP 429, `caddy-ratelimit`): frontend `general` 180/min and backend `api` 300/min, enabled 2026-09-26 after the live client-IP verification passed. Rate limiting complements — and does not replace — IP reputation enforcement (Cloudflare edge + Cilium) or CRS inspection. See [Rate Limiting](#rate-limiting).

Audit logs, access logs (including rate-limit 429s), and Coraza records from the WAFs are collected by **Grafana Alloy**, stored in **Grafana Loki** (30-day retention), and visualized in Grafana dashboards.

> **IP reputation is not a WAF concern here.** Known-malicious source IPs are
> enforced **before** this stack: at the Cloudflare edge for proxied traffic
> (IP list + WAF block rule) and by Cilium on the direct path
> (`CiliumCIDRGroup` + `CiliumClusterwideNetworkPolicy`). The AbuseIPDB feed is
> deliberately not loaded into Caddy/Coraza. See
> `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`.

> **Status update:** Coraza writes audit JSON directly to container stdout (`SecAuditLog /dev/stdout`); the previous FIFO plus `audit-log-redactor` sidecar was removed because a stalled reader could block every audited request while `/waf-healthz` stayed green. Credential redaction now happens at ingest in Alloy. Caddy runs with `admin off`, so **Caddyfile changes require a manual rollout restart** (see the runbook).

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
          │ + rate   │ │ + rate   │    │
          │   limit  │ │   limit  │    │
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
         ┌────▼──────────────────────────────────┐
         │  Observability Stack                  │
         │  Alloy → Loki → Grafana              │
         │  (job="coraza-waf")                   │
         │  Dashboards: /d/taskflow-waf,         │
         │              /d/taskflow-rate-limits  │
         └──────────────────────────────────────┘
```

## Components

| Component | Namespace | Version | Purpose |
|-----------|-----------|---------|---------|
| Caddy | `taskflow` | 2.11.4 | HTTP server + reverse proxy |
| Coraza | `taskflow` | v2.6.0 | WAF engine (OWASP ModSecurity compatible) |
| OWASP CRS | `taskflow` | v4.25.0 | Core Rule Set for attack detection |
| caddy-ratelimit | `taskflow` | commit `5625512f24` | Sliding-window per-client HTTP rate limiting (429) |
| Alloy | `monitoring` | 1.12.1 (chart) | Log collection agent |
| Loki | `monitoring` | 18.12.1 (chart) | Log aggregation and storage |
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
| `taskflow-backend-waf` | `backend.taskflow.svc.cluster.local:8080` | HTTP/1.1 |

## Image

The custom Caddy+Coraza image is built from the repository Dockerfile and pushed
to GHCR. Builds are automated by
`.github/workflows/build-taskflow-caddy-coraza.yaml` for changes under
`gitops/images/taskflow-caddy-coraza/`; the manual steps below remain available
as a fallback:

- **Repository**: `ghcr.io/stefanf81/taskflow-caddy-coraza`
- **Tag**: `2.11.4-coraza2.6.0-r3`
- **Digest**: `sha256:944074acac9fcc9fbeaf1aed373a283dfe579086414ad75948fb1f012512f6bd` (pinned in both WAF Deployments)
- **Dockerfile**: `gitops/images/taskflow-caddy-coraza/Dockerfile`
- **Platform**: `linux/amd64` (k3s node architecture)
- **Modules**: `github.com/corazawaf/coraza-caddy/v2@v2.6.0`, `github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db`

### Build & Push (Manual)

The image can be built manually when `gitops/images/taskflow-caddy-coraza/`
changes:

The release tag is derived from the Dockerfile's `CADDY_VERSION`,
`CORAZA_CADDY_VERSION`, and `IMAGE_REVISION` arguments. Increment
`IMAGE_REVISION` for recipe-only changes so immutable revision tags are never
overwritten. A publishing account needs package write permission; the pull secret
used by the cluster needs only package read permission.

`github.com/mholt/caddy-ratelimit` has no tagged release with `ipv4_prefix`/
`ipv6_prefix`, `disable_metrics`, or the metrics re-registration fix, so
`RATE_LIMIT_VERSION` pins an immutable commit instead of a tag.

Manual local build if needed:

```bash
docker buildx build --platform linux/amd64 --load \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 \
  gitops/images/taskflow-caddy-coraza/

# Authenticate to GHCR (requires write:packages scope)
read -r -s GITHUB_TOKEN
echo "$GITHUB_TOKEN" | docker login ghcr.io -u stefanf81 --password-stdin
unset GITHUB_TOKEN

docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3

# Verify both modules and get the digest for pinning
docker run --rm ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3 list-modules \
  | grep -E 'http.handlers.waf|http.handlers.rate_limit'
docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.6.0-r3
```

### Image Build Details

The Dockerfile uses a multi-stage build:

1. **Builder stage**: Uses `caddy:2.11.4-builder-alpine` to compile Caddy with the Coraza WAF plugin and the rate-limit plugin via `xcaddy` (`http.handlers.waf`, `http.handlers.rate_limit`)
2. **Runtime stage**: Based on `caddy:2.11.4-alpine`, copies the compiled binary
3. **Key steps**:
    - `setcap -r /usr/bin/caddy` — strips file capabilities (required for `allowPrivilegeEscalation: false`)
    - Creates `caddy` user (UID 100) for non-root execution
    - Adds `jq` (kept for ad-hoc debugging; the audit pipeline no longer needs it)
    - Exposes port 8080

### Automated tests

`gitops/images/taskflow-caddy-coraza/tests/` builds a disposable Docker network
that mirrors the production chain — client → Cloudflare edge sim → Cilium Envoy
sim → Caddy → upstream — and runs the **production Caddyfile** (extracted from
the WAF ConfigMaps, with only the trusted list and upstream target substituted).
It asserts:

- both the shipped config and a test-window config pass `caddy validate`, and
  the two WAF ConfigMaps carry identical trusted-proxy lists;
- proxied clients resolve to their real address;
- forged `X-Forwarded-For` / `CF-Connecting-IP` cannot win the identity, on both
  the proxied and direct paths;
- an address that is not in the trusted list (e.g. a pod) is **not** skipped, so
  it cannot spoof a forged value to its left;
- exceeding the window returns 429 with `Retry-After`, allowed requests reach
  the upstream exactly once, another client is unaffected, `/waf-healthz` stays
  available, and the 429 access log carries `rate_limit_zone`;
- Coraza still blocks a SQLi probe in the same fixed image.

The workflow runs the suite on every PR and before any publish, and skips the
push when the revision tag already exists (bump `IMAGE_REVISION` to publish).

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

### Volume Mounts

| Mount Path | Source | Purpose |
|------------|--------|---------|
| `/etc/caddy` | ConfigMap (Caddyfile) | Caddy configuration |
| `/etc/coraza` | ConfigMap (exclusions) | Coraza exclusion rules |
| `/data` | emptyDir | Caddy data storage |
| `/config` | emptyDir | Caddy runtime config |
| `/tmp` | emptyDir | Temporary files |

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

    SecRuleEngine On                      # Engine mode (blocking)
    SecAction "id:1000001,..."           # Paranoia level + tuning
    SecRequestBodyAccess On              # Body inspection
    SecResponseBodyAccess Off            # Response buffering off
    SecAuditEngine RelevantOnly          # Audit logging
    SecAuditLog /dev/stdout               # Audit JSON to container stdout
    SecAuditLogParts ABFHZ               # Includes matched-rule metadata
    SecRequestBodyLimit 10485760         # 10 MB max body
    SecRequestBodyNoFilesLimit 1048576   # 1 MB max non-file body

    Include @owasp_crs/*.conf            # CRS rules (embedded)
`
```

### SecRuleEngine Modes

| Mode | Effect |
|------|--------|
| `DetectionOnly` | Logs matches but never blocks |
| `On` | Enables blocking (current setting) |

### Paranoia Level

| Level | Description |
|-------|-------------|
| 1 | Minimal rules, low false-positive rate |
| 2 | More exotic attack detection, moderate false-positive risk |
| 3 | Aggressive, high false-positive rate |
| 4 | Maximum, not recommended for production |

### Audit Log Parts

Current: **ABFHZ** (request headers, response headers, matched-rule metadata, end
marker). It excludes request bodies. Coraza writes the records straight to stdout;
Alloy redacts inbound credential headers and sensitive query parameter values at
ingest (see `gitops/monitoring/logging/alloy-release.yaml`).

| Part | Content |
|------|---------|
| A | Audit log header |
| B | Request headers |
| C | Request body |
| K | Matched rule IDs |
| Z | End of audit log entry |

## Rate Limiting

Caddy enforces a sliding-window request limit per real client IP using
[`caddy-ratelimit`](https://github.com/mholt/caddy-ratelimit), built into the
same xcaddy image as Coraza (pinned commit
`5625512f24f6f59d6f64fb3aafe5eecff0b286db`). Exceeding a zone returns
**HTTP 429** with a `Retry-After` header.

> **Status: enforcement is ON** (since 2026-09-26). The zones live in the
> ConfigMap's `rate-limit.conf` key, imported by the Caddyfile. They were enabled
> only after the trusted proxy range was narrowed to the observed Envoy peer
> (`10.42.0.148/32`) plus the Cloudflare ranges and the client-IP canaries
> passed. The re-verification procedure and rollback are in
> `docs/TASKFLOW_WAF_RUNBOOK.md` § "Rate limiting".

### Zones

| WAF | Zone | Key | Limit | Window | IPv6 grouping |
|-----|------|-----|-------|--------|---------------|
| `taskflow-frontend-waf` | `general` | `{client_ip}` | 180 requests | 60s | `/64` |
| `taskflow-backend-waf` | `api` | `{client_ip}` | 300 requests | 60s | `/64` |

### How `{client_ip}` is derived

Caddy parses **`X-Forwarded-For` only**, right-to-left, skipping trusted hops
(`trusted_proxies_strict`). The trusted list contains:

- the **Cloudflare proxy ranges** (snapshot of Cloudflare's published lists, kept
  in Git), so the Cloudflare edge hop is skipped and the real visitor is used;
- the **observed Cilium Envoy peer** (`10.42.0.148/32`, the node's `cilium_host`
  address, verified 2026-09-26) so Caddy parses headers at all. It is a /32, not
  the Pod CIDR: trusting the pod network would let a pod that reaches the Gateway
  be skipped as a trusted hop and a forged address to its left selected. Re-verify
  if the node is replaced (runbook Stage 0).

`CF-Connecting-IP` is deliberately **not** consulted: Cilium Envoy forwards a
client-supplied value verbatim, so on the direct-to-origin path it would let a
client choose its own limiter identity. The right-to-left `X-Forwarded-For` walk
is robust to forged prefixes because Cloudflare and Envoy *append* the real
connecting address after any client-supplied values.

Coraza reads the same resolved `client_ip` variable, so WAF audit records and the
limiter always agree on the visitor identity.

### Zones: operational notes

- IPv6 addresses are masked to `/64` before keying, so rotating addresses within
  one prefix cannot mint new buckets.
- Limits are per Caddy replica and held in memory (there is exactly one replica
  per WAF and no shared Caddy storage), so no distributed mode, Redis, or extra
  datastore is involved.
- `/waf-healthz` is served by its own handler before the rate-limited handler
  and is never counted. Kubernetes probes therefore cannot trip the limiter.
- Rate limiting protects the *applications* from abusive request volume. It is
  deliberately keyed on the network client, not user identity: per-account
  quotas (e.g. "100 API calls/day per user") belong in the application/API layer.
- The long-lived SSE endpoint `/api/v1/appointments/events` counts as one event
  per connection, so the backend `api` zone does not interfere with the stream.

### Handler Order

```
log_append (client_ip, rate_limit_zone)  →  coraza_waf (CRS)  →  rate_limit (429)  →  reverse_proxy
```

`order coraza_waf first` is intentionally unchanged, so **Coraza always runs
before the limiter**. A rate-limited request has therefore already consumed WAF
inspection CPU; the AbuseIPDB/Cilium and Cloudflare layers drop known-bad
sources earlier, which keeps obvious floods away from Caddy entirely. Correct
WAF behavior takes priority over saving CPU.

Two access-log fields make rejections attributable:

| Field | Set by | Notes |
|-------|--------|-------|
| `client_ip` | `log_append <client_ip` (early) | Resolved visitor, present even when Coraza interrupts |
| `rate_limit_zone` | `log_append rate_limit_zone` (late) | `general`/`api` when the limiter rejected; empty otherwise |

`is_interrupted: true` in Coraza audit records identifies WAF blocks. HTTP 403 is
**not** used as the WAF signal: applications can legitimately return 403 too.

### Metrics and cardinality

The image does **not** expose Caddy metrics (no `metrics` global option, no
Prometheus scrape). The plugin is configured with `disable_metrics` as a
safeguard, because its Prometheus collectors label every series with the
rate-limit key — for `{client_ip}` that would create one time series per
Internet client. Do not enable Caddy metrics without accounting for that.
Individual 429 events are observed through the access logs → Loki path instead
(see [Rate Limits Dashboard](#rate-limits-dashboard)).

### Performance notes

The limiter is a map lookup plus a ring-buffer reservation and runs *after*
Coraza, so its CPU cost is negligible compared with CRS inspection. Memory is
`O(max_events × distinct keys)`; expired limiters are swept every minute. Watch
the WAF pod CPU/memory panels on the Taskflow WAF dashboard after rollout.

### Disable / rollback

Enforcement lives entirely in the ConfigMap `rate-limit.conf` key. Disabling it
does not touch Cilium, Gateway API, Coraza, CRS, or the applications:

1. Comment out or delete the `rate_limit` block in the `rate-limit.conf` keys of
   `gitops/apps/taskflow/{frontend,backend}-waf.yaml`.
2. `flux reconcile kustomization taskflow-app -n flux-system --with-source`
3. `kubectl -n taskflow rollout restart deployment/taskflow-backend-waf deployment/taskflow-frontend-waf`
   (Caddy runs with `admin off`; a ConfigMap change alone does not reload it).
4. After the rollout Caddy runs without the limiter. The image can stay at `r3`
   — the module is simply unused.

Keep the narrowed trusted-proxy configuration during rollback. To roll the image
back as well, restore the previous digest in both WAF Deployments.

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
| `container` | `waf` (both Caddy access logs and Coraza audit records) |
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
| Detections by paranoia level | pie chart | Loki | Grouped by `paranoia-level/1`, `paranoia-level/2`, `paranoia-level/3`, and `paranoia-level/4` tags |
| Top source IPs | table | Loki | `topk(10, sum by (transaction_client_ip) (count_over_time({job="coraza-waf"} |= "\"messages\"" | json [${__range}])))` |
| Recent WAF detections | logs | Loki | `{job="coraza-waf"} |= "\"messages\"" | json | regexp ... | line_format "{{.transaction_request_method}} {{.transaction_request_uri}} [rule={{.rule_id}}: {{.rule_msg}}] ip={{.transaction_client_ip}}"` |
| SQL injection detections | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf", rule_id=~"94[0-9]{4}"}[5m]))` |
| XSS, command injection, path traversal | timeseries | Loki | `sum by (application) (count_over_time({job="coraza-waf", rule_id=~"941[0-9]{3}|93[0-4][0-9]{3}"}[5m]))` |
| WAF block rate | stat | Loki | `(sum(count_over_time({job="coraza-waf"} |= "\"is_interrupted\":true" [$__range])) / sum(count_over_time({job="coraza-waf"} |= "\"messages\"" [$__range]))) * 100` |
| Top targeted URIs | table | Loki | `topk(10, sum by (transaction_request_uri) (count_over_time({job="coraza-waf"} |= "\"messages\"" | json [$__range])))` |
| Top attacking user agents | table | Loki | `topk(10, sum by (user_agent) (count_over_time({job="coraza-waf"} |= "\"messages\"" | json | user_agent := transaction_request_headers_user_agent [$__range])))` |
| WAF inspection latency (p95) | timeseries | Loki | `quantile_over_time(0.95, {job="coraza-waf"} |= "\"stopwatch\"" | regexp "combined=(?P<waf_latency_ns>[0-9]+)" | unwrap waf_latency_ns / 1000000 [$__interval])` |
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
The value is derived from the right-to-left `X-Forwarded-For` walk (trusted hops
skipped) received from the Cilium Gateway; `CF-Connecting-IP` is not consulted.
It is parsed at query time and is not a Loki label. Coraza audit records
continue to expose the same value as `transaction_client_ip` for `RelevantOnly`
transactions. The rate limiter uses the same `{client_ip}` as its key, and
rejections additionally carry the `rate_limit_zone` field.

### Rate Limits Dashboard

**Dashboard**: "Taskflow Rate Limits" (`/d/taskflow-rate-limits`)

Provisioned by `gitops/monitoring/logging/grafana-provisioning.yaml` and derived
entirely from Caddy access logs in Loki (`status=429`). It shows rate-limited
requests for 5m/1h/24h, 429 rate over time by application, WAF 403 blocks vs
rate-limit 429s, total Caddy request rate, and the top paths / client IPs / hosts
receiving 429. Client IPs and URIs are parsed at query time (`| json`) and are
not Loki labels, so no high-cardinality series are created.

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

# Detections introduced by paranoia level 2 (rules ignored on PL 1)
{job="coraza-waf"} |= "\"messages\"" |= "paranoia-level/2"

# Rate-limited requests (HTTP 429) with the resolved client IP
{job="coraza-waf", container="waf"} | json | __error__="" | status=429
  | line_format `{{.status}} {{.request_method}} {{.request_uri}} ip={{.client_ip}}`

# Top client IPs receiving 429 (query-time aggregation, not a Loki label)
topk(10, sum by (client_ip) (
  count_over_time({job="coraza-waf", container="waf"} | json | __error__="" |
    status=429 | client_ip != "" [24h])
))
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

A test pod cannot reach the WAF Services directly: `allow-gateway-to-waf` admits
only the Gateway/Envoy (`reserved:ingress`) identity. Use `kubectl port-forward`
(node-originated traffic is allowed by the network policy):

```bash
# Frontend WAF health
kubectl -n taskflow port-forward svc/taskflow-frontend-waf 8080:8080 &
PF=$!; sleep 1
curl -s http://localhost:8080/waf-healthz
kill "$PF"

# Backend WAF health
kubectl -n taskflow port-forward svc/taskflow-backend-waf 8081:8080 &
PF=$!; sleep 1
curl -s http://localhost:8081/waf-healthz
kill "$PF"

# SQL injection test (blocking mode - may return a WAF block status)
kubectl -n taskflow port-forward svc/taskflow-backend-waf 8082:8080 &
PF=$!; sleep 1
curl -s -o /dev/null -w "%{http_code}" \
  'http://localhost:8082/api?test=1%20UNION%20SELECT%201'
kill "$PF"
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
- **Audit log privacy**: Coraza audit parts exclude request bodies; Alloy removes sensitive request headers and query parameters at ingest
- **Rate-limit identity**: The limiter keys on Caddy's validated `{client_ip}`, resolved from `X-Forwarded-For` only, right-to-left, skipping the Cloudflare ranges and the trusted peer (`10.42.0.148/32`, the node's `cilium_host` address). `CF-Connecting-IP` is ignored, so a direct-to-origin client cannot choose its identity through it; forged `X-Forwarded-For` prefixes are ignored because Cloudflare and Envoy append the real connecting address. `trusted_proxies_strict` makes the trust check mandatory (an untrusted peer yields no header parsing at all). Because the peer entry is a /32 rather than the Pod CIDR, an in-cluster pod that reaches the Gateway is not skipped as a trusted hop. Re-verify the peer with the runbook Stage 0 if the node is replaced. IP reputation blocking at Cloudflare/Cilium remains the outer layer.
- **Not an account quota**: Rate limiting is per network client and cannot enforce per-user entitlements; those belong in the application/API layer

## File Reference

| File | Purpose |
|------|---------|
| `gitops/images/taskflow-caddy-coraza/Dockerfile` | Custom Caddy+Coraza+rate-limit image build |
| `gitops/images/taskflow-caddy-coraza/tests/` | Identity and rate-limit test suite (CI + local) |
| `gitops/apps/taskflow/frontend-waf.yaml` | Frontend WAF ConfigMap, Deployment, Service |
| `gitops/apps/taskflow/backend-waf.yaml` | Backend WAF ConfigMap, Deployment, Service |
| `gitops/apps/taskflow/httproute.yaml` | HTTPRoute routing through WAF services |
| `gitops/apps/taskflow/namespace-default-deny.yaml` | CiliumNetworkPolicies for WAF |
| `gitops/monitoring/logging/repositories.yaml` | HelmRepos for Loki and Alloy |
| `gitops/monitoring/logging/loki-release.yaml` | Loki HelmRelease |
| `gitops/monitoring/logging/alloy-release.yaml` | Alloy HelmRelease with log collection |
| `gitops/monitoring/logging/grafana-provisioning.yaml` | Loki datasource + WAF, access-log, and rate-limit dashboards |
| `gitops/monitoring/logging/vmservicescrapes.yaml` | VMServiceScrape for Loki/Alloy metrics |
| `gitops/clusters/taskflow/monitoring-logging.yaml` | Flux Kustomization for logging stack |
| `docs/TASKFLOW_WAF_RUNBOOK.md` | Operational runbook |
| `docs/CORAZA_CONFIGURATION.md` | Coraza/CRS tuning reference |
| `docs/TASKFLOW_WAF_ARCHITECTURE.md` | This document |
