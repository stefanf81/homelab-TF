#!/usr/bin/env bash
#
# Validate the WAF ConfigMaps and Grafana dashboards exactly as Git ships them.
#
# Unlike the identity/rate-limit suite, no Caddy configuration is substituted: the real
# trusted_proxies list, rate-limit zones and Coraza exclusions are validated,
# which is what ConfigMap-only changes need in CI (they do not trigger the image
# build workflow).
#
# Usage: [IMAGE=<ref>] [LOKI_IMAGE=<ref>] validate-configs.sh
# The image defaults to the one pinned in the frontend WAF Deployment.
#
# Requires: docker, ruby, and kubectl (with embedded Kustomize).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
WAF_DIR="$REPO_ROOT/gitops/apps/taskflow"
LOKI_RELEASE="$REPO_ROOT/gitops/monitoring/logging/loki-release.yaml"
LOKI_REPOSITORIES="$REPO_ROOT/gitops/monitoring/logging/repositories.yaml"

for tool in docker ruby kubectl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required tool not found: $tool" >&2
    exit 1
  }
done

# Every custom Grafana dashboard ships as a standalone JSON file next to the
# configMapGenerator that wraps it (see the SOURCE.md in each directory).
shopt -s nullglob
DASHBOARDS=("$REPO_ROOT"/gitops/monitoring/logging/dashboards/*.json "$REPO_ROOT"/gitops/monitoring/app/dashboards/*.json)
shopt -u nullglob
if ((${#DASHBOARDS[@]} == 0)); then
  echo "no dashboard JSON files found under gitops/monitoring/*/dashboards" >&2
  exit 1
fi

echo "== validating Grafana dashboard structure"
env -u LOKI_URL ruby "$HERE/validate-dashboards.rb" "${DASHBOARDS[@]}"

echo "== validating dashboard provisioning (Kustomize render)"
ruby "$HERE/validate-dashboard-provisioning.rb" "$REPO_ROOT"

echo "== resolving deployed Loki version from its Helm release/repository"
EXPECTED_LOKI_VERSION="$(ruby "$HERE/validate-loki-version.rb" "$LOKI_RELEASE" "$LOKI_REPOSITORIES")"
export EXPECTED_LOKI_VERSION
LOKI_IMAGE="${LOKI_IMAGE:-grafana/loki:$EXPECTED_LOKI_VERSION}"
# Even an overridden/digest-pinned image must report the deployed version.
# ALLOW_LOKI_VERSION_MISMATCH=1 explicitly permits migration testing.

cm_key() { # <file> <key>
  ruby -ryaml -e '
    cm = YAML.load_stream(File.read(ARGV[0])).compact.find { |d| d["kind"] == "ConfigMap" }
    print cm.fetch("data").fetch(ARGV[1])
  ' "$1" "$2"
}

deployment_image() { # <file>
  ruby -ryaml -e '
    dep = YAML.load_stream(File.read(ARGV[0])).compact.find { |d| d["kind"] == "Deployment" }
    print dep.dig("spec", "template", "spec", "containers", 0, "image")
  ' "$1"
}

IMAGE="${IMAGE:-$(deployment_image "$WAF_DIR/frontend-waf.yaml")}"
echo "image: $IMAGE"

tmp="$(mktemp -d)"
loki_container=""
cleanup() {
  if [[ -n "$loki_container" ]]; then
    docker rm -f "$loki_container" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

for waf in frontend backend; do
  mkdir -p "$tmp/$waf/caddy" "$tmp/$waf/coraza"
  cm_key "$WAF_DIR/$waf-waf.yaml" Caddyfile > "$tmp/$waf/caddy/Caddyfile"
  cm_key "$WAF_DIR/$waf-waf.yaml" rate-limit.conf > "$tmp/$waf/caddy/rate-limit.conf"
  cm_key "$WAF_DIR/$waf-waf.yaml" "$waf-exclusions.conf" > "$tmp/$waf/coraza/$waf-exclusions.conf"

  echo "== validating $waf WAF config (as shipped)"
  docker run --rm --platform linux/amd64 \
    -v "$tmp/$waf/caddy:/etc/caddy:ro" -v "$tmp/$waf/coraza:/etc/coraza:ro" \
    "$IMAGE" validate --config /etc/caddy/Caddyfile --adapter caddyfile
done

echo "== validating LogQL with $LOKI_IMAGE"
loki_container="$(docker run -d --rm --publish 127.0.0.1::3100 \
  -v "$HERE/loki-validation.yaml:/etc/loki/validation.yaml:ro" \
  "$LOKI_IMAGE" -config.file=/etc/loki/validation.yaml)"
loki_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "3100/tcp") 0).HostPort}}' "$loki_container")"
export LOKI_URL="http://127.0.0.1:$loki_port"
if ! ruby "$HERE/validate-dashboards.rb" "${DASHBOARDS[@]}"; then
  docker logs "$loki_container" >&2
  exit 1
fi

echo "== testing dashboard validation guards"
ruby "$HERE/validate-dashboards-test.rb"

echo "all config validations passed"
