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

VARS=gitops/clusters/taskflow/cluster-vars.yaml

# Emulate Flux postBuild substitution with the values from cluster-vars.yaml:
# ${NAME} -> value, and the escape $${ -> ${. With --check the stream is passed
# through unchanged, but the run fails if any ${NAME} defined in cluster-vars is
# still present, i.e. a path uses a variable without a postBuild block.
substitute() { # <apply|check>
  python3 -c '
import re, sys
mode = sys.argv[1]
data, in_data = {}, False
for line in open(sys.argv[2]):
    if line.startswith("data:"):
        in_data = True
    elif in_data and (m := re.match(r"  ([A-Z][A-Z0-9_]*): *(.+?) *$", line)):
        data[m[1]] = m[2].strip("\"\x27")
    elif in_data and line.strip() and not line.startswith(" "):
        in_data = False
text = sys.stdin.read()
if mode == "apply":
    text = re.sub(r"(?<!\$)\$\{([A-Z][A-Z0-9_]*)\}", lambda m: data.get(m[1], m[0]), text)
    text = text.replace("$${", "${")
else:
    left = sorted({k for k in data if "${" + k + "}" in text})
    if left:
        sys.exit("uses " + ", ".join(left) + " but its Flux Kustomization has no postBuild.substituteFrom cluster-vars")
sys.stdout.write(text)
' "$1" "$VARS"
}

fail=0
for p in "${paths[@]}"; do
  if [ ! -f "$p/kustomization.yaml" ]; then
    echo "SKIP  $p (no kustomization.yaml; Flux applies plain manifests)"
    continue
  fi
  echo "CHECK $p"
  mode=check
  if grep -ls "^  path: \./$p\$" gitops/clusters/taskflow/*.yaml | xargs -r grep -q 'name: cluster-vars'; then
    mode=apply
  fi
  if ! { build "$p" | substitute "$mode" | kubeconform \
      -summary -ignore-missing-schemas \
      -skip RenovateJob \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -; }; then
    fail=1
  fi
done

exit "$fail"
