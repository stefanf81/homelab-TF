#!/usr/bin/env ruby
# Build a test Alloy config from the shipped alloy-release.yaml: keep every
# processing block and the WAF source's real forward_to fan-out, and replace
# Kubernetes discovery with file tails over fixture logs.
# usage: validate-alloy-metrics-config.rb <alloy-release.yaml> <out.alloy> <loki push url>
require "yaml"

release, out, loki_url = ARGV
abort "usage: #{File.basename(__FILE__)} <alloy-release.yaml> <out.alloy> <loki push url>" unless loki_url

release_doc = YAML.load_stream(File.read(release)).compact.find { |d| d["kind"] == "HelmRelease" && d.dig("metadata", "name") == "alloy" }
abort "Alloy HelmRelease not found in #{release}" unless release_doc
config = release_doc.dig("spec", "values", "alloy", "configMap", "content") or abort "Alloy config content missing"

# Top-level blocks start at column 0 with `name "label" {` and end at a lone `}`.
blocks = []
current = nil
config.lines.map(&:chomp).each do |line|
  if current
    current << line
    if line == "}"
      blocks << current
      current = nil
    end
  elsif !line.empty? && line !~ /\A[\s\/]/ && line.end_with?("{")
    current = [line]
  end
end
abort "unterminated block in Alloy config" if current

replaced = %w[discovery.kubernetes discovery.relabel loki.source.kubernetes local.file_match loki.source.file]
waf_forward = nil
kept = blocks.reject do |block|
  head = block.first
  waf_forward = block.join("\n")[/forward_to\s*=\s*(\[.*?\])/m, 1] if head.start_with?('loki.source.kubernetes "taskflow_wafs"')
  replaced.any? { |prefix| head.start_with?(prefix) }
end
abort "WAF source block not found in Alloy config" unless waf_forward

text = kept.map { |block| block.join("\n") }.join("\n\n")
text = text.gsub("http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push", loki_url)
text << <<~ALLOY

  local.file_match "waf" {
    path_targets = [
      {__path__ = "/logs/frontend.log", job = "coraza-waf", application = "taskflow-frontend", namespace = "taskflow", pod = "taskflow-frontend-waf-aaaaa", container = "waf"},
      {__path__ = "/logs/backend.log", job = "coraza-waf", application = "taskflow-backend", namespace = "taskflow", pod = "taskflow-backend-waf-bbbbb", container = "waf"},
    ]
  }

  loki.source.file "waf" {
    targets    = local.file_match.waf.targets
    forward_to = #{waf_forward}
  }
ALLOY
File.write(out, text)
puts "test config: #{kept.length} blocks kept, WAF fan-out #{waf_forward.scan(/loki\.process\.(\w+)\.receiver/).flatten.join(', ')}"
