# Coraza WAF Configuration Guide

Reference for tuning and maintaining the Taskflow Caddy+Coraza WAF deployments.

## File Locations

| File | Path | Purpose |
|------|------|---------|
| Frontend Caddyfile + Coraza | `gitops/apps/taskflow/frontend-waf.yaml` (ConfigMap) | Main Caddyfile with inline Coraza directives |
| Backend Caddyfile + Coraza | `gitops/apps/taskflow/backend-waf.yaml` (ConfigMap) | Main Caddyfile with inline Coraza directives |
| Frontend exclusions | Same ConfigMap, key `frontend-exclusions.conf` | Empty until false positives are found |
| Backend exclusions | Same ConfigMap, key `backend-exclusions.conf` | Empty until false positives are found |
| Rate-limit zones | Same ConfigMap, key `rate-limit.conf` | Per-client HTTP rate-limit zones imported by Caddyfile |

With `load_owasp_crs`, the connector merges the embedded CRS filesystem with the OS filesystem. `Include @...` loads from the embedded CRS; `Include /etc/coraza/...` loads from the mounted ConfigMap.

## Current Deployment Mode

> **Note:** The current deployment uses `SecRuleEngine On` with paranoia level 2 — matching rules can block requests. Treat the exclusion files as production controls and test changes against both WAFs before rollout.

## Directive Load Order

```
directives `
    Include @coraza.conf-recommended              # 1. Coraza recommended base config
    Include @crs-setup.conf.example               # 2. CRS setup defaults
    Include /etc/coraza/frontend-exclusions.conf  # 3. Before-CRS exclusions

    SecRuleEngine On                              # 4. Engine mode (active blocking)
    SecAction "id:1000001,phase:1,pass,nolog,setvar:tx.blocking_paranoia_level=2" # Paranoia level 2
    SecRequestBodyAccess On                       #    Body processing
    SecResponseBodyAccess Off                     #    Response buffering (off)
    SecAuditEngine RelevantOnly                   #    Audit logging
    SecAuditLog /dev/stdout                       #    Audit JSON to stdout (Alloy redacts credentials at ingest)
    SecAuditLogFormat JSON                        #    JSON audit records
    SecAuditLogParts ABFHZ                        #    Rule-match metadata plus request/response headers
    SecRequestBodyLimit 10485760                  #    Max request body (10 MB)
    SecRequestBodyNoFilesLimit 1048576            #    Max body without files (1 MB)

    Include @owasp_crs/*.conf                     # 5. CRS rules (embedded)
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
SecAction "id:1000001,phase:1,pass,nolog,setvar:tx.blocking_paranoia_level=2"
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
| A | Audit log header (mandatory) |
| B | Request headers |
| C | Request body (requires `SecRequestBodyAccess On`) |
| D | Reserved for intermediary response headers (not implemented) |
| E | Intermediary response body (requires `SecResponseBodyAccess On`) |
| F | Final response headers |
| G | Reserved for the actual response body (not implemented) |
| H | Audit log trailer, including matched-rule messages and metadata |
| I | Request body without file contents for multipart (not implemented) |
| J | Uploaded file information (Coraza v3.7.0+) |
| K | Every matched rule, in match order |
| Z | Final boundary, end of the entry (mandatory) |

Coraza accepts only these letters (see the `SecAuditLogParts` reference linked below).

Current setting: **`ABFHZ`** — includes request and response headers plus the `H`
rule-match metadata. Request bodies remain excluded. Coraza writes these records
directly to container stdout; Alloy replaces the `Authorization`,
`Proxy-Authorization`, `Cookie` and `Set-Cookie` header values, sensitive query
parameter values and the matched data of credential variables with `REDACTED`
while ingesting the records. No audit log file is written.

## SecAuditEngine

| Value | Behavior |
|-------|----------|
| `Off` | Never audit |
| `On` | Audit all requests |
| `RelevantOnly` | Audit only transactions with warnings/errors or matching `SecAuditLogRelevantStatus` |

To change it per transaction, use the `ctl:auditEngine=...` rule action.

## Body Processing

| Directive | Value | Purpose |
|-----------|-------|---------|
| `SecRequestBodyAccess` | `On` | Enables body buffering and inspection |
| `SecResponseBodyAccess` | `Off` | Disables response body inspection (recommended for reverse proxy) |
| `SecRequestBodyLimit` | `10485760` | Max body size in bytes (10 MB). Larger bodies are rejected (see below). |
| `SecRequestBodyNoFilesLimit` | `1048576` | Max non-file body size (1 MB) |
| `SecRequestBodyLimitAction` | `Reject` | Not set in the ConfigMaps; Coraza's default with `SecRuleEngine On`. Interrupts the transaction (HTTP 413). `ProcessPartial` (inspect up to the limit, set `INBOUND_DATA_ERROR`) applies only in `DetectionOnly` or when set explicitly. |

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

To use after-CRS exclusions, add a separate ConfigMap key and a second `Include`
line **after** `Include @owasp_crs/*.conf`. The Deployment's `coraza-config`
volume projects only the keys listed under its `items`, so add the new key there too:

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
| `REQUEST_URI` | The request path including the query string |
| `REQUEST_FILENAME` | The request path without query string |
| `REQUEST_METHOD` | GET, POST, etc. |
| `!REQUEST_COOKIES:session` | Negation in `SecRuleUpdateTargetById`: remove this target from the rule |

## CRS Rule Families

| Rule ID Range | Attack Type |
|---------------|-------------|
| 913 | Scanner detection |
| 920-922 | Protocol enforcement (920), protocol attacks (921), multipart attacks (922) |
| 930-931 | Local file inclusion / path traversal (930), remote file inclusion (931) |
| 932-934 | Remote command execution (932), PHP injection (933), generic/Node.js attacks (934) |
| 941 | XSS (cross-site scripting) |
| 942 | SQL injection |
| 943 | Session fixation |
| 944 | Java attack detection |
| 949 | Inbound attack-score evaluation |
| 950-956 | Outbound (response) data-leakage detection |
| 959 | Outbound attack-score evaluation |

## Tuning Workflow

1. Observe the current `On` mode and review detections.
2. Query audit logs for detections:
    ```
    {job="coraza-waf", application="taskflow-frontend"} |= "},\"messages\":[{"
    ```
   A `transaction` without `messages[]` is a relevant audited response, not a CRS match.
3. Identify false positives from the sanitized audit record (`messages[].error_message`):
   - `[id "N"]` (and the `rule_id` label): which CRS rule matched
   - `[data "Matched Data: <fragment> found within <VARIABLE>: <value>"]`: which input
     triggered it (e.g., `ARGS:message`) and the payload. For cookies, `Authorization`,
     request bodies and credential-named arguments (`password`, `token`, `secret`,
     `session`, ...) Alloy replaces fragment and value with `REDACTED` at ingest; the
     variable name stays. `[data]` is cut at 280 bytes.
4. Write the narrowest possible exclusion in the exclusion file.
5. Validate the Caddyfile locally. The image entrypoint is already `caddy`, the
   Caddyfile imports `/etc/caddy/rate-limit.conf`, and Coraza reads the
   exclusions file, so mount the extracted ConfigMap keys (the rate-limit file
   contains the active zones):
   ```
   tmp=$(mktemp -d) && mkdir -p "$tmp/caddy" "$tmp/coraza"
   ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("data").fetch("Caddyfile")' \
     gitops/apps/taskflow/frontend-waf.yaml > "$tmp/caddy/Caddyfile"
   ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("data").fetch("rate-limit.conf")' \
     gitops/apps/taskflow/frontend-waf.yaml > "$tmp/caddy/rate-limit.conf"
   ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("data").fetch("frontend-exclusions.conf")' \
     gitops/apps/taskflow/frontend-waf.yaml > "$tmp/coraza/frontend-exclusions.conf"
   # The image the Deployment pins (tag@digest)
   img=$(ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).compact.find { |d| d["kind"] == "Deployment" }.dig("spec", "template", "spec", "containers", 0, "image")' \
     gitops/apps/taskflow/frontend-waf.yaml)
   docker run --rm --platform linux/amd64 -v "$tmp/caddy:/etc/caddy:ro" -v "$tmp/coraza:/etc/coraza:ro" \
     "$img" validate --config /etc/caddy/Caddyfile --adapter caddyfile
   rm -rf "$tmp"
   ```
   `gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh` does the same
   for both WAFs (it also needs Helm and kubectl, for the dashboard checks).
6. Reconcile (Reloader rolls the WAF; see `docs/TASKFLOW_WAF_RUNBOOK.md` § "Apply Caddyfile changes") and replay the test request. Confirm the false positive is gone and the rule still fires on other inputs.
7. Reconcile and repeat the replay tests after every exclusion or CRS change.

## Client IP Forwarding

The WAF receives requests only from the Cilium Gateway. Caddy resolves `{client_ip}`
from `X-Forwarded-For` only, parsed right-to-left while skipping trusted hops
(`trusted_proxies_strict`). The trusted list contains the Cloudflare proxy ranges
(so the Cloudflare edge hop is skipped and the real visitor is selected) plus the
observed Cilium Envoy peer `/32` (`10.42.0.148/32`). `CF-Connecting-IP` is
deliberately **not** consulted: Envoy forwards a client-supplied value verbatim,
so on the direct-to-origin path it would let a client choose its own identity.

> **Peer range.** The Caddyfile trusts `10.42.0.148/32`, the node's `cilium_host`
> address that SNATs host→pod traffic (the Cilium Envoy dials the WAFs from the
> host namespace). It was verified from live access logs and
> `ip -4 addr show cilium_host` on 2026-09-26; re-verify with
> `docs/TASKFLOW_WAF_RUNBOOK.md` § Stage 0 if the node is replaced or identity
> resolution degrades. Do not widen it to the Pod CIDR — a pod that reaches the
> Gateway could then be skipped as a trusted hop.

Each WAF writes the resolved value as `client_ip` in the Caddy access log before
Coraza executes, including blocked requests, and passes `{client_ip}` upstream as
`X-Real-IP`. Coraza reads the same Caddy `client_ip` variable, so its audit
records and detections use the identical identity.
The HTTPRoute attaches application traffic exclusively to the HTTPS Gateway listener,
so each WAF explicitly passes `X-Forwarded-Proto: https` upstream. Do not widen the
trusted proxy CIDR without also tightening the WAF ingress policy.

IP reputation blocking (AbuseIPDB) is intentionally **not** implemented in
Coraza/Caddy: denylisted source IPs are rejected at the Cloudflare edge (proxied
traffic) and by Cilium on the direct path, before requests reach the WAF. See
`docs/ABUSEIPDB_CILIUM_BLOCKLIST.md`.

## Documentation Links

- Coraza SecLang Reference: https://coraza.io/docs/seclang/directives/
- Coraza Body Processing: https://coraza.io/docs/reference/body-processing/
- CRS Setup File (all tunable knobs): https://github.com/corazawaf/coraza-coreruleset/blob/main/rules/@crs-setup.conf.example
- CRS Tuning Guide: https://coreruleset.org/docs/usage-tuning/
- Coraza Caddy Connector: https://github.com/corazawaf/coraza-caddy/blob/main/README.md
- Coraza + CRS on Caddy Tutorial: https://www.coraza.io/docs/tutorials/coreruleset/
- Peakhour Tuning Guide: https://www.peakhour.io/blog/how-to-tune-coraza-waf/
