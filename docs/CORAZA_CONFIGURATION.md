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
| Coraza base config | Image: `/usr/share/coraza/coraza.conf-recommended` | Coraza's recommended configuration (`CORAZA_CONF_VERSION` in the image Dockerfile) |
| CRS setup + rules | Image: `/usr/share/coraza/crs/crs-setup.conf.example`, `/usr/share/coraza/crs/rules/*.conf` | OWASP CRS (`CRS_VERSION` in the image Dockerfile) |

All `Include` lines are plain filesystem paths: `/usr/share/coraza/...` comes from the image, `/etc/coraza/...` from the mounted ConfigMap. `load_owasp_crs` and the `@...` aliases are **not** used: they resolve against the bundle embedded in the `coraza-caddy` connector, which upstream froze at CRS 4.25.0 (see "CRS version" below).

## CRS version

| Pin (image `Dockerfile`) | Go module | Current | Line |
|---|---|---|---|
| `CRS_VERSION` | `github.com/corazawaf/coraza-coreruleset/lts/v4` | v4.25.2 | CRS 4.25 LTS: security and regression backports only, quarterly, until Q3 2027 |
| `CORAZA_CONF_VERSION` | `github.com/corazawaf/coraza-coreruleset/coraza/v3` | v3.8.1 | `coraza.conf-recommended` of the Coraza engine the connector compiles in |

- Renovate tracks both (`# renovate: datasource=go` above each `ARG`) and bumps `IMAGE_REVISION`, in a `WAF rule set` PR of their own that is **never automerged**, LTS patch releases included. The image build runs the behaviour tests, including the false-positive regression test below; read the PR against the CRS release notes and the test output, then merge. A new image is then proposed for both Deployments.
- The ConfigMaps need an image from `r15` on (the first with `/usr/share/coraza`). With an older image Caddy does not start (`open /usr/share/coraza/coraza.conf-recommended: no such file or directory`); "Validate WAF behaviour" runs the pinned image, so CI rejects that combination.
- The image build copies the files out of the Go modules (`go mod download`, verified against the Go checksum database). The behaviour tests assert that blocked requests are attributed to exactly the CRS version in the image, and that a request with more arguments than `SecArgumentsLimit` is rejected.
- Why not the embedded copy: `coraza-caddy` v2.6.2 embeds the legacy module `coraza-coreruleset/v4`, frozen at v4.25.0 — CRS 4.25.0 without the 4.25.1/4.25.2 bypass fixes, and a `coraza.conf-recommended` that predates Coraza 3.8's `SecArgumentsLimit` (without rules 200004/200005 arguments beyond the first 1000 were dropped silently, hiding a payload from the CRS). Later connector releases embed the *latest* CRS line (`crs/v4`) instead; the LTS line is never embedded. Loading from files keeps the rule set independent of the connector version.
- `tx.crs_xml_attr_inspect=1` (SecAction `1000002`): on the 4.25 LTS line the fix for GHSA-6jp8-c2w2-x7wr (XML attribute values were not inspected) is shipped switched **off**; this turns it on. Remove it when moving to a line without the switch.
- Moving to the latest CRS line: change the module in the Dockerfile (`ARG` comment and the `RUN` step) to `.../crs/v4`, whose files are named `@owasp_crs` and `@crs-setup.conf.example`. That line adds detections in every minor release (Renovate: minor, manual merge), so replay the tuning workflow below before merging; rule IDs removed in 4.30 (950010–956010) only matter for response inspection, which is off here.

## Current Deployment Mode

> **Note:** The current deployment uses `SecRuleEngine On` with paranoia level 2 — matching rules can block requests. Treat the exclusion files as production controls and test changes against both WAFs before rollout.

## Directive Load Order

```
directives `
    Include /usr/share/coraza/coraza.conf-recommended         # 1. Coraza recommended base config (image)
    Include /usr/share/coraza/crs/crs-setup.conf.example      # 2. CRS setup defaults (image)
    Include /etc/coraza/frontend-exclusions.conf  # 3. Before-CRS exclusions

    SecRuleEngine On                              # 4. Engine mode (active blocking)
    SecAction "id:1000001,phase:1,pass,nolog,setvar:tx.blocking_paranoia_level=2" # Paranoia level 2
    SecAction "id:1000002,phase:1,pass,nolog,setvar:tx.crs_xml_attr_inspect=1"    # LTS: inspect XML attribute values
    SecRequestBodyAccess On                       #    Body processing
    SecResponseBodyAccess Off                     #    Response buffering (off)
    SecAuditEngine RelevantOnly                   #    Audit logging
    SecAuditLog /dev/stdout                       #    Audit JSON to stdout (Alloy redacts credentials at ingest)
    SecAuditLogFormat JSON                        #    JSON audit records
    SecAuditLogParts ABFHZ                        #    Rule-match metadata plus request/response headers
    SecRequestBodyLimit 65536                     #    Max request body (64 KiB)
    SecRequestBodyInMemoryLimit 65536             #    Buffer it in memory (must be <= the limit)

    Include /usr/share/coraza/crs/rules/*.conf    # 5. CRS rules (image)
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

## Allowed Methods

CRS rule 911100 blocks every method outside `tx.allowed_methods` (default `GET HEAD POST OPTIONS`); it is a
critical rule, so one match reaches the blocking threshold. The backend WAF sets
`GET HEAD POST PUT DELETE OPTIONS` (SecAction `1000003`, directly after `SecRuleEngine On` in its
`directives` block; not shown in the frontend load order above) because the API uses `PUT` and `DELETE`; the
frontend WAF keeps the default. When the backend gains an endpoint with another method (for example
`PATCH`), add it there, or the WAF answers it with 403. The image test suite sends `PUT`, `DELETE` and
`PATCH` through the backend WAF.

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
| `SecRequestBodyLimit` | `65536` | Max body size in bytes (64 KiB), both WAFs. Bodies that reach it are rejected with 413 before any rule runs (see below). The API's requests are small JSON (the application's own nginx bounds `/api` bodies at 32k) and the static site receives none. |
| `SecRequestBodyNoFilesLimit` | not set | Coraza parses this directive but does not enforce it (`internal/corazawaf/waf.go`: "no logic based on it is implemented"), so it cannot be used to bound JSON bodies separately from uploads. |
| `SecRequestBodyInMemoryLimit` | `65536` | Bodies up to this size are buffered in memory, larger ones in `/tmp`. Coraza refuses to start if it is larger than `SecRequestBodyLimit` ("request body limit should be at least the memory limit"; `coraza.conf-recommended` sets 128 KiB), so lower both together. Equal to the limit: nothing is spooled to `/tmp`. |
| `SecRequestBodyLimitAction` | `Reject` | Not set in the ConfigMaps; Coraza's default with `SecRuleEngine On`. Interrupts the transaction (HTTP 413). `ProcessPartial` (inspect up to the limit, set `INBOUND_DATA_ERROR`) applies only in `DetectionOnly` or when set explicitly. |

The body limit is the main cost control of the WAF: the body is buffered and inspected in full, and that happens before
the rate limiter (`order coraza_waf first`). At paranoia level 2 inspection costs on the order of a CPU-second per 100 KiB
of argument data, so raise the limit only for a real need and only on the WAF that needs it.

## False-positive regression test

`gitops/images/taskflow-caddy-coraza/tests/benign-corpus.py`, run by `run-tests.sh` for both WAFs (so by the
image build and by "Validate WAF behaviour"), sends 45 legitimate requests shaped exactly like the ones
taskflow-enterprise sends (paths, methods and field names from its Angular `core/api` clients and Spring
request records; free text with the punctuation real names, reviews and admin text contain) and pins each
answer:

- `PASS`: the request must reach the backend. A 403 here is a new false positive and fails CI.
- `fp(...)`: a known false positive that the shipped rule set blocks today, with the matching rule IDs and a
  `TODO(W-6)`. It must stay 403, so an update that changes detection in either direction fails CI and gets
  read by a person. Six are known (review comments, catalog name/description, a time-off reason, a booking
  of a service whose name has `&` and parentheses), identical on CRS 4.25.0 and 4.25.2 (BACKLOG SEC-21).

After a failing run, the test prints the rule IDs each case matched (from the audit log's `X-Corpus-Case`
request header). When you add an exclusion for a known false positive, change that case to `PASS` in the same
commit. When the app gains an endpoint or a free-text field, add a case.

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
line **after** `Include /usr/share/coraza/crs/rules/*.conf`. The Deployment's `coraza-config`
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
- CRS Setup File (all tunable knobs): `/usr/share/coraza/crs/crs-setup.conf.example` in the image; upstream: https://github.com/coreruleset/coreruleset/blob/lts/v4.25.x/crs-setup.conf.example
- CRS / Coraza config Go modules (one per bundle): https://github.com/corazawaf/coraza-coreruleset
- CRS LTS policy and releases: https://coreruleset.org/20260321/announcing-crs-v4-25-lts/
- CRS Tuning Guide: https://coreruleset.org/docs/usage-tuning/
- Coraza Caddy Connector: https://github.com/corazawaf/coraza-caddy/blob/main/README.md
- Coraza + CRS on Caddy Tutorial: https://www.coraza.io/docs/tutorials/coreruleset/
- Peakhour Tuning Guide: https://www.peakhour.io/blog/how-to-tune-coraza-waf/
