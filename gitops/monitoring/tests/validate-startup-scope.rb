#!/usr/bin/env ruby
# Render the pinned charts and verify application-only scans and DNS-independent
# nginx configuration. --fixtures DIR also writes inputs for the offline smoke test.
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

  _, loki = render("gitops/monitoring/logging/loki-release.yaml", "gitops/monitoring/logging/repositories.yaml")
  nginx = resource(loki, "ConfigMap", "loki-gateway").fetch("data").fetch("nginx.conf")
  resolvers = nginx.lines.grep(/^\s*resolver /).map(&:strip)
  assert(resolvers == ["resolver #{dns_ip} valid=30s ipv6=off;"], "rendered Loki must not resolve the DNS server hostname at startup")
  assert(nginx.include?("proxy_pass       $backend$request_uri;"), "retain Loki runtime upstream resolution")
  gateway_image = resource(loki, "Deployment", "loki-gateway").dig("spec", "template", "spec", "containers").find { |c| c["name"] == "nginx" }.fetch("image")
  puts "OK nginx: frontend and rendered Loki use the same literal CoreDNS IP and runtime resolution"

  if fixtures
    FileUtils.mkdir_p(fixtures)
    File.write(File.join(fixtures, "frontend-upstream.conf"), upstream)
    File.write(File.join(fixtures, "loki-nginx.conf"), nginx)
    File.write(File.join(fixtures, "images.json"), JSON.generate({frontend: frontend_image, gateway: gateway_image}))
  end
rescue StandardError => error
  warn error.message
  exit 1
end
