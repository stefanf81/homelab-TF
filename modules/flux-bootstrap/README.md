# Flux Bootstrap Module

This module is ready for **future GitHub bootstrap via HTTPS + PAT**.

It is **not wired into the root Terraform yet** because Flux requires a remote Git repository and your GitOps content currently exists only locally under `../../gitops`.

## What this module does

When you later connect it, it will:

1. install Flux into the target cluster using the kubeconfig produced by the root project
2. commit Flux bootstrap manifests into your GitHub repository
3. configure the cluster to reconcile from `clusters/homelab` (or another path you choose)

## Expected future root usage

```hcl
module "flux_bootstrap" {
  source = "./modules/flux-bootstrap"

  kubeconfig_path    = module.k3s_kubeconfig.kubeconfig_path
  git_url            = "https://github.com/YOUR_ORG/YOUR_REPO.git"
  git_branch         = "main"
  git_http_username  = "YOUR_GITHUB_USERNAME"
  git_http_password  = var.git_http_password
  cluster_path       = "clusters/homelab"

  depends_on = [module.k3s_kubeconfig]
}
```

## Prerequisites later

- the `gitops/` directory has been pushed to a remote GitHub repository
- the repository is reachable from the machine running OpenTofu
- you have a GitHub PAT with repo write permissions
- `git_url`, username, and token are set correctly

## Recommended flow later

1. create a GitHub repo
2. push `gitops/` into it
3. add a new sensitive root variable like `git_http_password`
4. wire this module into root `main.tf`
5. run `tofu init && tofu apply`
