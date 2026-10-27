#!/usr/bin/env bash
# Render every path a Flux Kustomization reconciles and schema-validate the output.
#
# Mirrors what kustomize-controller does (build the path, apply the result), so a
# broken kustomization.yaml, a missing resource file or an invalid manifest fails
# here instead of after the merge. Flux and cert-manager CRDs are validated against
# the community CRD catalog; kinds without a schema are skipped, not failed.
#
# Needs: kubectl (embedded Kustomize) or kustomize, and kubeconform.
# Usage: scripts/validate-gitops.sh [path ...]   (default: all Flux Kustomization paths)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1"; }
else
  build() { kubectl kustomize "$1"; }
fi

if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  # Cluster root plus every spec.path referenced from it.
  mapfile -t paths < <(
    { echo "gitops/clusters/taskflow"
      grep -h '^  path:' gitops/clusters/taskflow/*.yaml | sed 's|^  path: *\./||'; } | sort -u
  )
fi

fail=0
for p in "${paths[@]}"; do
  if [ ! -f "$p/kustomization.yaml" ]; then
    echo "SKIP  $p (no kustomization.yaml; Flux applies plain manifests)"
    continue
  fi
  echo "CHECK $p"
  if ! build "$p" | kubeconform \
      -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -; then
    fail=1
  fi
done

exit "$fail"
