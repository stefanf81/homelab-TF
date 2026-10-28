#!/usr/bin/env ruby
# Render the pinned Helm charts, not just the values YAML. This catches unknown
# value paths, Helm tpl failures, and missing operator CR wiring. No cluster I/O.
require "yaml"
require "tempfile"
require "open3"

ROOT = File.expand_path("../../..", __dir__)

def assert(condition, message)
  raise message unless condition
end

def render(release_path, repository_path)
  release = YAML.load_file(File.join(ROOT, release_path))
  chart = release.fetch("spec").fetch("chart").fetch("spec")
  repos = YAML.load_stream(File.read(File.join(ROOT, repository_path))).compact
  repository = repos.find { |r| r.dig("metadata", "name") == chart.dig("sourceRef", "name") }
  raise "repository not found for #{release_path}" unless repository
  Tempfile.create(["monitoring-values-", ".yaml"]) do |values|
    values.write(release.fetch("spec").fetch("values").to_yaml)
    values.flush
    output, error, status = Open3.capture3(
      "helm", "template", release.dig("metadata", "name"), chart.fetch("chart"),
      "--repo", repository.dig("spec", "url"), "--version", chart.fetch("version"),
      "--namespace", release.dig("metadata", "namespace"), "--values", values.path
    )
    raise "Helm render failed for #{release_path}: #{error}" unless status.success?
    [release, YAML.load_stream(output).compact]
  end
end

def resource(documents, kind, name)
  documents.find { |d| d["kind"] == kind && d.dig("metadata", "name") == name } or
    raise "rendered #{kind}/#{name} not found"
end

begin
  alloy_release, alloy = render("gitops/monitoring/logging/alloy-release.yaml", "gitops/monitoring/logging/repositories.yaml")
  assert(alloy_release.dig("spec", "upgrade", "serverSideApply") == "disabled", "Alloy strategy migration requires strategic merge, not SSA")
  deployment = resource(alloy, "Deployment", "alloy")
  assert(deployment.dig("spec", "replicas") == 1, "Alloy must have one PVC writer")
  assert(deployment.dig("spec", "strategy", "type") == "Recreate", "Alloy must not surge with a shared WAL")
  assert(!deployment.dig("spec", "strategy").key?("rollingUpdate"), "Recreate must not retain rollingUpdate fields")
  config = resource(alloy, "ConfigMap", "alloy").fetch("data").fetch("config.alloy")
  assert(config.include?("drop_malformed = true"), "audit parsing must fail closed")
  assert(!config.include?("$1=REDACTED"), "redaction must replace values, not names")
  puts "  OK rendered Alloy: exclusive WAL writer, Helm tpl, audit safety guards"

  release, stack = render("gitops/monitoring/platform/release.yaml", "gitops/monitoring/platform/repository.yaml")
  name = release.dig("metadata", "name")
  tsdb = resource(stack, "VMSingle", name).fetch("spec")
  assert(tsdb.dig("extraArgs", "memory.allowedBytes") == "384MiB", "TSDB caches must leave recovery/query headroom")
  assert(!tsdb.fetch("extraArgs").key?("memory.allowedPercent"), "use a fixed cache budget, not a share of the limit")
  assert(tsdb.dig("extraArgs", "search.maxConcurrentRequests") == "4", "TSDB query concurrency must be bounded")
  assert(tsdb.dig("extraArgs", "search.maxMemoryPerQuery") == "64MiB", "TSDB per-query memory must be bounded")
  assert(release.dig("spec", "upgrade", "serverSideApply") == "disabled", "Grafana strategy migration requires strategic merge, not SSA")
  evaluator = resource(stack, "VMAlert", name).fetch("spec")
  assert(evaluator.dig("extraArgs", "notifier.blackhole") == "true", "alert delivery must remain disabled")
  assert(!evaluator.key?("notifiers") && !evaluator.key?("notifier"), "blackhole must not be combined with external notifiers")
  assert(evaluator["selectAllByDefault"] == true, "recording rules must be selected")
  assert(evaluator.dig("datasource", "url").end_with?("/vmsingle"), "rule queries must use the VMSingle prefix")
  assert(evaluator.dig("remoteWrite", "url").end_with?("/vmsingle/api/v1/write"), "recording results need a remote-write target")
  assert(evaluator.dig("extraArgs", "remoteWrite.disablePathAppend") == "true", "do not append a second API path")
  assert(stack.none? { |d| d["kind"] == "VMAlertmanager" }, "Alertmanager must remain disabled")
  assert(release.dig("spec", "values", "defaultRules", "enabled") != false, "bundled recording rules must remain enabled")

  agent = resource(stack, "VMAgent", name).fetch("spec")
  storage = agent.dig("statefulStorage", "volumeClaimTemplate", "spec")
  assert(agent["statefulMode"] == true, "vmagent queue must survive pod replacement")
  assert(storage && storage["storageClassName"] == "proxmox-csi", "queue PVC storage class missing")
  assert(storage["accessModes"] == ["ReadWriteOnce"], "queue PVC access mode missing")
  assert(storage.dig("resources", "requests", "storage") == "2Gi", "queue PVC must leave room above the 1Gi queue cap")
  assert(agent.dig("extraArgs", "remoteWrite.maxDiskUsagePerURL") == "1073741824", "queue must be byte-bounded")
  assert(agent.dig("extraArgs", "memory.allowedBytes") == "128MiB", "vmagent internal memory must leave process headroom")
  assert(agent.dig("resources", "limits", "memory") == "512Mi", "vmagent needs startup/backlog memory headroom")

  grafana = resource(stack, "Deployment", "#{name}-grafana")
  assert(grafana.dig("spec", "strategy", "type") == "Recreate", "SQLite PVC must not have overlapping Grafana writers")
  assert(!grafana.dig("spec", "strategy").key?("rollingUpdate"), "Grafana Recreate must not retain rollingUpdate fields")
  ini = resource(stack, "ConfigMap", "#{name}-grafana").fetch("data").fetch("grafana.ini")
  security = ini[/^\[security\]\n(.*?)(?=^\[|\z)/m, 1].to_s
  assert(security.match?(/^cookie_secure = true$/), "Grafana HTTPS cookies must be Secure")
  assert(security.match?(/^cookie_samesite = lax$/), "GitHub OAuth requires a compatible SameSite policy")
  puts "  OK rendered stack: rule evaluator/write path, persistent bounded queue, SQLite rollout, secure cookies"
rescue StandardError => error
  warn error.message
  exit 1
end
