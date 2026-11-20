#!/usr/bin/env ruby
# frozen_string_literal: true

# Emulate Flux postBuild variable substitution for one reconciled path.
#
# Usage: kustomize build <path> | ruby scripts/flux-postbuild.rb <path> > rendered.yaml
#
# Looks up the Flux Kustomization(s) in gitops/clusters/taskflow/ whose spec.path is
# <path>. If one declares postBuild.substituteFrom the cluster-vars ConfigMap, the
# rendered stream is substituted with the values from cluster-vars.yaml, the way
# kustomize-controller does it: ${NAME} -> value, $${ -> ${ (escape). Flux replaces
# an undefined ${...} with an empty string, so any ${...} left after substitution is
# an error (typo or missing key).
#
# Without postBuild the stream is passed through unchanged, but it is an error if it
# references a cluster-vars key: Flux would apply the literal ${NAME}.
#
# SOPS: kustomize-controller decrypts SOPS-encrypted documents and drops their
# top-level `sops:` metadata block before applying. When the path's Kustomization
# declares `decryption.provider: sops` the block is removed here too, so strict
# schema validation sees what Flux applies (values stay encrypted strings). Without
# the decryption block it is an error: Flux would try to apply the encrypted
# document as is.

require "yaml"

CLUSTER_DIR = "gitops/clusters/taskflow"
VARS_FILE = File.join(CLUSTER_DIR, "cluster-vars.yaml")
VAR_REF = /(?<!\$)\$\{([^}]*)\}/

path = ARGV.fetch(0) { abort "usage: #{File.basename(__FILE__)} <path>" }
path = path.delete_prefix("./").chomp("/")

def documents(file)
  YAML.load_stream(File.read(file)).compact.select { |d| d.is_a?(Hash) }
end

kustomizations = Dir[File.join(CLUSTER_DIR, "*.yaml")].sort.flat_map { |f| documents(f) }.select do |doc|
  doc["kind"] == "Kustomization" && doc["apiVersion"].to_s.start_with?("kustomize.toolkit.fluxcd.io/") &&
    doc.dig("spec", "path").to_s.delete_prefix("./").chomp("/") == path
end

uses_vars = kustomizations.any? do |k|
  Array(k.dig("spec", "postBuild", "substituteFrom")).any? do |src|
    src["kind"] == "ConfigMap" && src["name"] == "cluster-vars"
  end
end
if kustomizations.size > 1 && kustomizations.map { |k| k.dig("spec", "postBuild") }.uniq.size > 1
  abort "#{path}: reconciled by several Flux Kustomizations with different postBuild settings"
end

vars_doc = documents(VARS_FILE).find { |d| d["kind"] == "ConfigMap" && d.dig("metadata", "name") == "cluster-vars" }
abort "#{VARS_FILE}: no ConfigMap named cluster-vars" unless vars_doc
vars = (vars_doc["data"] || {}).transform_values(&:to_s)

# Rendered YAML is UTF-8 regardless of the caller's locale (dashboards contain
# non-ASCII text; a US-ASCII locale would make the regexes below raise).
text = $stdin.read.force_encoding(Encoding::UTF_8)

decrypts = kustomizations.any? { |k| k.dig("spec", "decryption", "provider") == "sops" }
if text.match?(/^sops:/)
  unless decrypts
    abort "#{path}: contains SOPS-encrypted documents but no Flux Kustomization for it " \
          "declares decryption.provider: sops"
  end
  # Drop each top-level `sops:` key with its indented body (rendered output puts
  # top-level keys at column 0, so the block ends at the next unindented line).
  in_sops = false
  text = text.each_line.reject do |line|
    if line.start_with?("sops:")
      in_sops = true
    elsif in_sops && !(line.start_with?(" ", "\t") || line.strip.empty?)
      in_sops = false
    end
    in_sops
  end.join
end

if uses_vars
  missing = []
  text = text.gsub(VAR_REF) do
    name = Regexp.last_match(1)
    vars.fetch(name) { missing << name; Regexp.last_match(0) }
  end
  text = text.gsub("$${", "${")
  unless missing.empty?
    abort "#{path}: ${#{missing.uniq.sort.join('}, ${')}} not defined in #{VARS_FILE} " \
          "(Flux would substitute an empty string; write a literal as $${...})"
  end
else
  used = vars.keys.select { |k| text.include?("${#{k}}") }
  unless used.empty?
    abort "#{path}: uses ${#{used.sort.join('}, ${')}} but no Flux Kustomization for it " \
          "declares postBuild.substituteFrom cluster-vars"
  end
end

$stdout.write(text)
