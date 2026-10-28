#!/usr/bin/env ruby
require "json"
require "yaml"
require "date"
require "net/http"
require "uri"

module LokiVersionValidation
  def self.get(url, local: false, redirects: 3)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port, local ? nil : :ENV)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 30
    response = http.get(uri.request_uri)
    if response.is_a?(Net::HTTPRedirection) && redirects.positive? && response["location"]
      return get(URI.join(url, response["location"]).to_s, local: local, redirects: redirects - 1)
    end
    raise "HTTP #{response.code} fetching #{url}" unless response.is_a?(Net::HTTPSuccess)
    response.body
  end

  def self.app_version(index, chart, version)
    entry = index.fetch("entries").fetch(chart).find { |candidate| candidate["version"].to_s == version.to_s }
    raise "chart #{chart} version #{version} not found in repository index" unless entry
    value = entry["appVersion"]
    raise "chart #{chart} version #{version} has no appVersion" unless value.is_a?(String) && !value.strip.empty?
    value.delete_prefix("v")
  end

  def self.deployment_version(release_path, repositories_path)
    release = YAML.load_stream(File.read(release_path)).compact.find do |document|
      document["kind"] == "HelmRelease" && document.dig("metadata", "name") == "loki"
    end
    raise "Loki HelmRelease not found in #{release_path}" unless release
    # An explicit runtime tag supersedes the chart default.
    tag = release.dig("spec", "values", "loki", "image", "tag")
    return tag.delete_prefix("v") if tag.is_a?(String) && !tag.empty?

    chart = release.fetch("spec").fetch("chart").fetch("spec")
    source = chart.fetch("sourceRef")
    raise "Loki chart must use an HTTP HelmRepository" unless source["kind"] == "HelmRepository"
    namespace = source["namespace"] || release.dig("metadata", "namespace")
    repository = YAML.load_stream(File.read(repositories_path)).compact.find do |document|
      document["kind"] == "HelmRepository" && document.dig("metadata", "name") == source["name"] &&
        document.dig("metadata", "namespace") == namespace
    end
    raise "HelmRepository #{namespace}/#{source['name']} not found" unless repository
    url = repository.fetch("spec").fetch("url")
    raise "Loki repository must use HTTP(S)" unless %w[http https].include?(URI(url).scheme)
    index_url = URI.join("#{url.delete_suffix('/')}/", "index.yaml").to_s
    index = YAML.safe_load(get(index_url), permitted_classes: [Date, Time])
    app_version(index, chart.fetch("chart"), chart.fetch("version"))
  end

  def self.check_runtime(url, expected, allow_mismatch: false)
    actual = JSON.parse(get(URI.join(url, "/loki/api/v1/status/buildinfo").to_s, local: true))["version"]
    raise "validation Loki buildinfo has no version" unless actual.is_a?(String) && !actual.empty?
    if actual.delete_prefix("v") != expected.delete_prefix("v")
      message = "validation Loki version #{actual} does not match deployed version #{expected}"
      raise "#{message}; use ALLOW_LOKI_VERSION_MISMATCH=1 only for migration testing" unless allow_mismatch
      warn "Migration override: #{message}"
    end
    actual
  rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError => error
    raise "Loki version check failed at #{url}: #{error.class}: #{error.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise "usage: #{File.basename(__FILE__)} <loki-release.yaml> <repositories.yaml>" unless ARGV.length == 2
    puts LokiVersionValidation.deployment_version(*ARGV)
  rescue StandardError => error
    warn "Cannot resolve deployed Loki version: #{error.message}"
    exit 1
  end
end
