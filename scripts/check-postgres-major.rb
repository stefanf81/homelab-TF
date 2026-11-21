#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail when the PostgreSQL image and its data directory name different major versions.
#
# The server keeps its data in /var/lib/postgresql/<major>/docker (PGDATA in
# gitops/apps/taskflow/postgres-db.yaml), on a volume mounted at /var/lib/postgresql.
# A major upgrade is a data migration, not an image bump:
# - a newer image on the old directory does not start ("database files are
#   incompatible with server"), so the database is down until the change is reverted;
# - pointing PGDATA at a new, empty directory makes the image initialise an empty
#   database, and the backend's Flyway then builds an empty schema in it.
# Renovate proposes the next major as an image-only change; this check keeps that
# pull request red until it also migrates the data (dump with the old image and
# restore with the new one in init containers, see the Git history of that file for
# the 18 -> 19 upgrade).
#
# Offline and read-only. Run: ruby scripts/check-postgres-major.rb
require "yaml"

root = File.expand_path("..", __dir__)
Dir.chdir(root)

FILE = "gitops/apps/taskflow/postgres-db.yaml"
MOUNT = "/var/lib/postgresql"

docs = YAML.load_stream(File.read(FILE)).compact.select { |d| d.is_a?(Hash) }
deployment = docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata", "name") == "postgres-db" }
abort "#{FILE}: no Deployment named postgres-db" unless deployment
container = deployment.dig("spec", "template", "spec", "containers").find { |c| c["name"] == "postgres" }
abort "#{FILE}: no container named postgres" unless container

errors = []
image_major = container["image"].to_s[%r{\A(?:[^/]+/)*postgres:(\d+)[.\-@]}, 1]
errors << "cannot read the PostgreSQL major from the image #{container['image'].inspect}" unless image_major

pgdata = Array(container["env"]).find { |e| e["name"] == "PGDATA" }&.fetch("value", nil)
if pgdata.nil?
  errors << "the postgres container sets no PGDATA"
elsif image_major && pgdata != "#{MOUNT}/#{image_major}/docker"
  errors << "the image is PostgreSQL #{image_major} but PGDATA is #{pgdata} (expected #{MOUNT}/#{image_major}/docker): " \
            "a major upgrade must migrate the data, see the header of #{__FILE__.delete_prefix("#{root}/")}"
end

mounts = Array(container["volumeMounts"]).map { |m| m["mountPath"] }
unless mounts.include?(MOUNT)
  errors << "the data volume must be mounted at #{MOUNT}, so that the old and the new major's directories share it"
end

if errors.empty?
  puts "OK: PostgreSQL #{image_major} with PGDATA #{pgdata}"
else
  errors.each { |e| warn "#{FILE}: #{e}" }
  exit 1
end
