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
# The Alloy chart renders configMap.content through Helm's `tpl` (ConfigMap data and
# checksum annotation). Any "{{" is evaluated by Helm: a Go-template stage.template
# made every upgrade fail to render, so Flux silently kept the previous Alloy release.
if (line_no = config.lines.index { |line| line.include?("{{") })
  abort "Alloy config line #{line_no + 1} contains \"{{\"; the chart renders the config through Helm tpl, so the release would fail. " \
        "Avoid Go templates in the Alloy config (e.g. use stage.regex/stage.match instead of stage.template)."
end

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
# The WAF metrics share the source's synchronous fan-out with the Loki write path.
# Without the write-ahead log, an unreachable Loki stalls them once the in-memory
# queue fills (a load larger than these fixtures), so keep it from being dropped.
writer = blocks.find { |block| block.first.start_with?('loki.write "local"') }&.join("\n").to_s
abort 'loki.write "local" must keep `wal { enabled = true }` (see alloy-release.yaml)' unless writer =~ /wal\s*\{[^}]*enabled\s*=\s*true/m

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
