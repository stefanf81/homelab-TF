SHELL := /bin/zsh

.PHONY: init plan apply destroy provision kubeconfig all

ROOT := .

init:
	tofu -chdir=$(ROOT) init

plan: provision
	tofu -chdir=$(ROOT) plan

apply: provision kubeconfig
	@true

destroy:
	tofu -chdir=$(ROOT) destroy

# Creates the VM; k3s itself installs at boot via cloud-init.
provision:
	tofu -chdir=$(ROOT) apply -target=module.proxmox

# Waits for cloud-init's k3s install to finish, then downloads kubeconfig.
kubeconfig: provision
	tofu -chdir=$(ROOT) apply -target=module.k3s_kubeconfig

all: init provision kubeconfig
