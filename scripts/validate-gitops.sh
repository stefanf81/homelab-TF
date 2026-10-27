#!/usr/bin/env bash
# Render every path a Flux Kustomization reconciles and schema-validate the output.
#
# Mirrors what kustomize-controller does (build the path, apply the result), so a
# broken kustomization.yaml, a missing resource file or an invalid manifest fails
# here instead of after the merge. Flux and cert-manager CRDs are validated against
# the community CRD catalog; kinds without a schema are skipped, not failed.
# RenovateJob is skipped explicitly: the catalog schema lags the operator and rejects
# spec.renovateConfig, which the deployed operator version accepts.
#
# Needs: kubectl (embedded Kustomize) or kustomize, kubeconform and ruby.
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

# CRD schemas from the community catalog, pinned to a commit so upstream changes
# cannot change results without a change here. Bump deliberately.
CRD_CATALOG_REF=3eb90d47aba8d61919d4419dd38301536e32a94b

# Flux applies a path without kustomization.yaml by generating one over every
# manifest below it; approximate that by concatenating them.
render() {
  if [ -f "$1/kustomization.yaml" ]; then
    build "$1"
  else
    find "$1" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort | while read -r f; do
      echo '---'; cat "$f"
    done
  fi
}

fail=0
for p in "${paths[@]}"; do
  if [ ! -d "$p" ]; then
    echo "MISSING $p (referenced by a Flux Kustomization)" >&2
    fail=1
    continue
  fi
  echo "CHECK $p"
  # flux-postbuild.rb applies cluster-vars substitution exactly when the path's Flux
  # Kustomization declares it, and fails on undefined or unsubstituted variables.
  if ! { render "$p" | ruby scripts/flux-postbuild.rb "$p" | kubeconform \
      -summary -ignore-missing-schemas \
      -skip RenovateJob \
      -schema-location default \
      -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      -; }; then
    fail=1
  fi
done

exit "$fail"
