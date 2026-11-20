#!/usr/bin/env ruby
# The dashboard docs (SOURCE.md, panel descriptions and text panels) name the
# upstream versions whose metric names and labels the dashboards were checked
# against, e.g. "checked against Kyverno v1.20.0". This fails when such a
# mention no longer matches the major.minor version the repository deploys, so
# a minor upgrade cannot leave the dashboards described against an older release.
#
# Patch drift (mention 1.20.0, deployed 1.20.3) is reported but allowed: Renovate
# automerges patch updates, while minor and major updates stay manual and are the
# ones that remove or rename metrics (Kyverno 1.20 dropped kyverno_policy_results).
#
# Deployed versions are resolved from the Git pins: chart `appVersion` from the
# HelmRepository index, or from the OCI chart's config blob at the pinned digest.
# Needs network access to those registries; no Kubernetes access.
require "date"
require "digest"
require "json"
require "net/http"
require "uri"
require "yaml"
require_relative "validate-loki-version"

module DashboardVersionValidation
  NUMBER = /v?(?<version>\d+\.\d+(?:\.\d+)?)(?![\d.]*\d)/
  CHART = /(?:\s*\(|,\s*)(?:the app version of )?(?:stack )?chart v?(?<chart>\d+\.\d+\.\d+)/

  # label: how the docs name the component. source: the Git pin.
  COMPONENTS = [
    { name: "Cilium", labels: ["Cilium"],
      source: { kind: "oci", path: "gitops/infrastructure/controllers/cilium/repository.yaml" } },
    { name: "Kyverno", labels: ["Kyverno"],
      source: { kind: "oci", path: "gitops/infrastructure/controllers/kyverno/repository.yaml" } },
    { name: "cert-manager", labels: ["cert-manager"],
      source: { kind: "oci", path: "gitops/infrastructure/controllers/cert-manager/repository.yaml" } },
    { name: "Falco", labels: ["Falco"],
      source: { kind: "oci", path: "gitops/infrastructure/controllers/falco/repository.yaml" } },
    { name: "Trivy Operator", labels: ["Trivy Operator"],
      source: { kind: "helm", release: "gitops/infrastructure/controllers/trivy-operator/release.yaml",
                repositories: "gitops/infrastructure/controllers/trivy-operator/repository.yaml" } },
    { name: "Loki", labels: ["Loki"],
      source: { kind: "helm", release: "gitops/monitoring/logging/loki-release.yaml",
                repositories: "gitops/monitoring/logging/repositories.yaml" } },
    { name: "Alloy", labels: ["Alloy"],
      source: { kind: "helm", release: "gitops/monitoring/logging/alloy-release.yaml",
                repositories: "gitops/monitoring/logging/repositories.yaml" } },
    { name: "VictoriaMetrics", labels: ["VictoriaMetrics", "VMSingle"],
      source: { kind: "helm", release: "gitops/monitoring/platform/release.yaml",
                repositories: "gitops/monitoring/platform/repository.yaml" } }
  ].freeze

  DOCUMENTS = [
    "gitops/monitoring/*/dashboards/SOURCE.md",
    "gitops/monitoring/*/dashboards/*.json",
    "gitops/monitoring/tests/README.md"
  ].freeze

  Mention = Struct.new(:component, :path, :line, :text, :version, :chart, keyword_init: true)

  # Not part of a longer name; a JSON "\n" escape counts as a line start.
  START = /(?:(?<=\\n)|(?<![\w-]))/

  # Compiled once per label: building them per scanned line was ~2/3 of the run
  # (27k lines x labels x 2 patterns).
  PATTERNS = Hash.new do |cache, label|
    cache[label] = /#{START}#{Regexp.escape(label)}(?:\s+image)?\s+#{NUMBER}(?:#{CHART})?/
  end
  CHART_ONLY_PATTERNS = Hash.new do |cache, label|
    cache[label] = /#{START}#{Regexp.escape(label)}\s+(?:stack\s+)?chart\s+v?(?<chart>\d+\.\d+\.\d+)/
  end

  def self.pattern(label)
    PATTERNS[label]
  end

  def self.chart_only_pattern(label)
    CHART_ONLY_PATTERNS[label]
  end

  # Version mentions per component, with file and line for the report.
  def self.mentions(root, components = COMPONENTS, documents = DOCUMENTS)
    paths = documents.flat_map { |glob| Dir.glob(File.join(root, glob)) }.sort.uniq
    paths.flat_map do |path|
      File.readlines(path, chomp: true, encoding: "UTF-8").each_with_index.flat_map do |line, index|
        components.flat_map do |component|
          component[:labels].flat_map do |label|
            found = line.to_enum(:scan, pattern(label)).map { Regexp.last_match }.map do |match|
              Mention.new(component: component[:name], path: path.delete_prefix("#{root}/"), line: index + 1,
                          text: match[0], version: match[:version], chart: match[:chart])
            end
            found + line.to_enum(:scan, chart_only_pattern(label)).map { Regexp.last_match }.map do |match|
              Mention.new(component: component[:name], path: path.delete_prefix("#{root}/"), line: index + 1,
                          text: match[0], version: nil, chart: match[:chart])
            end
          end
        end
      end
    end.uniq { |mention| [mention.component, mention.path, mention.line, mention.text] }
  end

  def self.minor(version)
    version.delete_prefix("v").split(".").first(2).join(".")
  end

  # [failures, notes] for mentions against { name => { app:, chart: } }.
  def self.compare(mentions, deployed)
    failures = []
    notes = []
    mentions.each do |mention|
      pin = deployed.fetch(mention.component)
      where = "#{mention.path}:#{mention.line}: #{mention.text.inspect}"
      current = "#{mention.component} #{pin[:app]} (chart #{pin[:chart]})"
      { version: :app, chart: :chart }.each do |field, key|
        named = mention[field]
        next unless named
        actual = pin.fetch(key)
        if minor(named) != minor(actual)
          failures << "#{where} names #{field == :chart ? 'chart ' : ''}#{named}, but the repository deploys " \
                      "#{current}; re-check the dashboard against #{minor(actual)} and update the mention"
        elsif named.count(".") == 2 && named.delete_prefix("v") != actual.delete_prefix("v")
          notes << "#{where} names #{field == :chart ? 'chart ' : ''}#{named}; deployed #{current} (patch drift, allowed)"
        end
      end
    end
    [failures, notes]
  end

  # --- Deployed versions ------------------------------------------------------

  def self.documents(path)
    YAML.load_stream(File.read(path)).compact
  end

  def self.deployed(root, component)
    source = component[:source]
    case source[:kind]
    when "oci" then oci_pin(File.join(root, source[:path]))
    when "helm" then helm_pin(File.join(root, source[:release]), File.join(root, source[:repositories]))
    else raise "unknown source kind #{source[:kind].inspect} for #{component[:name]}"
    end
  end

  def self.helm_pin(release_path, repositories_path)
    releases = documents(release_path).select { |document| document["kind"] == "HelmRelease" }
    raise "expected one HelmRelease in #{release_path}" unless releases.length == 1
    release = releases.first
    chart = release.dig("spec", "chart", "spec") or raise "#{release_path}: HelmRelease has no spec.chart.spec"
    source = chart.fetch("sourceRef")
    raise "#{release_path}: chart source must be a HelmRepository" unless source["kind"] == "HelmRepository"
    namespace = source["namespace"] || release.dig("metadata", "namespace")
    repository = documents(repositories_path).find do |document|
      document["kind"] == "HelmRepository" && document.dig("metadata", "name") == source["name"] &&
        (document.dig("metadata", "namespace") || namespace) == namespace
    end
    raise "HelmRepository #{namespace}/#{source['name']} not found in #{repositories_path}" unless repository
    url = repository.dig("spec", "url")
    raise "#{repositories_path}: HelmRepository #{source['name']} must use HTTP(S)" unless %w[http https].include?(URI(url).scheme)
    index = YAML.safe_load(LokiVersionValidation.get(URI.join("#{url.delete_suffix('/')}/", "index.yaml").to_s),
                           permitted_classes: [Date, Time])
    version = chart.fetch("version").to_s
    { chart: version.delete_prefix("v"), app: LokiVersionValidation.app_version(index, chart.fetch("chart"), version) }
  end

  def self.oci_pin(path)
    repositories = documents(path).select { |document| document["kind"] == "OCIRepository" }
    raise "expected one OCIRepository in #{path}" unless repositories.length == 1
    spec = repositories.first.fetch("spec")
    tag = spec.dig("ref", "tag") or raise "#{path}: OCIRepository has no ref.tag"
    digest = spec.dig("ref", "digest")
    metadata = oci_chart_metadata(spec.fetch("url"), digest || tag, digest)
    app = metadata["appVersion"]
    raise "#{path}: chart metadata has no appVersion" unless app.is_a?(String) && !app.strip.empty?
    if metadata["version"].to_s.delete_prefix("v") != tag.to_s.delete_prefix("v")
      raise "#{path}: digest #{digest} is chart #{metadata['version']}, not the pinned tag #{tag}"
    end
    { chart: tag.to_s.delete_prefix("v"), app: app.delete_prefix("v") }
  end

  # Helm stores Chart.yaml as JSON in the OCI manifest's config blob.
  def self.oci_chart_metadata(url, reference, digest)
    uri = URI(url)
    raise "#{url}: expected an oci:// URL" unless uri.scheme == "oci"
    registry = "https://#{uri.host}#{":#{uri.port}" if uri.port}"
    repository = uri.path.delete_prefix("/")
    token = nil
    accept = "application/vnd.oci.image.manifest.v1+json"
    manifest_url = "#{registry}/v2/#{repository}/manifests/#{reference}"
    response = request(manifest_url, accept: accept)
    if response.code == "401"
      token = registry_token(response["www-authenticate"], url)
      response = request(manifest_url, accept: accept, token: token)
    end
    raise "HTTP #{response.code} fetching #{manifest_url}" unless response.is_a?(Net::HTTPSuccess)
    verify_digest(response.body, digest, manifest_url) if digest
    config = JSON.parse(response.body).fetch("config")
    unless config["mediaType"] == "application/vnd.cncf.helm.config.v1+json"
      raise "#{url}@#{reference} is not a Helm chart (config #{config['mediaType']})"
    end
    blob_url = "#{registry}/v2/#{repository}/blobs/#{config.fetch('digest')}"
    blob = request(blob_url, token: token)
    raise "HTTP #{blob.code} fetching #{blob_url}" unless blob.is_a?(Net::HTTPSuccess)
    verify_digest(blob.body, config.fetch("digest"), blob_url)
    JSON.parse(blob.body)
  end

  def self.verify_digest(body, digest, url)
    algorithm, expected = digest.split(":", 2)
    raise "#{url}: unsupported digest #{digest}" unless algorithm == "sha256"
    actual = Digest::SHA256.hexdigest(body)
    raise "#{url}: content digest sha256:#{actual} does not match #{digest}" unless actual == expected
  end

  # Anonymous pull token for a Bearer challenge (public charts only).
  def self.registry_token(challenge, url)
    raise "#{url}: registry requires authentication without a Bearer challenge" unless challenge&.start_with?("Bearer ")
    fields = challenge.delete_prefix("Bearer ").scan(/(\w+)="([^"]*)"/).to_h
    realm = URI(fields.fetch("realm") { raise "#{url}: Bearer challenge has no realm" })
    realm.query = URI.encode_www_form(fields.slice("service", "scope"))
    response = request(realm.to_s)
    raise "HTTP #{response.code} fetching an anonymous token for #{url}" unless response.is_a?(Net::HTTPSuccess)
    body = JSON.parse(response.body)
    body["token"] || body["access_token"] or raise "#{url}: token response has no token"
  end

  # GET with redirects. The registry token is not forwarded to another host
  # (blob downloads redirect to signed CDN URLs that reject extra credentials).
  def self.request(url, accept: nil, token: nil, redirects: 5)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port, :ENV)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30
    get = Net::HTTP::Get.new(uri.request_uri)
    get["Accept"] = accept if accept
    get["Authorization"] = "Bearer #{token}" if token
    response = http.request(get)
    if response.is_a?(Net::HTTPRedirection) && response["location"]
      raise "too many redirects fetching #{url}" unless redirects.positive?
      target = URI.join(url, response["location"])
      return request(target.to_s, accept: accept, token: target.host == uri.host ? token : nil,
                                  redirects: redirects - 1)
    end
    response
  end

  def self.run(root, components = COMPONENTS, documents = DOCUMENTS)
    found = mentions(root, components, documents)
    deployed = components.to_h { |component| [component[:name], deployed(root, component)] }
    failures, notes = compare(found, deployed)
    notes.each { |note| puts "  note: #{note}" }
    raise failures.join("\n") unless failures.empty?

    counts = found.group_by(&:component).transform_values(&:length)
    summary = components.map { |component| "#{component[:name]} #{deployed[component[:name]][:app]} (#{counts.fetch(component[:name], 0)})" }
    puts "  OK #{found.length} version mentions match the deployed minor versions: #{summary.join(', ')}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    root = ARGV.first || File.expand_path("../../..", __dir__)
    DashboardVersionValidation.run(root)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
