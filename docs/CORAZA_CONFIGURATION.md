# Coraza WAF Configuration Guide

Reference for tuning and maintaining the Taskflow Caddy+Coraza WAF deployments.

## File Locations

| File | Path | Purpose |
|------|------|---------|
| Frontend Caddyfile + Coraza | `gitops/apps/taskflow/frontend-waf.yaml` (ConfigMap) | Main Caddyfile with inline Coraza directives |
| Backend Caddyfile + Coraza | `gitops/apps/taskflow/backend-waf.yaml` (ConfigMap) | Main Caddyfile with inline Coraza directives |
| Frontend exclusions | Same ConfigMap, key `frontend-exclusions.conf` | Empty until false positives are found |
| Backend exclusions | Same ConfigMap, key `backend-exclusions.conf` | Empty until false positives are found |

With `load_owasp_crs`, the connector merges the embedded CRS filesystem with the OS filesystem. `Include @...` loads from the embedded CRS; `Include /etc/coraza/...` loads from the mounted ConfigMap.

## Directive Load Order

```
directives `
    Include @coraza.conf-recommended     # 1. Coraza recommended base config
    SecRuleEngine On                     # 2. Engine mode (active blocking)
    SecAction "id:1000001,phase:1,pass,nolog,setvar:tx.paranoia_level=2" # Paranoia level 2
    SecRequestBodyAccess On              #    Body processing
    SecResponseBodyAccess Off            #    Response buffering (off)
    SecAuditEngine RelevantOnly          #    Audit logging
    SecAuditLog /var/run/coraza/audit.pipe #  Private audit-log pipe
    SecAuditLogFormat JSON               #    JSON audit records
    SecAuditLogParts ABFHZ               #    Rule-match metadata plus request/response headers
    SecRequestBodyLimit 10485760         #    Max request body (10 MB)
    SecRequestBodyNoFilesLimit 1048576   #    Max body without files (1 MB)

    Include /etc/coraza/frontend-exclusions.conf  # 4. Before-CRS exclusions

    Include @owasp_crs/*.conf            # 5. CRS rules (embedded)
`
```

## SecRuleEngine Modes

| Value | Effect |
|-------|--------|
| `DetectionOnly` | Runs all rules, logs matches, but never blocks. Use for initial rollout and tuning. |
| `On` | Enables blocking actions (`deny`, `drop`, `redirect`). Switch only after tuning is complete. |

Change mode in the `directives` block of the relevant WAF ConfigMap.

## Paranoia Level

Set via `SecAction` inside the `directives` block:

```
SecAction "id:1000001,phase:1,pass,nolog,setvar:tx.paranoia_level=2"
```

| Level | Description |
|-------|-------------|
| 1 | Minimal rules. Low false-positive rate. Recommended starting point. |
| 2 | Adds rules for more exotic attacks. Moderate false-positive risk. |
| 3 | Aggressive detection. High false-positive rate. Needs careful tuning. |
| 4 | Maximum paranoia. Not recommended for production. |

Raise one level at a time, observe detections, add exclusions, then raise again.

## Audit Log Parts

Configured by `SecAuditLogParts`. Each letter adds a section:

| Part | Content |
|------|---------|
| A | Audit log header (timestamp, parts) |
| B | Request headers |
| C | Request body |
| D | (Reserved, currently unused) |
| E | Request body after rules |
| F | Response headers |
| G | Response body |
| H | Audit log trailer, including matched-rule messages and metadata |
| I | Compact request body (multipart) |
| J | Uploaded file information |
| K | Matched rule IDs |
| L | Final boundary |
| M | Error messages |
| N | Phase 1 and 2 compressed output |
| O | Connection metadata |
| P | Protocol info |
| Q | Filename (if logged) |
| R | Non-standard response codes |
| S | Rule action messages |
| T | Timestamp |
| U | URI path |
| V | Protocol version |
| X | Request body inspection notes |
| Y | Response body inspection notes |
| Z | End of audit log entry |

Current setting: **`ABFHZ`** — includes request and response headers plus the `H`
rule-match metadata. Request bodies remain excluded. Coraza writes these records to a
shared named pipe; the `audit-log-redactor` sidecar removes inbound `Authorization`,
`Proxy-Authorization`, and `Cookie` headers and sensitive query parameters before
emitting JSON to stdout for Alloy. Raw audit records are neither persisted nor sent to
container stdout.

## SecAuditEngine

| Value | Behavior |
|-------|----------|
| `Off` | Never audit |
| `On` | Audit all requests |
| `RelevantOnly` | Audit only transactions with warnings/errors or matching `SecAuditLogRelevantStatus` |
| `Dynamic` | Per-transaction decision via `SecAuditEngine` rule action |

## Body Processing

| Directive | Value | Purpose |
|-----------|-------|---------|
| `SecRequestBodyAccess` | `On` | Enables body buffering and inspection |
| `SecResponseBodyAccess` | `Off` | Disables response body inspection (recommended for reverse proxy) |
| `SecRequestBodyLimit` | `10485760` | Max body size in bytes (10 MB). Larger bodies are partially inspected. |
| `SecRequestBodyNoFilesLimit` | `1048576` | Max non-file body size (1 MB) |
| `SecRequestBodyLimitAction` | `ProcessPartial` | Default. Inspects bytes within limit, sets `INBOUND_DATA_ERROR` if truncated. |

## Exclusion Files

Create false-positive exclusions in the ConfigMap keys. Two files control timing:

### Before-CRS (Runtime) Exclusions

File: `frontend-exclusions.conf` or `backend-exclusions.conf` (loaded before CRS rules).

Use these when you need to change the transaction before a rule runs:

```
# Exclude a specific field from SQL injection rule 942100 for POST /api/jobs
SecRule REQUEST_FILENAME "@beginsWith /api/jobs" \
    "id:1000100,phase:1,pass,nolog,t:none,chain"
    SecRule REQUEST_METHOD "@streq POST" \
        "t:none,ctl:ruleRemoveTargetById=942100;ARGS:message"
```

### After-CRS Exclusions

To use after-CRS exclusions, add a second `Include` line and a separate ConfigMap key:

```
Include /etc/coraza/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf
```

```
# Remove a cookie from rule 942100 everywhere
SecRuleUpdateTargetById 942100 "!REQUEST_COOKIES:campaign"
```

### Key Exclusion Actions

| Action | Purpose |
|--------|---------|
| `ctl:ruleRemoveTargetById=<id>;<target>` | Exclude a field from a specific rule |
| `ctl:ruleRemoveTargetByTag=<tag>;<target>` | Exclude a field from all rules with a tag |
| `ctl:ruleRemoveById=<id>` | Remove a rule entirely (use sparingly) |
| `ctl:ruleEngine=Off` | Disable engine for matching requests |

### Target Syntax

| Target | Description |
|--------|-------------|
| `ARGS:message` | A specific query/form parameter |
| `ARGS:/^json\.\d+\.jobdescription$/` | Regex match on parameter name |
| `REQUEST_COOKIES:session` | A specific cookie |
| `REQUEST_URI` | The request path |
| `REQUEST_FILENAME` | The request path without query string |
| `REQUEST_METHOD` | GET, POST, etc. |
| `!REQUEST_COOKIES:session` | Negate (remove from exclusion) |

## CRS Rule Families

| Rule ID Range | Attack Type |
|---------------|-------------|
| 913 | Scanner detection |
| 920-929 | Protocol enforcement (HTTP methods, headers) |
| 930-931 | Path traversal |
| 932-934 | Remote command execution |
| 941 | XSS (cross-site scripting) |
| 942 | SQL injection |
| 943 | Session fixation |
| 944 | Java attack detection |
| 949 | Inbound attack-score evaluation |
| 950-959 | Outbound attack detection |
| 959-959 | Outbound attack score blocking |

## Tuning Workflow

1. Run in `DetectionOnly` mode.
2. Query audit logs for detections:
    ```
    {job="coraza-waf", application="taskflow-frontend"} |= "\"messages\""
    ```
   A `transaction` without `messages[]` is a relevant audited response, not a CRS match.
3. Identify false positives from the sanitized audit log fields:
   - `rule_id`: which CRS rule matched
   - `variable_name`: which input triggered it (e.g., `ARGS:message`)
   - `matched_data`: the actual payload
4. Write the narrowest possible exclusion in the exclusion file.
5. Validate the Caddyfile locally:
   ```
   ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("data").fetch("Caddyfile")' \
     gitops/apps/taskflow/frontend-waf.yaml | \
      docker run --rm -i ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0-r1 \
     caddy validate --config /dev/stdin --adapter caddyfile
   ```
6. Reconcile and replay the test request. Confirm the false positive is gone and the rule still fires on other inputs.
7. Once clean, switch `SecRuleEngine` to `On` and repeat the replay tests.

## Client IP Forwarding

The WAF receives requests only from the Cilium Gateway. Its Caddy global options trust
the K3s Pod CIDR (`10.42.0.0/16`), parse `X-Forwarded-For` from right to left, and use only that
header to resolve `{client_ip}`. Each WAF writes that resolved value as `client_ip` in
the Caddy access log before Coraza executes, including blocked requests. The WAF also
passes `{client_ip}` upstream as `X-Real-IP`.
The HTTPRoute attaches application traffic exclusively to the HTTPS Gateway listener,
so each WAF explicitly passes `X-Forwarded-Proto: https` upstream. Do not widen the
trusted proxy CIDR without also tightening the WAF ingress policy.

## Documentation Links

- Coraza SecLang Reference: https://coraza.io/docs/seclang/directives/
- Coraza Body Processing: https://coraza.io/docs/reference/body-processing/
- CRS Setup File (all tunable knobs): https://github.com/corazawaf/coraza-coreruleset/blob/main/rules/@crs-setup.conf.example
- CRS Tuning Guide: https://coreruleset.org/docs/usage-tuning/
- Coraza Caddy Connector: https://github.com/corazawaf/coraza-caddy/blob/main/README.md
- Coraza + CRS on Caddy Tutorial: https://www.coraza.io/docs/tutorials/coreruleset/
- Peakhour Tuning Guide: https://www.peakhour.io/blog/how-to-tune-coraza-waf/
