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
# for the test topology. The production zones are overridden with small windows
# so the suite runs in seconds; the production values (frontend general 180/min,
# backend api 300/min and authentication 20/min) live in the ConfigMaps.
#
# Usage: TEST_IMAGE=<image> ./run-tests.sh
# Requires: docker, python3 with PyYAML (used to extract the ConfigMaps).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

default_image() {
  awk -F= '
    /^ARG CADDY_VERSION=/ { caddy=$2 }
    /^ARG CORAZA_CADDY_VERSION=/ { coraza=$2 }
    /^ARG IMAGE_REVISION=/ { rev=$2 }
    END {
      gsub(/[ "]/,"",caddy); gsub(/[ "]/,"",coraza); gsub(/[ "]/,"",rev);
      sub(/^v/,"",coraza);
      print "ghcr.io/stefanf81/taskflow-caddy-coraza:" caddy "-coraza" coraza "-" rev
    }' "$HERE/../Dockerfile"
}

TEST_IMAGE="${TEST_IMAGE:-$(default_image)}"

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

req() { # client-container url [Header: value ...]
  local c="$1" url="$2"; shift 2
  docker exec "$c" python3 /srv/client.py "$url" "$@"
}

upstream_count() { # container key
  docker exec -e KEY="$2" "$1" python3 -c \
    'import json,os,urllib.request; print(json.loads(urllib.request.urlopen("http://127.0.0.1:8080/__count").read()).get(os.environ["KEY"],0))'
}

teardown_suite() {
  for cid in "${CONTAINERS[@]:-}"; do docker rm -f "$cid" >/dev/null 2>&1 || true; done
  CONTAINERS=()
}

# The Cloudflare ranges are duplicated in both ConfigMaps (the interim peer entry
# is identical too); fail early if they ever drift apart.
check_trusted_lists_match() {
  python3 - "$REPO_ROOT/gitops/apps/taskflow/frontend-waf.yaml" \
            "$REPO_ROOT/gitops/apps/taskflow/backend-waf.yaml" <<'PY'
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
print(f"trusted_proxies lists match ({len(front)} entries)")
PY
}

run_suite() { # waf
  local waf="$1"
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
  say "$waf: validating shipped config"
  docker run --rm -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" \
    "$TEST_IMAGE" validate --config /etc/caddy/Caddyfile --adapter caddyfile \
    >/dev/null 2>&1 || fail "$waf: caddy validate rejected the production config"

  # Override the zones for the test only, with a window long enough that a slow
  # runner cannot slide it during the burst. Production values live in the
  # ConfigMaps; the backend also carries the tighter authentication zone.
  if [ "$waf" = backend ]; then
    cat > "$cfg/caddy/rate-limit.conf" <<'EOF'
rate_limit {
    disable_metrics

    zone api {
        key         {client_ip}
        events      5
        window      5m
        ipv6_prefix 64
    }

    zone authentication {
        match {
            path /api/v1/auth/*
        }
        key         {client_ip}
        events      3
        window      5m
        ipv6_prefix 64
    }
}
EOF
  else
    cat > "$cfg/caddy/rate-limit.conf" <<'EOF'
rate_limit {
    disable_metrics

    zone general {
        key         {client_ip}
        events      5
        window      5m
        ipv6_prefix 64
    }
}
EOF
  fi

  say "$waf: validating generated Caddyfile"
  docker run --rm -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" \
    "$TEST_IMAGE" validate --config /etc/caddy/Caddyfile --adapter caddyfile \
    >/dev/null 2>&1 || fail "$waf: caddy validate rejected the generated Caddyfile"

  say "$waf: starting topology"
  start_python "$upstream" "$UPSTREAM" python3 /srv/upstream.py
  start_python "$edge" "$EDGE" python3 /srv/xff_proxy.py --listen 8080 \
    --upstream "http://$envoy:8080" --client-header X-Test-Client
  start_python "$envoy" "$ENVOY" python3 /srv/xff_proxy.py --listen 8080 --upstream "http://$caddy:8080"
  CONTAINERS+=("$(docker run -d --name "$caddy" --network "$NET" --ip "$CADDY" \
    -v "$cfg/caddy:/etc/caddy:ro" -v "$cfg/coraza:/etc/coraza:ro" "$TEST_IMAGE")")
  start_client "$ca" "$CA"
  start_client "$ca2" "$CA2"
  start_client "$cb" "$CB"
  start_client "$ca3" "$CA3"
  start_client "$ca4" "$CA4"
  start_client "$podclient" "$POD"
  start_client "$hzclient" "$HZ"

  local ready="" r
  for _ in $(seq 1 30); do
    if r="$(req "$hzclient" "http://$envoy:8080/waf-healthz" 2>/dev/null)"; then
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

  r="$(req "$hzclient" "http://$envoy:8080/waf-healthz")"
  [ "$(json_field "$r" status)" = 200 ] || fail "$waf: health endpoint was rate limited: $r"

  r="$(req "$podclient" "http://$envoy:8080/api?q=1%20UNION%20SELECT%201")"
  [ "$(json_field "$r" status)" = 403 ] || fail "$waf: Coraza did not block the SQLi test: $r"

  if [ "$waf" = backend ]; then
    say "$waf: authentication zone"
    local a_allowed=0 a_denied=0
    for i in $(seq 1 6); do
      r="$(req "$ca3" "http://$envoy:8080/api/v1/auth/test?i=$i")"
      status="$(json_field "$r" status)"
      case "$status" in
        200) a_allowed=$((a_allowed + 1)) ;;
        429) a_denied=$((a_denied + 1)) ;;
        *) fail "$waf: unexpected status $status on an auth request: $r" ;;
      esac
    done
    printf 'auth allowed=%s denied=%s\n' "$a_allowed" "$a_denied"
    [ "$a_denied" -ge 1 ] || fail "$waf: authentication zone did not trigger"
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
say "image: $TEST_IMAGE"
say "config consistency"
check_trusted_lists_match
run_suite frontend
run_suite backend
say "all tests passed"
