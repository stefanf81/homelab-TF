# Future Flux Bootstrap Steps

When you are ready to move from local-only GitOps scaffolding to a real Flux-managed cluster:

## 1. Create a remote GitHub repository

Example:

- `https://github.com/YOUR_ORG/YOUR_REPO`

## 2. Push this directory into that repository

From the `gitops/` directory, make it the repository root content or copy it into your chosen repo layout.

Important paths expected by the prepared Flux module:

- `gitops/clusters/taskflow`
- `infrastructure/controllers`
- `infrastructure/configs`

## 3. Add a root sensitive variable later

Example future root variable:

```hcl
variable "git_http_password" {
  type      = string
  sensitive = true
}
```

## 4. Wire `modules/flux-bootstrap` into root `main.tf`

Use the example from `../../modules/flux-bootstrap/README.md`.

## 5. Apply

```bash
make init
make provision
make kubeconfig
tofu apply
```

At that point Flux will reconcile `gitops/clusters/taskflow`, which in turn points to the infrastructure manifests under this GitOps tree.
