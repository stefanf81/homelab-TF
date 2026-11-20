#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail when a secret could reach Git in plain text.
#
# - Every Secret with data/stringData under gitops/ must live in a file that the
#   .sops.yaml creation rule encrypts (path_regex), so `sops -e` covers it.
# - Every such file must be SOPS-encrypted for the age recipient in .sops.yaml:
#   a sops block with a MAC, and every data/stringData value an ENC[...] string.
#
# Offline and read-only; no keys needed. Run: ruby scripts/check-sops-secrets.rb
require "yaml"

root = File.expand_path("..", __dir__)
Dir.chdir(root)

rule = YAML.safe_load(File.read(".sops.yaml")).fetch("creation_rules").first
path_regex = Regexp.new(rule.fetch("path_regex"))
recipient = rule.fetch("age")

errors = []
files = `git ls-files -- gitops`.split("\n").select { |f| f.end_with?(".yaml", ".yml") }
files.each do |file|
  docs = YAML.load_stream(File.read(file)).compact.select { |d| d.is_a?(Hash) }
  encrypted_path = path_regex.match?(file)
  docs.each do |doc|
    values = %w[data stringData].flat_map { |k| (doc[k] || {}).to_a }
    name = "#{file}: #{doc['kind']}/#{doc.dig('metadata', 'name')}"
    if doc["kind"] == "Secret" && !values.empty? && !encrypted_path
      errors << "#{name} carries data outside a *-secrets.yaml file (not covered by .sops.yaml)"
    end
    next unless encrypted_path

    sops = doc["sops"]
    unless sops.is_a?(Hash) && sops["mac"].to_s.start_with?("ENC[")
      errors << "#{name} is not SOPS-encrypted (no sops block with a MAC)"
      next
    end
    recipients = Array(sops["age"]).map { |a| a["recipient"] }
    errors << "#{name} is not encrypted for #{recipient}" unless recipients.include?(recipient)
    values.each do |key, value|
      errors << "#{name}: #{key} is not encrypted" unless value.is_a?(String) && value.start_with?("ENC[")
    end
  end
end

if errors.empty?
  puts "OK #{files.count { |f| path_regex.match?(f) }} SOPS secret files encrypted; no Secret data outside them"
else
  warn errors.map { |e| "ERROR #{e}" }
  exit 1
end
