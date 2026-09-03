# Renovate

Renovate runs as a daily, manually reviewed dependency-update CronJob in the
`renovate` namespace. It creates pull requests only; it never pushes to `main`
or merges updates.

## Activate

1. Create a fine-grained PAT for the dedicated GitHub bot account, restricted to
   `stefanf81/homelab-TF`, with Contents, Pull requests, and Issues read/write.
2. Edit the encrypted Secret locally and replace the placeholder:

   ```bash
   sops gitops/infrastructure/controllers/renovate/renovate-secrets.yaml
   ```

3. Remove the `dryRun` property from
   `gitops/infrastructure/controllers/renovate/renovate-config.yaml` after the
   initial scan succeeds.
4. Change `suspend: true` to `suspend: false` in
   `gitops/infrastructure/controllers/renovate/cronjob.yaml`.

## Validate the initial scan

Keep the CronJob suspended and `dryRun: "full"`, reconcile Flux, and start a
one-off Job:

```bash
flux reconcile kustomization renovate --with-source
kubectl -n renovate create job --from=cronjob/renovate renovate-dry-run
kubectl -n renovate logs job/renovate-dry-run -f
```

The scan should discover Flux HelmRelease charts, Kubernetes images, Dockerfile
bases, and the explicitly annotated tag-only Helm values. It must not propose
changes to generated Flux manifests, vendored Gateway API resources, Kubernetes
API versions, or the Flux-managed TaskFlow backend/frontend digests.

Renovate may still list the generated Flux system manifest during extraction
because the Flux manager always has a built-in `gotk-components.yaml` detector.
The repository policy disables `fluxcd/flux2`, so it cannot open PRs for that
generated file.

## Private GHCR Images

GitHub does not support GitHub Packages access through fine-grained PATs.
Therefore, the custom WAF image requires a separate classic PAT from the bot
account with only the `read:packages` scope. Configure it in the same SOPS
Secret as valid JSON, replacing the empty `RENOVATE_HOST_RULES` value:

```json
[
  {
    "hostType": "docker",
    "matchHost": "ghcr.io",
    "username": "YOUR_BOT_ACCOUNT",
    "password": "CLASSIC_PAT_WITH_READ_PACKAGES_ONLY"
  }
]
```

The fine-grained platform PAT remains restricted to this repository. The
classic token is used only for registry metadata and cannot create branches or
pull requests.

## Normal operation

The CronJob runs at 03:17 Europe/Brussels. It permits one active run, retains
two successful and three failed Jobs, and opens at most three dependency PRs at
one time. All updates require manual review and merge.
