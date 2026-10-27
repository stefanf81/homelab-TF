#!/usr/bin/env bash
# Fail if the tool versions pinned in mise.toml differ from the ones CI installs in
# .github/workflows/validate-gitops.yaml.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

wf=.github/workflows/validate-gitops.yaml
fail=0
check() { # <mise tool> <workflow key> <strip leading v: 0|1>
  local want have
  want="$(sed -nE "s/^$1 *= *\"([^\"]+)\".*/\1/p" mise.toml)"
  have="$(sed -nE "s/^ *$2: *v?([0-9][^ #]*).*/\1/p" "$wf" | head -1)"
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    echo "MISMATCH $1: mise.toml=${want:-<missing>} $wf ($2)=${have:-<missing>}" >&2
    fail=1
  fi
}
check kubectl KUBECTL_VERSION 1
check kubeconform KUBECONFORM_VERSION 1
check opentofu tofu_version 0
check tflint tflint_version 1
[ "$fail" -eq 0 ] && echo "tool versions consistent"
exit "$fail"
