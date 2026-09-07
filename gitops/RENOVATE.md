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

## Private GHCR Images & Release Notes (Changelogs)

GitHub Packages access is unavailable through fine-grained PATs. Similarly, a
fine-grained PAT restricted to `stefanf81/homelab-TF` cannot read releases from
upstream repositories on `api.github.com`, causing unauthenticated rate-limit
errors when fetching changelogs.

To support both private GHCR metadata and rich PR changelogs, configure
`RENOVATE_HOST_RULES` in the same encrypted Secret:

```json
[
  {
    "hostType": "docker",
    "matchHost": "ghcr.io",
    "username": "YOUR_BOT_ACCOUNT",
    "password": "CLASSIC_PAT_WITH_READ_PACKAGES_ONLY"
  },
  {
    "matchHost": "api.github.com",
    "token": "CLASSIC_PAT_WITH_NO_SCOPES"
  }
]
```

The fine-grained platform token remains restricted to this repository. The
classic token requires no OAuth scopes and is used only for public metadata and
release changelogs (5,000 requests/hour limit).

## PR Workflow & Grouping

- **Dependency Dashboard**: Open updates and pending upgrades are tracked in the
  Dependency Dashboard issue.
- **Major Upgrades**: All major updates require manual opt-in. They appear under
  "Pending Approval" on the Dependency Dashboard and will not open a PR until
  their checkbox is ticked.
- **Tightly Coupled Stacks**: Co-dependent components are grouped into unified PRs:
  - VictoriaMetrics Stack (`victoria-metrics-k8s-stack`, `victoriametrics/operator`, `grafana/grafana`)
  - Falco Stack (`falco`, `falcosidekick`)
  - Logging Stack (`loki`, `alloy`)
  - Proxmox CSI (`proxmox-csi-plugin`, `proxmox-csi-controller`)
  - Metrics Server (`metrics-server` chart and image)
- **General Patch Updates**: Standalone patch updates are bundled together into a
  single `patch updates` PR to reduce notification noise.
- **Concurrency**: Up to 5 PRs may remain open concurrently (`prConcurrentLimit: 5`),
  and hourly rate limiting is disabled (`prHourlyLimit: 0`) so scheduled runs
  generate updates in a single batch.
- **Custom Image Annotations**: Any manifest under `gitops/` supports inline
  annotations for Renovate:
  `# renovate: datasource=<ds> depName=<dep> tag: <tag>` or `version: <ver>`.

## Operation

The operator is namespace-scoped, policy-enforced, and has no public route.
Its executor runs without a Kubernetes API token and may egress only to DNS and
HTTPS. Completed jobs expire after 24 hours. The operator's UI is available
only through a local port-forward when needed:

```bash
kubectl -n renovate port-forward svc/renovate-operator 8081:8081
```
