SHELL := /bin/zsh

.PHONY: init plan apply destroy provision kubeconfig all cache cache-clean

ROOT := .

# ------------------------------------------------------------------------------
# OpenTofu provider plugin cache
#
# Providers can be hundreds of MB. By pointing OpenTofu at a shared, project-local
# cache directory we download each distinct provider binary exactly once and reuse
# it (via symlink where the filesystem allows) across `init`/`plan`/`apply`/`destroy`.
#
# OpenTofu will NOT create this directory itself, so `ensure-cache` creates it
# before any tofu command runs. The path lives under `.terraform/`, which is
# already excluded from version control by the `**/.terraform/*` rule in .gitignore.
#
# This is the Terraform-compatible `TF_PLUGIN_CACHE_DIR` env var, which OpenTofu
# honors. To make the cache persistent across direct `tofu` invocations (outside
# `make`), export the same variable in your shell, or use a project-local CLI
# config file (`.tofurc` / `tofu.tfrc`) with `plugin_cache_dir = ".terraform/providers-cache"`.
# ------------------------------------------------------------------------------
export TF_PLUGIN_CACHE_DIR := $(ROOT)/.terraform/providers-cache

# Ensure the cache directory exists; OpenTofu refuses to cache into a missing dir.
ensure-cache:
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"

init: ensure-cache
	tofu -chdir=$(ROOT) init

# Non-mutating OpenTofu preview. Use `make provision` or `make apply` to change infrastructure.
plan: ensure-cache
	tofu -chdir=$(ROOT) plan

# Convenience bring-up target: applies the Proxmox VM and kubeconfig sync targets.
# Run `tofu -chdir=$(ROOT) apply` directly when a full root-module apply is required.
apply: ensure-cache provision kubeconfig
	@true

destroy: ensure-cache
	tofu -chdir=$(ROOT) destroy

# Creates the VM; k3s itself installs at boot via cloud-init.
provision: ensure-cache
	tofu -chdir=$(ROOT) apply -target=module.proxmox

# Waits for cloud-init's k3s install to finish, then downloads kubeconfig.
kubeconfig: ensure-cache provision
	tofu -chdir=$(ROOT) apply -target=module.k3s_kubeconfig

all: init provision kubeconfig

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
cache-clean:
	@echo "Removing cached providers in $(TF_PLUGIN_CACHE_DIR)"
	@rm -rf "$(TF_PLUGIN_CACHE_DIR)"
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
