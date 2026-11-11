#!/usr/bin/env ruby
# Render the pinned charts and verify application-only scans, DNS-independent
# frontend nginx configuration and that Loki is reached directly (no gateway).
# --fixtures DIR also writes inputs for the offline smoke test.
require "yaml"
require "json"
require "ipaddr"
require "tempfile"
require "open3"
require "fileutils"

ROOT = File.expand_path("../../..", __dir__)

def assert(condition, message)
  raise message unless condition
end

def documents(path)
  YAML.load_stream(File.read(File.join(ROOT, path))).compact
end

def render(release_path, repository_path)
  release = documents(release_path).first
  chart = release.fetch("spec").fetch("chart").fetch("spec")
  repo = documents(repository_path).find { |r| r.dig("metadata", "name") == chart.dig("sourceRef", "name") }
  raise "missing repository for #{release_path}" unless repo
  Tempfile.create(["startup-scope-values-", ".yaml"]) do |values|
    values.write(release.fetch("spec").fetch("values").to_yaml)
    values.flush
    output, error, status = Open3.capture3(
      "helm", "template", release.dig("metadata", "name"), chart.fetch("chart"),
      "--repo", repo.dig("spec", "url"), "--version", chart.fetch("version"),
      "--namespace", release.dig("metadata", "namespace"), "--values", values.path
    )
    raise "Helm render failed: #{error}" unless status.success?
    [release, YAML.load_stream(output).compact]
  end
end

def resource(docs, kind, name)
  docs.find { |d| d["kind"] == kind && d.dig("metadata", "name") == name } or
    raise "missing #{kind}/#{name}"
end

begin
  fixtures = ARGV.empty? ? nil : (ARGV.length == 2 && ARGV[0] == "--fixtures" && ARGV[1])
  raise "usage: #{$PROGRAM_NAME} [--fixtures DIR]" unless ARGV.empty? || fixtures

  release, trivy = render("gitops/infrastructure/controllers/trivy-operator/release.yaml",
                           "gitops/infrastructure/controllers/trivy-operator/repository.yaml")
  values = release.dig("spec", "values")
  deployment = resource(trivy, "Deployment", "trivy-operator")
  env = deployment.dig("spec", "template", "spec", "containers", 0, "env").to_h { |e| [e["name"], e["value"]] }
  targets = env.fetch("OPERATOR_TARGET_NAMESPACES").split(",").sort
  assert(targets == %w[abuseipdb taskflow], "Trivy must use the explicit application namespace allowlist")
  assert(env["OPERATOR_NAMESPACE"] == "trivy-system", "scan jobs must remain in trivy-system")
  assert(values["excludeNamespaces"].to_s.empty?, "do not rely on the bypassable all-namespace exclusions")
  assert(values.dig("operator", "scanJobsConcurrentLimit") == 1, "keep scan concurrency bounded")
  assert(values.dig("trivy", "resources", "requests", "memory") == "512Mi", "do not shrink scanner requests to hide the scope bug")
  assert(values.dig("trivy", "resources", "limits", "memory") == "2Gi", "retain scanner OOM headroom")
  %w[rbacAssessmentScannerEnabled infraAssessmentScannerEnabled clusterComplianceEnabled].each do |key|
    assert(values.dig("operator", key) == true, "do not disable #{key}")
  end
  assert(values.dig("compliance", "reportType") == "all", "keep detailed compliance reports")
  puts "OK Trivy: rendered application allowlist, scan budgets and cluster scanners retained"

  dns_ip = documents("gitops/infrastructure/controllers/coredns/release.yaml").first.dig("spec", "values", "service", "clusterIP")
  IPAddr.new(dns_ip)
  frontend = documents("gitops/apps/taskflow/frontend.yaml")
  upstream = resource(frontend, "ConfigMap", "taskflow-frontend-upstream").fetch("data").fetch("upstream-server.conf")
  assert(upstream.match?(/^\s*resolver #{Regexp.escape(dns_ip)} valid=30s ipv6=off;$/), "frontend resolver must use the literal kube-dns IP")
  assert(upstream.match?(/^\s*resolver_timeout 2s;$/), "frontend DNS queries must time out promptly")
  assert(upstream.match?(/^\s*server backend\.taskflow\.svc\.cluster\.local:8080 resolve;$/), "frontend must defer backend resolution")
  frontend_image = resource(frontend, "Deployment", "taskflow-frontend").dig("spec", "template", "spec", "containers", 0, "image")
  assert(frontend_image.include?("@sha256:"), "smoke test must use the pinned frontend image (including its upstream zone)")

  puts "OK nginx: frontend uses the literal CoreDNS IP and runtime resolution"

  # Loki has no nginx gateway in front of it (the chart's gateway could not start
  # while DNS was down). Every client must name the Loki Service itself, and the two
  # network policies between abuseipdb-sync and Loki must match the rendered pod.
  _, loki = render("gitops/monitoring/logging/loki-release.yaml", "gitops/monitoring/logging/repositories.yaml")
  gateway = loki.select { |d| d.dig("metadata", "name").to_s.start_with?("loki-gateway") }
  assert(gateway.empty?, "the Loki gateway must stay disabled, rendered: #{gateway.map { |d| "#{d["kind"]}/#{d.dig("metadata", "name")}" }.join(", ")}")
  service = resource(loki, "Service", "loki")
  port = service.dig("spec", "ports").find { |p| p["name"] == "http-metrics" }&.fetch("port")
  assert(port == 3100, "rendered Loki Service must expose HTTP on 3100")
  namespace = service.dig("metadata", "namespace")
  loki_url = "http://loki.#{namespace}.svc.cluster.local:#{port}"
  pod_labels = resource(loki, "StatefulSet", "loki").dig("spec", "template", "metadata", "labels")
  assert(service.dig("spec", "selector").all? { |k, v| pod_labels[k] == v }, "Loki Service must select the single-binary pod")

  alloy = documents("gitops/monitoring/logging/alloy-release.yaml").first.dig("spec", "values", "alloy", "configMap", "content")
  assert(alloy.scan(/^\s*url\s*=\s*"([^"]+)"/).flatten == ["#{loki_url}/loki/api/v1/push"], "Alloy must push to the Loki Service directly")
  datasource = YAML.safe_load(resource(documents("gitops/monitoring/logging/loki-datasource.yaml"), "ConfigMap", "taskflow-waf-loki-datasource")
    .fetch("data").fetch("loki-datasource.yaml")).fetch("datasources").find { |d| d["uid"] == "loki" }
  assert(datasource.fetch("url") == loki_url, "the Grafana Loki datasource must query the Loki Service directly")
  abuseipdb = resource(documents("gitops/platform/abuseipdb/config.yaml"), "ConfigMap", "abuseipdb-sync-config").fetch("data")
  assert(abuseipdb.fetch("LOKI_PUSH_URL") == "#{loki_url}/loki/api/v1/push", "abuseipdb-sync must push to the Loki Service directly")

  # Cilium matches the pod's labels and port (after Service translation), so both
  # sides of the cross-namespace path are compared with the rendered pod.
  selects_loki = ->(labels) { labels.all? { |k, v| pod_labels[k.delete_prefix("k8s:")] == v } }
  has_port = ->(rule) { rule.fetch("toPorts").flat_map { |t| t.fetch("ports") }.include?({"port" => port.to_s, "protocol" => "TCP"}) }
  ingress = resource(documents("gitops/monitoring/platform/network-policies.yaml"), "CiliumNetworkPolicy", "allow-abuseipdb-sync-to-loki").fetch("spec")
  assert(selects_loki.call(ingress.dig("endpointSelector", "matchLabels")), "allow-abuseipdb-sync-to-loki must select the Loki pod")
  assert(ingress.fetch("ingress").any? { |rule| has_port.call(rule) }, "allow-abuseipdb-sync-to-loki must admit the Loki HTTP port")
  egress = resource(documents("gitops/platform/abuseipdb/network-policy.yaml"), "CiliumNetworkPolicy", "abuseipdb-sync-egress").dig("spec", "egress")
  to_loki = egress.select do |rule|
    rule.fetch("toEndpoints", []).any? do |endpoint|
      labels = endpoint.fetch("matchLabels").dup
      labels.delete("k8s:io.kubernetes.pod.namespace") == namespace && selects_loki.call(labels)
    end
  end
  assert(to_loki.any? { |rule| has_port.call(rule) }, "abuseipdb-sync-egress must allow the Loki pod on its HTTP port")
  puts "OK Loki: no gateway; Alloy, Grafana and abuseipdb-sync use #{loki_url}; both network policies match the rendered pod and port"

  if fixtures
    FileUtils.mkdir_p(fixtures)
    File.write(File.join(fixtures, "frontend-upstream.conf"), upstream)
    File.write(File.join(fixtures, "images.json"), JSON.generate({frontend: frontend_image}))
  end
rescue StandardError => error
  warn error.message
  exit 1
end
