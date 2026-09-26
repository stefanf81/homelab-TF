#!/usr/bin/env bash
#
# Validate the WAF ConfigMaps and Grafana dashboards exactly as Git ships them.
#
# Unlike the identity/rate-limit suite, nothing is substituted: the real
# trusted_proxies list, rate-limit zones and Coraza exclusions are validated,
# which is what ConfigMap-only changes need in CI (they do not trigger the image
# build workflow).
#
# Usage: [IMAGE=<ref>] validate-configs.sh
# The image defaults to the one pinned in the frontend WAF Deployment.
#
# Requires: docker and ruby.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
WAF_DIR="$REPO_ROOT/gitops/apps/taskflow"
GRAFANA_FILE="$REPO_ROOT/gitops/monitoring/logging/grafana-provisioning.yaml"

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
trap 'rm -rf "$tmp"' EXIT

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

echo "== validating Grafana dashboard JSON"
ruby -ryaml -rjson -e '
  YAML.load_stream(File.read(ARGV[0])).compact.each do |d|
    next unless d["kind"] == "ConfigMap"
    next unless d.dig("metadata", "labels", "grafana_dashboard") == "1"
    (d["data"] || {}).each do |key, value|
      next unless key.end_with?(".json")
      JSON.parse(value)
      puts "  OK #{d.dig("metadata", "name")}/#{key}"
    end
  end
' "$GRAFANA_FILE"

echo "all config validations passed"
