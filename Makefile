# Recipes are POSIX sh only; the default shell keeps this portable (no zsh required).
.PHONY: init plan apply destroy provision kubeconfig bootstrap-foundation all cache cache-clean ensure-cache fmt validate lint validate-gitops

ROOT := .

# ------------------------------------------------------------------------------
# OpenTofu provider plugin cache
#
# Providers are tens of MB each. TF_PLUGIN_CACHE_DIR (honoured by OpenTofu) keeps
# one copy per provider version outside the project, so a fresh `tofu init`
# (after deleting .terraform/, in a second checkout or worktree) links from the
# cache instead of downloading again. It used to live under .terraform/, which is
# exactly what gets deleted, so it never saved a download.
#
# Override with `make TF_PLUGIN_CACHE_DIR=...` or by exporting the variable; set
# it in your shell (or plugin_cache_dir in ~/.tofurc) to cover direct `tofu` runs.
# ------------------------------------------------------------------------------
TF_PLUGIN_CACHE_DIR ?= $(HOME)/.cache/opentofu/plugins
export TF_PLUGIN_CACHE_DIR

# Ensure the cache directory exists; OpenTofu refuses to cache into a missing dir.
ensure-cache:
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"

init: ensure-cache
	tofu -chdir=$(ROOT) init

# Formatting gate (CI-friendly: exits non-zero on drift). `tofu fmt -recursive` fixes it.
fmt:
	tofu -chdir=$(ROOT) fmt -check -recursive

# Static validation of the root module and both child modules (needs `make init` first).
validate: ensure-cache
	tofu -chdir=$(ROOT) validate

# Static analysis of the OpenTofu code (config in .tflint.hcl; needs tflint installed).
lint:
	tflint --recursive --format compact

# Render and schema-validate every path Flux reconciles (needs kustomize or kubectl, and kubeconform).
validate-gitops:
	scripts/validate-gitops.sh

# Non-mutating OpenTofu preview. Use `make provision` or `make apply` to change infrastructure.
plan: ensure-cache
	tofu -chdir=$(ROOT) plan

# Full bring-up in one plan: the VM, then (once cloud-init has installed k3s) the
# kubeconfig fetch. A single apply matters: the fetch re-runs when the VM is
# rebuilt only if both modules are planned together (the build id is unknown
# until apply); the old two-step -target flow left the previous cluster's
# kubeconfig in place after a VM replacement, and planned and prompted twice.
apply: ensure-cache
	tofu -chdir=$(ROOT) apply

destroy: ensure-cache
	tofu -chdir=$(ROOT) destroy

# Single-module steps, for debugging. Prefer `make apply`.
# Creates the VM; k3s itself installs at boot via cloud-init.
provision: ensure-cache
	tofu -chdir=$(ROOT) apply -target=module.proxmox

# Waits for cloud-init's k3s install to finish, then downloads kubeconfig.
kubeconfig: ensure-cache provision
	tofu -chdir=$(ROOT) apply -target=module.k3s_kubeconfig

# Installs Gateway API CRDs, Cilium, CoreDNS and Flux Operator from the exact
# GitOps chart versions and cluster-vars-substituted values so Flux adopts them.
# $(CURDIR), not $(PWD): with `make -C <dir>` PWD is still the caller's directory.
bootstrap-foundation:
	KUBECONFIG="$${KUBECONFIG:-$(CURDIR)/kubeconfig.yaml}" scripts/bootstrap-foundation.sh

all: init apply

# Show the cache location and its current on-disk size.
cache:
	@echo "OpenTofu provider plugin cache:"
	@echo "  $(TF_PLUGIN_CACHE_DIR)"
	@if [ -d "$(TF_PLUGIN_CACHE_DIR)" ]; then \
		echo "  Size: $$(du -sh "$(TF_PLUGIN_CACHE_DIR)" | cut -f1)"; \
	else \
		echo "  (not created yet — will be on next 'make init')"; \
	fi

# Drop all cached provider binaries (e.g. after a major provider upgrade bump).
# OpenTofu never prunes the cache itself, so this is the supported cleanup path.
# The default directory is per user, so this also empties it for other projects
# that use it; they simply download again on their next init.
cache-clean:
	@echo "Removing cached providers in $(TF_PLUGIN_CACHE_DIR)"
	@rm -rf "$(TF_PLUGIN_CACHE_DIR)"
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
