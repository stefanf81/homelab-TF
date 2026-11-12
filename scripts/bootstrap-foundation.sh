#!/usr/bin/env bash
# Bootstrap the pre-Flux cluster foundation on a fresh k3s node (or validate it offline).
#
# WHY THIS SCRIPT EXISTS (C-1):
# modules/proxmox/main.tf installs k3s with:
#   --flannel-backend=none --disable-network-policy --disable-kube-proxy --disable coredns
#
# On a freshly provisioned node:
#   1. Bare `cilium install` fails because `--disable-kube-proxy` leaves 10.43.0.1:443
#      unprogrammed (Cilium needs kubeProxyReplacement=true + k8sServiceHost=${NODE_IP}:6443),
#      defaults to ipam.mode=cluster-pool instead of `kubernetes`, and starts before
#      the Gateway API CRDs required by `gatewayAPI.enabled=true` exist.
#   2. With `--disable coredns`, nothing listens on 10.43.0.10:53 until CoreDNS is
#      installed, so `flux-operator` (pulling flux-manifests OCI) and `source-controller`
#      (cloning GitHub + pulling OCI charts) fail in-pod DNS resolution and deadlock
#      before Flux can ever reconcile `infra-controllers` to install CoreDNS.
#
# Installing Gateway API CRDs (server-side apply) plus the `cilium`, `coredns` and
# `flux-operator` Helm releases from the EXACT chart versions and `cluster-vars`-
# substituted `.spec.values` in Git breaks both deadlocks with zero drift: Flux's
# kustomize-controller and helm-controller adopt every object seamlessly on first sync.
#
# Usage:
#   scripts/bootstrap-foundation.sh             # Live cluster bring-up (uses KUBECONFIG)
#   scripts/bootstrap-foundation.sh --dry-run   # Offline render & anti-deadlock check (CI)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 1
fi

for tool in kubectl helm ruby; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required tool not found: $tool" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Extract OCIRepository URL/tag and substituted HelmRelease metadata/values.
extract_release() { # <postbuild-path> <repo-yaml> <release-yaml> <out-dir>
  local pb_path="$1" repo_yaml="$2" release_yaml="$3" out_dir="$4"
  mkdir -p "$out_dir"
  ruby scripts/flux-postbuild.rb "$pb_path" < "$release_yaml" > "$out_dir/release.rendered.yaml"
  ruby -ryaml -e '
    repo_docs = YAML.load_stream(File.read(ARGV[0])).compact
    rel_docs  = YAML.load_stream(File.read(ARGV[1])).compact
    out_dir   = ARGV[2]

    repo = repo_docs.find { |d| d["kind"] == "OCIRepository" } or abort "no OCIRepository in #{ARGV[0]}"
    rel  = rel_docs.find  { |d| d["kind"] == "HelmRelease" }   or abort "no HelmRelease in #{ARGV[1]}"

    url  = repo.dig("spec", "url").to_s
    tag  = repo.dig("spec", "ref", "tag").to_s
    name = rel.dig("metadata", "name").to_s
    ns   = rel.dig("metadata", "namespace").to_s
    abort "missing chart metadata for #{ARGV[1]}" if [url, tag, name, ns].any?(&:empty?)

    File.write(File.join(out_dir, "meta.env"), <<~ENV)
      CHART_URL=#{url}
      CHART_VERSION=#{tag}
      RELEASE_NAME=#{name}
      RELEASE_NAMESPACE=#{ns}
    ENV
    File.write(File.join(out_dir, "values.yaml"), (rel.dig("spec", "values") || {}).to_yaml)
  ' "$repo_yaml" "$out_dir/release.rendered.yaml" "$out_dir"
}

GATEWAY_API_DIR="gitops/infrastructure/controllers/gateway-api"

extract_release "gitops/infrastructure/controllers" \
  "gitops/infrastructure/controllers/cilium/repository.yaml" \
  "gitops/infrastructure/controllers/cilium/release.yaml" \
  "$TMP_DIR/cilium"

extract_release "gitops/infrastructure/controllers" \
  "gitops/infrastructure/controllers/coredns/repository.yaml" \
  "gitops/infrastructure/controllers/coredns/release.yaml" \
  "$TMP_DIR/coredns"

extract_release "gitops/infrastructure/controllers/flux-operator" \
  "gitops/infrastructure/controllers/flux-operator/repository.yaml" \
  "gitops/infrastructure/controllers/flux-operator/release.yaml" \
  "$TMP_DIR/flux-operator"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "== [dry-run] rendering Gateway API CRDs ($GATEWAY_API_DIR)"
  kubectl kustomize "$GATEWAY_API_DIR" > "$TMP_DIR/gateway-api.rendered.yaml"

  for comp in cilium coredns flux-operator; do
    (
      # shellcheck disable=SC1090
      . "$TMP_DIR/$comp/meta.env"
      echo "== [dry-run] rendering $RELEASE_NAMESPACE/$RELEASE_NAME ($CHART_URL:$CHART_VERSION)"
      helm template "$RELEASE_NAME" "$CHART_URL" \
        --version "$CHART_VERSION" \
        --namespace "$RELEASE_NAMESPACE" \
        --include-crds \
        --values "$TMP_DIR/$comp/values.yaml" > "$TMP_DIR/$comp/manifest.rendered.yaml"
    )
  done

  ruby -ryaml -e '
    tmp = ARGV[0]
    vars = YAML.load_file("gitops/clusters/taskflow/cluster-vars.yaml").fetch("data")

    gw_docs = YAML.load_stream(File.read(File.join(tmp, "gateway-api.rendered.yaml"))).compact
    crds = gw_docs.select { |d| d["kind"] == "CustomResourceDefinition" }.map { |d| d.dig("metadata", "name") }
    %w[
      gatewayclasses.gateway.networking.k8s.io
      gateways.gateway.networking.k8s.io
      httproutes.gateway.networking.k8s.io
    ].each do |crd|
      abort "missing Gateway API CRD #{crd}" unless crds.include?(crd)
    end

    cilium_docs = YAML.load_stream(File.read(File.join(tmp, "cilium/manifest.rendered.yaml"))).compact
    cm = cilium_docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "cilium-config" } or
      abort "cilium-config ConfigMap missing"
    abort "Cilium must set kube-proxy-replacement=true" unless cm.dig("data", "kube-proxy-replacement").to_s == "true"
    abort "Cilium must set ipam=kubernetes" unless cm.dig("data", "ipam") == "kubernetes"
    agent = cilium_docs.find { |d| d["kind"] == "DaemonSet" && d.dig("metadata", "name") == "cilium" } or
      abort "cilium DaemonSet missing"
    env = agent.dig("spec", "template", "spec", "containers", 0, "env").to_h { |e| [e["name"], e["value"]] }
    abort "Cilium KUBERNETES_SERVICE_HOST must match NODE_IP (#{vars["NODE_IP"]}), got #{env["KUBERNETES_SERVICE_HOST"].inspect}" unless env["KUBERNETES_SERVICE_HOST"] == vars["NODE_IP"]
    abort "Cilium KUBERNETES_SERVICE_PORT must be 6443" unless env["KUBERNETES_SERVICE_PORT"].to_s == "6443"

    coredns_docs = YAML.load_stream(File.read(File.join(tmp, "coredns/manifest.rendered.yaml"))).compact
    svc = coredns_docs.find { |d| d["kind"] == "Service" && d.dig("metadata", "name") == "kube-dns" } or
      abort "kube-dns Service missing"
    abort "kube-dns clusterIP must be 10.43.0.10" unless svc.dig("spec", "clusterIP") == "10.43.0.10"
    corefile = coredns_docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "coredns" }&.dig("data", "Corefile").to_s
    abort "Corefile missing substituted GATEWAY_IP/DOMAIN" unless corefile.include?("#{vars["GATEWAY_IP"]} #{vars["DOMAIN"]}")

    fo_docs = YAML.load_stream(File.read(File.join(tmp, "flux-operator/manifest.rendered.yaml"))).compact
    abort "FluxInstance CRD missing from flux-operator render" unless fo_docs.any? { |d| d["kind"] == "CustomResourceDefinition" && d.dig("metadata", "name") == "fluxinstances.fluxcd.controlplane.io" }
    abort "flux-operator Deployment missing" unless fo_docs.any? { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "flux-operator" }

    puts "  OK foundation bootstrap dry-run: Gateway API CRDs, Cilium (kubeProxyReplacement + kubernetes IPAM), CoreDNS (10.43.0.10), Flux Operator"
  ' "$TMP_DIR"
  exit 0
fi

echo "== Checking cluster API reachability"
kubectl version --request-timeout=10s >/dev/null

echo "== 1/4 Applying Gateway API CRDs (server-side apply to match Flux)"
kubectl apply --server-side -k "$GATEWAY_API_DIR"
kubectl wait --for=condition=Established \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  --timeout=60s

(
  # shellcheck disable=SC1091
  . "$TMP_DIR/cilium/meta.env"
  echo "== 2/4 Bootstrapping Cilium ($RELEASE_NAMESPACE/$RELEASE_NAME @ $CHART_VERSION)"
  helm upgrade --install "$RELEASE_NAME" "$CHART_URL" \
    --version "$CHART_VERSION" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$TMP_DIR/cilium/values.yaml"
  kubectl -n "$RELEASE_NAMESPACE" rollout status daemonset/cilium --timeout=5m
  kubectl -n "$RELEASE_NAMESPACE" rollout status daemonset/cilium-envoy --timeout=5m
  kubectl -n "$RELEASE_NAMESPACE" rollout status deployment/cilium-operator --timeout=5m
)

echo "== Waiting for k3s node(s) to report Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

(
  # shellcheck disable=SC1091
  . "$TMP_DIR/coredns/meta.env"
  echo "== 3/4 Bootstrapping CoreDNS ($RELEASE_NAMESPACE/$RELEASE_NAME @ $CHART_VERSION)"
  helm upgrade --install "$RELEASE_NAME" "$CHART_URL" \
    --version "$CHART_VERSION" \
    --namespace "$RELEASE_NAMESPACE" \
    --values "$TMP_DIR/coredns/values.yaml"
  kubectl -n "$RELEASE_NAMESPACE" rollout status deployment/coredns --timeout=5m
)

(
  # shellcheck disable=SC1091
  . "$TMP_DIR/flux-operator/meta.env"
  echo "== 4/4 Bootstrapping Flux Operator ($RELEASE_NAMESPACE/$RELEASE_NAME @ $CHART_VERSION)"
  helm upgrade --install "$RELEASE_NAME" "$CHART_URL" \
    --version "$CHART_VERSION" \
    --namespace "$RELEASE_NAMESPACE" \
    --create-namespace \
    --values "$TMP_DIR/flux-operator/values.yaml"
  kubectl -n "$RELEASE_NAMESPACE" rollout status deployment/flux-operator --timeout=5m
)

echo "Foundation bootstrap complete (Gateway API CRDs, Cilium, CoreDNS, Flux Operator)."
echo "Next: seed secrets in flux-system and taskflow, then apply gitops/infrastructure/flux-instance/flux-instance.yaml (see gitops/FLUX_BOOTSTRAP.md §3-4)."
