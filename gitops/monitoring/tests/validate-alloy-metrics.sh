#!/usr/bin/env bash
# Runs the real Alloy image, with the processing blocks from alloy-release.yaml, over
# fixture WAF logs and checks the logs-to-metrics series the dashboards read:
# exact request/rate-limit/audit/detection counts, the duration histogram, and that
# no pod, file or client data leaks into metric labels. It also checks what Alloy
# writes to Loki: credential redaction on audit records, Coraza's per-rule lines and
# access records (headers, query keys, Coraza matched data, Coraza's \u0026 and %q
# escaping), the removal of the per-message URI copies that keeps a ~19 KB padded
# URI under Loki's 256 KB line limit, and bounded method/rule_id labels. Needs docker,
# ruby, python3 and a disposable Loki (LOKI_URL), which receives the redacted fixture
# logs (use a fresh one after changing the pipeline: stored records are checked too).
#
# ALLOY_IMAGE is pinned to the app version of the Alloy Helm chart in
# gitops/monitoring/logging/alloy-release.yaml (chart 1.14.3 -> Alloy v1.21.2);
# bump both together. The release sets `alloy.stabilityLevel: experimental` (the
# loki.write WAL needs it since v1.21), so the test passes the same flag.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$HERE/../../.." && pwd)}"
RELEASE="${ALLOY_RELEASE:-$REPO_ROOT/gitops/monitoring/logging/alloy-release.yaml}"
ALLOY_IMAGE="${ALLOY_IMAGE:-grafana/alloy:v1.21.2}"
ALLOY_PORT="${ALLOY_PORT:-12367}"
: "${LOKI_URL:?LOKI_URL must point at a reachable Loki}"

tmp="$(mktemp -d)"
alloy_container=""
cleanup() {
  if [[ -n "$alloy_container" ]]; then
    docker rm -f "$alloy_container" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/logs"

echo "== testing Alloy logs-to-metrics with $ALLOY_IMAGE"
ruby "$HERE/validate-alloy-metrics-config.rb" "$RELEASE" "$tmp/config.alloy" "$LOKI_URL/loki/api/v1/push"
python3 "$HERE/validate-alloy-metrics-fixtures.py" "$tmp/logs" "$tmp/truth.json"
chmod -R a+rX "$tmp"

alloy_container="$(docker run -d --network host \
  -v "$tmp/config.alloy:/etc/alloy/config.alloy:ro" -v "$tmp/logs:/logs:ro" \
  "$ALLOY_IMAGE" run --stability.level=experimental --server.http.listen-addr="127.0.0.1:$ALLOY_PORT" \
  --storage.path=/tmp/alloy /etc/alloy/config.alloy)"

if ! python3 "$HERE/validate-alloy-metrics-check.py" "$tmp/truth.json" "http://127.0.0.1:$ALLOY_PORT/metrics"; then
  docker logs "$alloy_container" >&2 || true
  exit 1
fi
if ! python3 "$HERE/validate-alloy-logs-check.py" "$tmp/truth.json" "$LOKI_URL"; then
  docker logs "$alloy_container" >&2 || true
  exit 1
fi
echo "Alloy logs-to-metrics checks passed"
