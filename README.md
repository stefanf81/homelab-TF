# Homelab OpenTofu

Single-root OpenTofu project for provisioning a Proxmox VM and bootstrapping k3s.
Cluster add-ons are now scaffolded for GitOps under `gitops/` rather than being
managed directly by Terraform.

## Layout

- `modules/proxmox` – provisions the VM; cloud-init installs k3s at boot (no SSH provisioner needed for this part, per [Terraform's own guidance](https://developer.hashicorp.com/terraform/language/post-apply-operations) to prefer cloud-init over provisioners)
- `modules/k3s-kubeconfig` – waits for cloud-init's k3s install to finish, then fetches `kubeconfig.yaml` over SSH
- `modules/flux-bootstrap` – future GitHub-ready Flux bootstrap module template (prepared but not wired in yet)
- `gitops/` – Flux-style GitOps layout for MetalLB, Longhorn, and cert-manager

## Workflow

Use the Makefile to enforce the correct sequence:

```bash
make init
make apply
```

If you want to run phases manually:

```bash
make provision   # create the VM (k3s installs itself via cloud-init)
make kubeconfig  # wait for k3s + fetch kubeconfig.yaml
```

## Why it's still phased

k3s installation no longer needs an SSH provisioner — it happens automatically
at boot via cloud-init, same as the rest of the OS tuning. The kubeconfig file still only exists once cloud-init has finished
running on the VM. So `modules/k3s-kubeconfig` remains as a small bridge that
waits for that file and downloads it — everything else is boot-time, not
apply-time-scripted.

## Preflight checklist

Before your first real deploy, verify these three items:

1. Create a remote Git repository and wire Flux bootstrap to it.
2. Replace the placeholder MetalLB IP range in `gitops/infrastructure/configs/metallb/ipaddresspool.yaml`.
3. Run a test deploy of the Proxmox + cloud-init bootstrap path and confirm:
   - VM boots successfully
   - k3s installs on boot
   - `kubeconfig.yaml` is fetched successfully
   - SSH access works

## Notes

- The kubeconfig is written to `kubeconfig_path` (default `./kubeconfig.yaml`).
- `k3s_token` and `docker_hub_mirror` are consumed by `modules/proxmox` and
  baked into the VM's cloud-init user-data.
- The `gitops/` directory is local scaffolding for now. Once you create a remote
  Git repository, push that directory there and then wire in
  `modules/flux-bootstrap` to install Flux against it.
- See `gitops/FUTURE_FLUX_BOOTSTRAP.md` and `modules/flux-bootstrap/README.md`
  for the exact future GitHub + PAT bootstrap wiring.
