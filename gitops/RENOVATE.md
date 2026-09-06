# Renovate

Renovate runs through the Mogenius Renovate Operator in the `renovate`
namespace. The operator discovers `stefanf81/homelab-TF` daily at 03:17
Europe/Brussels, then runs a single hardened Renovate executor for that
repository. Updates create pull requests only; Renovate never pushes to `main`
or merges updates.

## Credentials

The SOPS-encrypted GitHub credential is at:

```bash
sops gitops/infrastructure/controllers/renovate/job/renovate-secrets.yaml
```

Use a fine-grained PAT for the dedicated GitHub bot account, restricted to
`stefanf81/homelab-TF`, with Contents, Pull requests, and Issues read/write.

## Manual Run

The operator performs discovery before it schedules an executor. Trigger a
discovery, wait for it to complete, then schedule the known project:

```bash
kubectl -n renovate annotate renovatejob renovate \
  renovate-operator.mogenius.com/discovery=true --overwrite

kubectl -n renovate annotate renovatejob renovate \
  renovate-operator.mogenius.com/schedule-all=true --overwrite
```

Inspect the resulting projects and Jobs:

```bash
kubectl -n renovate get renovatejobs,renovateprojects,jobs
```

## Private GHCR Images

GitHub Packages access is unavailable through fine-grained PATs. For private
GHCR image metadata, add a separate classic PAT with only `read:packages` to
`RENOVATE_HOST_RULES` in the same encrypted Secret:

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

The fine-grained platform token remains restricted to this repository. The
classic token is used only to retrieve registry metadata.

## Operation

The operator is namespace-scoped, policy-enforced, and has no public route.
Its executor runs without a Kubernetes API token and may egress only to DNS and
HTTPS. Completed jobs expire after 24 hours. The operator's UI is available
only through a local port-forward when needed:

```bash
kubectl -n renovate port-forward svc/renovate-operator 8081:8081
```
