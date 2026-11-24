# Renovate

Renovate runs through the Mogenius Renovate Operator in the `renovate`
namespace. The operator discovers `stefanf81/homelab-TF` daily at 03:17
Europe/Brussels, then runs a single hardened Renovate executor for that
repository. Every update is a pull request; Renovate never pushes to `main`
directly. Digest and patch PRs are merged automatically once their CI checks
pass (`automerge` in `.github/renovate.json`; Flux then rolls them out). Minor
and major updates, Gateway API bumps (which need a manual CRD bundle swap) and the
WAF rule set (OWASP CRS and the Coraza base config in the WAF image, also its
patch releases: a new false positive blocks real users; see
`docs/CORAZA_CONFIGURATION.md`, "False-positive regression test") stay manual.

Three more kinds of update are never merged unattended:

- **Images and OCI charts from registries without release timestamps** (GHCR,
  Quay, gcr.io, registry.k8s.io: every docker source except Docker Hub). Renovate
  cannot age them, so `minimumReleaseAge` would hold them forever; they are raised
  without the 3-day wait (`minimumReleaseAgeBehaviour: timestamp-optional`, scoped
  to these registries) and need a review. Their patch updates have their own group,
  "patch updates without a release timestamp". Docker Hub reports when a tag was
  pushed, so its updates keep the wait and the automerge. Every other datasource
  keeps Renovate's default (`timestamp-required`): an update without a timestamp
  waits on the Dependency Dashboard instead of skipping the wait.
- **A digest-only change of a pinned GitHub Action** (group "GitHub Actions whose
  tag was moved"). Every pin carries its full `# vX.Y.Z` comment, so this means the
  tag was moved to another commit, and Renovate ages it against the tag's original
  release date. Compare the two commits before merging.
- **A new digest under an existing tag of the own images** (`abuseipdb-sync`,
  `taskflow-caddy-coraza`). Their new revision tags are still merged unattended;
  the workflow never overwrites a tag, so a changed digest means someone replaced it.

`internalChecksFilter: "strict"` (Renovate's default, set explicitly) keeps a branch
from being created before its wait has passed. These rules sit below the automerge
rule in `.github/renovate.json`: Renovate applies `packageRules` in order and a later
match overrides an earlier one.

A k3s update PR (`k3s_version` in `variables.tf`, with the copies in
`terraform.tfvars.example` and `README.md`) is a reminder, not a rollout: it only changes
what a new node installs. Upgrade the running node first, re-pin the installer commit and
checksum in `modules/proxmox/main.tf` in the same PR, then merge. It is never automerged.

CI validates `.github/renovate.json` with `renovate-config-validator --strict`
(`.github/workflows/validate-renovate.yaml`), using the Renovate version pinned in
`gitops/platform/renovate/job/renovate-job.yaml`.

## Credentials

The SOPS-encrypted GitHub credential is at:

```bash
sops gitops/platform/renovate/job/renovate-secrets.yaml
```

Use a fine-grained PAT for the dedicated GitHub bot account, restricted to
`stefanf81/homelab-TF`, with Contents, Pull requests, Issues and Workflows
read/write. Workflows is needed because the `github-actions` manager updates
files under `.github/workflows/`; GitHub rejects such pushes without it.

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

- **Enabled Managers** (`.github/renovate.json`): `custom.regex`, `dockerfile`,
  `flux`, `github-actions`, `gomod`, `kubernetes`, `mise`, and `terraform`, with
  `minimumReleaseAge: "3 days"` (`flux2` and `kubectl` in `mise.toml` are restricted
  to patch updates so their minors stay aligned with `FluxInstance` and `k3s_version`).
- **Dependency Dashboard**: Open updates and pending upgrades are tracked in the
  Dependency Dashboard issue.
- **Major Upgrades**: All major updates require manual opt-in. They appear under
  "Pending Approval" on the Dependency Dashboard and will not open a PR until
  their checkbox is ticked.
- **Tightly Coupled Stacks**: Co-dependent components are grouped into unified PRs:
  - VictoriaMetrics Stack (`victoria-metrics-k8s-stack`, `victoriametrics/operator`, `grafana/grafana`)
  - Falco Stack (`falco`, `ghcr.io/falcosecurity/charts/falco`, `falcosecurity/falcosidekick`)
  - Logging Stack (`loki`, `alloy`)
  - Proxmox CSI (`proxmox-csi-plugin`, `ghcr.io/sergelogvinov/charts/proxmox-csi-plugin`, `ghcr.io/sergelogvinov/proxmox-csi-controller`)
  - Metrics Server (`metrics-server` chart and image)
- **General Patch Updates**: Standalone patch updates are bundled together into a
  single `patch updates` PR to reduce notification noise.
- **Concurrency**: Up to 10 PRs may remain open concurrently (`prConcurrentLimit: 10`),
  and hourly rate limiting is disabled (`prHourlyLimit: 0`) so scheduled runs
  generate updates in a single batch.
- **Custom Image & Bundle Annotations**: Any manifest under `gitops/` supports
  two-line inline annotations for Renovate:
  ```yaml
  # renovate: datasource=<ds> depName=<dep> [versioning=<ver>]
  tag: <tag> # (or `version: <ver>` / `# bundle-version: <ver>`)
  ```
  Dockerfiles under `gitops/images/` take the same comment on the line above an
  `ARG NAME=<version>` (used for the Coraza plugin in the WAF image). Renovate
  bumps the image's `IMAGE_REVISION` in the same PR, as the build workflows
  require. Workflows under `.github/workflows/` take it on the line above an
  `env` pin (e.g. `TRIVY_VERSION`).

## Operation

The operator is namespace-scoped, policy-enforced, and has no public route.
Its executor runs without a Kubernetes API token and may egress only to DNS and
HTTPS. Completed jobs expire after 24 hours. The operator's UI is available
only through a local port-forward when needed:

```bash
kubectl -n renovate port-forward svc/renovate-operator 8081:8081
```
