#!/usr/bin/env bash
# Fail if mise.toml's client tools drift from what the cluster runs:
#   - flux2 minor must equal the FluxInstance distribution minor;
#   - kubectl minor must equal the k3s minor (default k3s_version in variables.tf).
# CI reads every other pin from mise.toml directly (scripts/tool-versions.sh).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

eval "$(scripts/tool-versions.sh)"
minor() { echo "$1" | sed -nE 's/^v?([0-9]+\.[0-9]+).*/\1/p'; }

flux_instance="$(sed -nE 's/^ *version: *"?([0-9]+\.[0-9]+)\.x"?.*/\1/p' gitops/infrastructure/flux-instance/flux-instance.yaml)"
k3s="$(sed -nE '/variable "k3s_version"/,/^}/ s/^ *default *= *"v?([0-9]+\.[0-9]+).*/\1/p' variables.tf)"

fail=0
compare() { # <what> <mise value> <cluster value> <cluster source>
  if [ -z "$2" ] || [ -z "$3" ] || [ "$2" != "$3" ]; then
    echo "MISMATCH $1: mise.toml=${2:-<missing>} vs ${4}=${3:-<missing>}" >&2
    fail=1
  fi
}
compare "flux2 minor" "$(minor "${FLUX2_VERSION:-}")" "$flux_instance" "FluxInstance"
compare "kubectl minor" "$(minor "${KUBECTL_VERSION:-}")" "$k3s" "k3s_version"

[ "$fail" -eq 0 ] && echo "toolchain pins match the cluster (flux $flux_instance, k8s $k3s)"
exit "$fail"
