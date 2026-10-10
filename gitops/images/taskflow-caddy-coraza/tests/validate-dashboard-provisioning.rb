#!/usr/bin/env ruby
# Verify that every dashboard JSON is actually rendered by the Flux
# Kustomizations. A valid JSON file that no Kustomization includes would pass
# the panel/query validator but never reach Grafana, so render the parent trees
# with `kubectl kustomize` and compare the generated ConfigMaps against the
# source files.
require "json"
require "yaml"
require "open3"

module DashboardProvisioningValidation
  TREES = [
    { name: "logging", kustomization: "gitops/monitoring/logging",
      dashboards: "gitops/monitoring/logging/dashboards" },
    { name: "app", kustomization: "gitops/monitoring/app",
      dashboards: "gitops/monitoring/app/dashboards" }
  ].freeze

  # Folder annotation values are relative paths under the sidecar's FOLDER.
  # Reject absolute paths, parent traversal, backslashes, and stray whitespace.
  def self.valid_folder?(value)
    return false unless value.is_a?(String)
    return false if value.empty? || value != value.strip
    return false if value.start_with?("/") || value.end_with?("/") || value.include?("\\") || value.match?(/\A[A-Za-z]:/)
    value.split("/").all? { |segment| !segment.empty? && segment != "." && segment != ".." }
  end

  def self.load_sources(repo_root, tree)
    dir = File.join(repo_root, tree.fetch(:dashboards))
    Dir[File.join(dir, "*.json")].sort.map do |path|
      { path: path, name: File.basename(path), dashboard: JSON.parse(File.read(path)) }
    end
  end

  def self.render(repo_root, tree)
    stdout, stderr, status = Open3.capture3("kubectl", "kustomize", File.join(repo_root, tree.fetch(:kustomization)))
    raise "#{tree.fetch(:name)}: kubectl kustomize failed: #{stderr.strip}" unless status.success?
    YAML.load_stream(stdout).compact
  rescue Errno::ENOENT
    raise "kubectl is required to validate dashboard provisioning"
  end

  def self.check(sources, documents, tree_name)
    errors = []
    provisioned = {}
    documents.select { |document| document.is_a?(Hash) && document["kind"] == "ConfigMap" }.each do |configmap|
      next unless configmap.dig("metadata", "labels", "grafana_dashboard") == "1"
      name = configmap.dig("metadata", "name")
      json_keys = (configmap["data"] || {}).keys.select { |key| key.end_with?(".json") }
      if json_keys.length != 1
        errors << "#{tree_name}: ConfigMap #{name} must contain exactly one dashboard JSON entry (found #{json_keys.length})"
        next
      end
      key = json_keys.first
      source = sources.find { |item| item.fetch(:name) == key }
      unless source
        errors << "#{tree_name}: ConfigMap #{name} provisions #{key} but no source file provides it"
        next
      end
      if provisioned.key?(key)
        errors << "#{tree_name}: #{key} is rendered more than once"
        next
      end
      provisioned[key] = true

      if configmap.dig("metadata", "namespace") != "monitoring"
        errors << "#{tree_name}: ConfigMap #{name} (#{key}) must be in the monitoring namespace"
      end
      folder = configmap.dig("metadata", "annotations", "grafana_folder")
      unless valid_folder?(folder)
        errors << "#{tree_name}: ConfigMap #{name} (#{key}) must set a relative grafana_folder annotation (got #{folder.inspect})"
      end
      begin
        rendered = JSON.parse(configmap.fetch("data").fetch(key))
      rescue JSON::ParserError => error
        errors << "#{tree_name}: ConfigMap #{name} (#{key}) contains invalid JSON: #{error.message}"
        next
      end
      unless rendered == source.fetch(:dashboard)
        errors << "#{tree_name}: ConfigMap #{name} (#{key}) does not match #{source.fetch(:path)}"
      end
    end
    sources.each do |source|
      next if provisioned.key?(source.fetch(:name))
      errors << "#{tree_name}: #{source.fetch(:name)} (#{source.fetch(:path)}) is not provisioned by the #{tree_name} Kustomization"
    end
    errors
  end

  def self.run(repo_root, trees = TREES)
    total = 0
    trees.each do |tree|
      sources = load_sources(repo_root, tree)
      raise "#{tree.fetch(:name)}: no dashboard JSON files under #{tree.fetch(:dashboards)}" if sources.empty?
      documents = render(repo_root, tree)
      errors = check(sources, documents, tree.fetch(:name))
      raise errors.join("\n") unless errors.empty?
      total += sources.length
    end
    puts "  OK #{total} dashboards rendered across #{trees.length} Kustomizations with folders"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    repo_root = ARGV[0] || File.expand_path("../../../..", __dir__)
    DashboardProvisioningValidation.run(repo_root)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
