#!/usr/bin/env bash
# Print the [tools] pins from mise.toml as NAME_VERSION=x.y.z lines (e.g. for
# $GITHUB_ENV). mise.toml is the single source of tool versions for CI and local use.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

awk '
  /^\[/ { in_tools = ($0 == "[tools]"); next }
  in_tools && match($0, /^[a-z0-9_-]+ *= *"[^"]+"/) {
    split(substr($0, RSTART, RLENGTH), kv, /"/)
    name = $1; gsub(/[- ]/, "_", name)
    printf "%s_VERSION=%s\n", toupper(name), kv[2]
  }
' mise.toml
