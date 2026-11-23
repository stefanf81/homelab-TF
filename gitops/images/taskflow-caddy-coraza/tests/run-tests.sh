#!/usr/bin/env bash
#
# Identity and rate-limit tests for the taskflow-caddy-coraza image.
#
# Builds a disposable Docker network that mirrors the production request chain:
#
#   client -> edge (Cloudflare sim) -> envoy (Cilium Envoy sim) -> caddy -> upstream
#
# and asserts against the *production* Caddyfile extracted from the WAF
# ConfigMaps, substituting only the trusted_proxies list and the upstream target
# for the test topology. The production list itself is checked statically
# (check_trusted_lists). The shipped rate-limit zones are used as they are,
# with only their `events` and `window` shrunk (patch-rate-limit.py) so the
# suite runs in seconds: zone names, keys, match blocks and IPv6 grouping are
# the production ones.
#
# Usage: [TEST_IMAGE=<image>] ./run-tests.sh
# Without TEST_IMAGE each WAF is tested with the image its Deployment pins
# (what a ConfigMap-only change will run on); the image build sets TEST_IMAGE to
# the freshly built image.
# Requires: docker, python3 with PyYAML (used to extract the ConfigMaps).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

deployment_image() { # waf
  python3 - "$REPO_ROOT/gitops/apps/taskflow/$1-waf.yaml" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as fh:
    dep = next(d for d in yaml.safe_load_all(fh) if d and d.get("kind") == "Deployment")
print(next(c["image"] for c in dep["spec"]["template"]["spec"]["containers"] if c["name"] == "waf"))
PY
}

TEST_IMAGE="${TEST_IMAGE:-}"

NET="lrtest-$$"
NAME_PREFIX="$NET-"
SUBNET="172.31.240.0/24"
# Fixed addresses on the test network.
CA="172.31.240.10"     # external client A (identity tests)
CA2="172.31.240.12"    # external client A (enforcement tests, fresh bucket)
CB="172.31.240.11"     # external client B
POD="172.31.240.13"    # simulated in-cluster pod
HZ="172.31.240.14"     # health check / Coraza client
CA3="172.31.240.15"    # external client for the authentication-zone test
CA4="172.31.240.16"    # external client for the IPv6 /64 grouping test
EDGE="172.31.240.20"   # simulated Cloudflare edge
ENVOY="172.31.240.30"  # simulated Cilium Envoy
CADDY="172.31.240.40"
UPSTREAM="172.31.240.50"
# Mirrors the target production posture: Cloudflare edge + a single Envoy /32,
# no pod network. This is what makes the pod-path spoof test meaningful.
TRUSTED="$EDGE/32 $ENVOY/32"

WORK="$(mktemp -d)"
CONTAINERS=()

cleanup() {
  for cid in "${CONTAINERS[@]:-}"; do docker rm -f "$cid" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say()  { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

json_field() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"
}

body_field() {
  python3 -c 'import json,sys; print(json.loads(json.loads(sys.argv[1])["body"]).get(sys.argv[2],""))' "$1" "$2"
}

start_python() { # name ip command...
  local name="$1" ip="$2"; shift 2
  local cid
  cid="$(docker run -d --name "$name" --network "$NET" --ip "$ip" -v "$HERE:/srv:ro" \
    python:3.12-alpine "$@")"
  CONTAINERS+=("$cid")
}

start_client() { # name ip
  start_python "$1" "$2" python3 -c 'import time; time.sleep(3600)'
}

req() { # client-container [-X METHOD] url [Header: value ...]
  local c="$1"; shift
  docker exec "$c" python3 /srv/client.py "$@"
}

upstream_count() { # container key
  docker exec -e KEY="$2" "$1" python3 -c \
    'import json,os,urllib.request; print(json.loads(urllib.request.urlopen("http://127.0.0.1:8080/__count").read()).get(os.environ["KEY"],0))'
}

teardown_suite() {
  for cid in "${CONTAINERS[@]:-}"; do docker rm -f "$cid" >/dev/null 2>&1 || true; done
  CONTAINERS=()
}

# The behavioural suite replaces trusted_proxies with the test topology, so the
# production list is checked here instead: both ConfigMaps must carry the same
# list (the Cloudflare ranges are duplicated), and every private address in it
# must be a single host. Trusting a wider private range (the Pod CIDR, a node
# subnet) would let an in-cluster client be skipped as a trusted hop and forge
# its X-Forwarded-For identity.
check_trusted_lists() {
  python3 - "$REPO_ROOT/gitops/apps/taskflow/frontend-waf.yaml" \
            "$REPO_ROOT/gitops/apps/taskflow/backend-waf.yaml" <<'PY'
import ipaddress
import re
import sys

import yaml


def trusted(path):
    with open(path) as fh:
        cm = next(d for d in yaml.safe_load_all(fh) if d and d.get("kind") == "ConfigMap")
    m = re.search(r"trusted_proxies static (.*?)\n\s+trusted_proxies_strict", cm["data"]["Caddyfile"], re.S)
    return sorted(m.group(1).replace("\\", " ").split())


front, back = trusted(sys.argv[1]), trusted(sys.argv[2])
if front != back:
    print("trusted_proxies lists differ between the WAF ConfigMaps; update both together", file=sys.stderr)
    raise SystemExit(1)
wide = [e for e in front
        if ipaddress.ip_network(e, strict=False).is_private
        and ipaddress.ip_network(e, strict=False).num_addresses > 1]
if wide:
    print(f"trusted_proxies trusts private ranges wider than one address: {wide}", file=sys.stderr)
    raise SystemExit(1)
print(f"trusted_proxies lists match ({len(front)} entries; private entries are single hosts)")
PY
}

run_suite() { # waf
  local waf="$1"
  local image="${TEST_IMAGE:-$(deployment_image "$waf")}"
  local cfg="$WORK/$waf"
  local zone=general
  [ "$waf" = backend ] && zone=api
  local upstream="${NAME_PREFIX}upstream" edge="${NAME_PREFIX}edge" envoy="${NAME_PREFIX}envoy"
  local caddy="${NAME_PREFIX}caddy" ca="${NAME_PREFIX}ca" ca2="${NAME_PREFIX}ca2" cb="${NAME_PREFIX}cb"
  local ca3="${NAME_PREFIX}ca3" ca4="${NAME_PREFIX}ca4"
  local podclient="${NAME_PREFIX}pod" hzclient="${NAME_PREFIX}hz"
  mkdir -p "$cfg"

  python3 "$HERE/gen-config.py" \
    "$REPO_ROOT/gitops/apps/taskflow/$waf-waf.yaml" "$cfg" "$waf" "$TRUSTED" "$upstream"

  # First validate the config exactly as Git ships it (production zones): a typo
  # in the import or rate-limit.conf must fail CI here.
  say "$waf: validating shipped config with $image"
  docker run --rm -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" \
    "$image" validate --config /etc/caddy/Caddyfile --adapter caddyfile \
    >/dev/null 2>&1 || fail "$waf: caddy validate rejected the production config"

  # Shrink the shipped zones for the test only (events and window), with a
  # window long enough that a slow runner cannot slide it during the burst.
  # Everything else in rate-limit.conf is tested as shipped.
  if [ "$waf" = backend ]; then
    python3 "$HERE/patch-rate-limit.py" "$cfg/caddy/rate-limit.conf" 5m api=5 authentication=3
  else
    python3 "$HERE/patch-rate-limit.py" "$cfg/caddy/rate-limit.conf" 5m general=5
  fi

  say "$waf: validating generated Caddyfile"
  docker run --rm -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" \
    "$image" validate --config /etc/caddy/Caddyfile --adapter caddyfile \
    >/dev/null 2>&1 || fail "$waf: caddy validate rejected the generated Caddyfile"

  say "$waf: starting topology"
  start_python "$upstream" "$UPSTREAM" python3 /srv/upstream.py
  start_python "$edge" "$EDGE" python3 /srv/xff_proxy.py --listen 8080 \
    --upstream "http://$envoy:8080" --client-header X-Test-Client
  start_python "$envoy" "$ENVOY" python3 /srv/xff_proxy.py --listen 8080 --upstream "http://$caddy:8080"
  CONTAINERS+=("$(docker run -d --name "$caddy" --network "$NET" --ip "$CADDY" \
    -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" "$image")")
  start_client "$ca" "$CA"
  start_client "$ca2" "$CA2"
  start_client "$cb" "$CB"
  start_client "$ca3" "$CA3"
  start_client "$ca4" "$CA4"
  start_client "$podclient" "$POD"
  start_client "$hzclient" "$HZ"

  # Readiness the way the kubelet probes: straight to the pod, no proxy and
  # therefore no X-Forwarded-For.
  local ready="" r
  for _ in $(seq 1 30); do
    if r="$(req "$hzclient" "http://$caddy:8080/waf-healthz" 2>/dev/null)"; then
      [ "$(json_field "$r" status)" = 200 ] && { ready=1; break; }
    fi
    sleep 2
  done
  [ -n "$ready" ] || fail "$waf: WAF did not become ready"

  say "$waf: client identity"
  r="$(req "$ca" "http://$edge:8080/")"
  [ "$(json_field "$r" status)" = 200 ] || fail "$waf: proxied request failed: $r"
  [ "$(body_field "$r" x_real_ip)" = "$CA" ] \
    || fail "$waf: proxied identity is $(body_field "$r" x_real_ip), want $CA"

  r="$(req "$ca" "http://$edge:8080/" "X-Forwarded-For: 1.2.3.4" "CF-Connecting-IP: 5.6.7.8")"
  [ "$(body_field "$r" x_real_ip)" = "$CA" ] \
    || fail "$waf: forged headers via Cloudflare won the identity: $(body_field "$r" x_real_ip)"

  r="$(req "$ca" "http://$envoy:8080/" "X-Forwarded-For: 1.2.3.4" "CF-Connecting-IP: 5.6.7.8")"
  [ "$(body_field "$r" x_real_ip)" = "$CA" ] \
    || fail "$waf: forged headers on the direct path won the identity: $(body_field "$r" x_real_ip)"

  r="$(req "$podclient" "http://$envoy:8080/" "X-Forwarded-For: 1.2.3.4")"
  [ "$(body_field "$r" x_real_ip)" = "$POD" ] \
    || fail "$waf: pod address was skipped as a trusted hop: $(body_field "$r" x_real_ip)"

  say "$waf: rate limiting"
  local before after allowed=0 denied=0 retry="" status
  before="$(upstream_count "$upstream" "$CA2")"
  for i in $(seq 1 8); do
    r="$(req "$ca2" "http://$envoy:8080/burst?i=$i")"
    status="$(json_field "$r" status)"
    case "$status" in
      200) allowed=$((allowed + 1)) ;;
      429)
        denied=$((denied + 1))
        [ -n "$retry" ] || retry="$(json_field "$r" retry_after)"
        ;;
      *) fail "$waf: unexpected status $status during burst: $r" ;;
    esac
  done
  after="$(upstream_count "$upstream" "$CA2")"
  printf 'allowed=%s denied=%s retry_after=%s upstream_delta=%s\n' \
    "$allowed" "$denied" "$retry" "$((after - before))"
  [ "$allowed" -ge 1 ] || fail "$waf: burst rejected every request"
  [ "$denied" -ge 1 ] || fail "$waf: burst never returned 429"
  [ -n "$retry" ] || fail "$waf: 429 response has no Retry-After header"
  [ "$((after - before))" -eq "$allowed" ] \
    || fail "$waf: $((after - before)) requests reached the upstream, expected $allowed"

  # The dashboard and runbook attribute 429s via the access-log field; assert it.
  # Capture the logs before matching: `docker logs | grep -q` makes grep exit on
  # first match, SIGPIPEs the producer, and trips `set -o pipefail`.
  local caddy_logs
  caddy_logs="$(docker logs "$caddy" 2>&1)"
  case "$caddy_logs" in
    *"\"rate_limit_zone\":\"$zone\""*) ;;
    *) fail "$waf: access logs do not carry rate_limit_zone=$zone on a 429" ;;
  esac

  r="$(req "$cb" "http://$envoy:8080/")"
  [ "$(json_field "$r" status)" = 200 ] || fail "$waf: independent client was blocked: $r"
  [ "$(body_field "$r" x_real_ip)" = "$CB" ] || fail "$waf: client B identity wrong"

  say "$waf: health endpoint"
  # Probes (no X-Forwarded-For) are answered by Caddy itself and never limited:
  # send more than the zone allows from one client, all must stay 200.
  local hz_before hz_ok=0 i
  hz_before="$(upstream_count "$upstream" "$HZ")"
  for i in $(seq 1 8); do
    r="$(req "$hzclient" "http://$caddy:8080/waf-healthz")"
    [ "$(json_field "$r" status)" = 200 ] && [ "$(json_field "$r" body)" = healthy ] && hz_ok=$((hz_ok + 1))
  done
  [ "$hz_ok" -eq 8 ] || fail "$waf: only $hz_ok/8 probe requests got 'healthy' (probe path limited or changed)"
  [ "$(upstream_count "$upstream" "$HZ")" -eq "$hz_before" ] \
    || fail "$waf: a probe request reached the upstream"

  # Through the proxy (X-Forwarded-For present) the same path is ordinary
  # traffic: Coraza and the limiter apply and allowed requests go upstream.
  local g_allowed=0 g_denied=0
  for i in $(seq 1 8); do
    r="$(req "$hzclient" "http://$envoy:8080/waf-healthz?i=$i")"
    case "$(json_field "$r" status)" in
      200)
        [ "$(body_field "$r" path)" = "/waf-healthz?i=$i" ] \
          || fail "$waf: proxied /waf-healthz was answered by Caddy, not the upstream: $r"
        g_allowed=$((g_allowed + 1)) ;;
      429) g_denied=$((g_denied + 1)) ;;
      *) fail "$waf: unexpected status on a proxied /waf-healthz: $r" ;;
    esac
  done
  printf 'gateway /waf-healthz allowed=%s denied=%s\n' "$g_allowed" "$g_denied"
  [ "$g_allowed" -ge 1 ] && [ "$g_denied" -ge 1 ] \
    || fail "$waf: /waf-healthz through the Gateway is not rate limited"

  r="$(req "$podclient" "http://$envoy:8080/api?q=1%20UNION%20SELECT%201")"
  [ "$(json_field "$r" status)" = 403 ] || fail "$waf: Coraza did not block the SQLi test: $r"

  say "$waf: rule set"
  # The audit record of that block names the rule set that evaluated it. It
  # must be the CRS the image ships under /usr/share/coraza (CRS_VERSION in the
  # Dockerfile), not the frozen 4.25.0 bundle embedded in the connector: a
  # Caddyfile that goes back to `load_owasp_crs` / `@owasp_crs` fails here.
  local shipped_crs
  shipped_crs="$(docker cp "$caddy:/usr/share/coraza/crs/rules/REQUEST-901-INITIALIZATION.conf" - \
    | tar -xO | sed -n 's/^SecComponentSignature "\(OWASP_CRS\/[0-9.]*\)"$/\1/p')"
  [ -n "$shipped_crs" ] || fail "$waf: the image ships no CRS under /usr/share/coraza"
  case "$(docker logs "$caddy" 2>&1)" in
    *"\"rulesets\":[\"$shipped_crs\"]"*) ;;
    *) fail "$waf: the blocking rule set is not the shipped $shipped_crs" ;;
  esac
  printf 'rule set: %s\n' "$shipped_crs"

  # Coraza keeps the first SecArgumentsLimit (1000) arguments per source and
  # drops the rest. The base configuration must reject such a request (rules
  # 200004/200005 of coraza.conf-recommended); otherwise a payload placed
  # behind 1000 filler arguments is never shown to the CRS rules.
  local filler
  filler="$(python3 -c 'print("&".join(f"a{i}=1" for i in range(1000)))')"
  r="$(req "$podclient" "http://$envoy:8080/api?$filler&q=1%20UNION%20SELECT%201")"
  [ "$(json_field "$r" status)" = 400 ] \
    || fail "$waf: a payload behind 1000 filler arguments was not rejected: $(json_field "$r" status)"

  say "$waf: legitimate requests (false-positive regression)"
  # Requests the app really sends must keep their answer when the rule set,
  # the connector or a ConfigMap changes: PASS cases must reach the upstream,
  # known false positives must stay 403 until someone decides otherwise
  # (benign-corpus.py). This is what makes a CRS update safe to review from CI.
  local corpus_rc=0
  docker exec "$cb" python3 /srv/benign-corpus.py "$waf" "http://$edge:8080" || corpus_rc=$?
  docker logs "$caddy" 2>/dev/null | python3 "$HERE/benign-corpus.py" --rules
  [ "$corpus_rc" -eq 0 ] || fail "$waf: the WAF answered a legitimate request differently than pinned (see above)"

  if [ "$waf" = backend ]; then
    say "$waf: request methods"
    # The API's own methods must pass the CRS method allow-list (rule 911100);
    # a method the backend does not use stays blocked.
    local m
    for m in PUT DELETE; do
      r="$(req "$cb" -X "$m" "http://$envoy:8080/api/v1/appointments/1")"
      [ "$(json_field "$r" status)" = 200 ] && [ "$(body_field "$r" method)" = "$m" ] \
        || fail "$waf: $m did not reach the upstream: $r"
    done
    r="$(req "$cb" -X PATCH "http://$envoy:8080/api/v1/appointments/1")"
    [ "$(json_field "$r" status)" = 403 ] || fail "$waf: PATCH was not blocked: $(json_field "$r" status)"

    say "$waf: authentication zone"
    # 4 requests: above the authentication zone (3) but below the api zone (5),
    # so a 429 here can only come from the authentication zone and its match.
    local a_allowed=0 a_denied=0
    for i in $(seq 1 4); do
      r="$(req "$ca3" "http://$envoy:8080/api/v1/auth/test?i=$i")"
      status="$(json_field "$r" status)"
      case "$status" in
        200) a_allowed=$((a_allowed + 1)) ;;
        429) a_denied=$((a_denied + 1)) ;;
        *) fail "$waf: unexpected status $status on an auth request: $r" ;;
      esac
    done
    printf 'auth allowed=%s denied=%s\n' "$a_allowed" "$a_denied"
    [ "$a_allowed" -eq 3 ] && [ "$a_denied" -eq 1 ] \
      || fail "$waf: authentication zone did not limit /api/v1/auth/* to 3 (allowed=$a_allowed denied=$a_denied)"
    local auth_logs
    auth_logs="$(docker logs "$caddy" 2>&1)"
    case "$auth_logs" in
      *"\"rate_limit_zone\":\"authentication\""*) ;;
      *) fail "$waf: 429s were not attributed to the authentication zone" ;;
    esac
  fi

  say "$waf: IPv6 /64 grouping"
  # The edge proxy reports the X-Test-Client value as its client, so these
  # requests key on the IPv6 address instead of the client container's IPv4.
  local v6_allowed=0 v6_denied=0 same64 other64
  for i in $(seq 1 6); do
    r="$(req "$ca4" "http://$edge:8080/ipv6?i=$i" "X-Test-Client: 2001:db8:aaaa::1")"
    [ "$(json_field "$r" status)" = 200 ] && v6_allowed=$((v6_allowed + 1)) || v6_denied=$((v6_denied + 1))
  done
  r="$(req "$ca4" "http://$edge:8080/ipv6?same64" "X-Test-Client: 2001:db8:aaaa::2")"
  same64="$(json_field "$r" status)"
  r="$(req "$ca4" "http://$edge:8080/ipv6?other64" "X-Test-Client: 2001:db8:bbbb::1")"
  other64="$(json_field "$r" status)"
  printf 'v6 allowed=%s denied=%s same64=%s other64=%s\n' \
    "$v6_allowed" "$v6_denied" "$same64" "$other64"
  [ "$v6_allowed" -ge 1 ] && [ "$v6_denied" -ge 1 ] \
    || fail "$waf: IPv6 burst did not exhaust the /64 bucket"
  [ "$same64" = 429 ] || fail "$waf: a second address in the same /64 did not share the bucket ($same64)"
  [ "$other64" = 200 ] || fail "$waf: a different /64 was not a fresh bucket ($other64)"

  teardown_suite
}

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 with PyYAML is required (pip install pyyaml)" >&2; exit 1; }

docker network create --subnet "$SUBNET" "$NET" >/dev/null
say "image: ${TEST_IMAGE:-the image pinned in each WAF Deployment}"
say "config consistency"
check_trusted_lists
run_suite frontend
run_suite backend
say "all tests passed"
