# GitOps Layout

This directory is intended to become the future Git repository that Flux will reconcile from.

Right now it only exists locally. Once you create a remote Git repository (for example on GitHub), you can copy or push this directory there and then use the Terraform `modules/flux-bootstrap` module template to bootstrap Flux against it.

## Structure

- `clusters/homelab/` – cluster-specific Flux `Kustomization` objects
- `infrastructure/controllers/` – HelmReleases and supporting manifests for shared infra controllers
- `infrastructure/configs/` – cluster-specific config objects consumed by those controllers

## Next step later

1. Create a remote repository.
2. Push this `gitops/` directory into it.
3. Follow `./FUTURE_FLUX_BOOTSTRAP.md`.
4. Wire `modules/flux-bootstrap` into the root Terraform when you are ready.
