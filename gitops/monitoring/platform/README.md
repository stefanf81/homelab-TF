# Monitoring deployment safety

The stack evaluates the bundled VMRule recording rules every minute through
VMAlert and writes their results to VMSingle. This supplies the precomputed
CPU/memory/workload series used by the bundled Kubernetes dashboards. Allow a
few evaluation cycles after deployment for dependent rules and rate windows.

**Notifications are still disabled:** Alertmanager is off and VMAlert uses
`notifier.blackhole=true`. Enabling rule evaluation is not an alerting rollout;
external alert delivery remains a separate task.

## Persistent vmagent queue

`vmagent.spec.statefulMode` gives each vmagent pod a persistent 2Gi Proxmox CSI
volume. The remote-write queue is capped at 1Gi per destination, leaving space
for filesystem overhead. Once full, the queue can discard its oldest data; this
is finite outage buffering, not a backup.

The first deployment changes vmagent from a Deployment to an operator-managed
StatefulSet. Apply while VMSingle is healthy and the existing remote-write queue
is drained: the old `emptyDir` backlog cannot be migrated into the new PVC.
Let the operator manage the transition; do not delete pods/PVCs manually. Verify
one active collector and a Bound queue PVC after reconciliation.

## Single-writer updates and browser security

The stack and Alloy explicitly use client-side apply for Helm upgrades. Its
strategic merge removes server-defaulted `rollingUpdate` fields when switching
to `Recreate`; server-side apply failed this migration even with an explicit null.
Fresh chart rendering alone does not test upgrades of existing Deployments.

vmagent has a 512Mi process limit and a 128MiB internal cache/queue budget. The
previous 256Mi limit OOMKilled it during persistent-queue startup and failed-write
retries. Monitor actual RSS after recovery; internal budgets are not total RSS caps.

Alloy uses `Recreate` because its one PVC contains WAL and file positions. Grafana
also uses `Recreate` for its SQLite PVC. `ReadWriteOnce` restricts nodes, not the
number of writers on one node. These updates intentionally trade a short outage
for exclusive storage access; Alloy configuration-only changes still hot-reload.

Grafana's cookies are Secure with SameSite=Lax, preserving GitHub OAuth redirects.
Existing dashboard public-sharing settings are unchanged and remain managed in
Grafana independently of the GitHub login restriction.

## Disk and log safety

Alloy's 30-minute WAL expiry is an age limit, not a byte-size limit. At roughly
0.57 MiB/s the 1Gi `alloy-data` PVC can fill before expiry, especially while Loki
is unavailable. Monitor PVC usage on Logging pipeline and size storage for peak
traffic/outages. Loki's filesystem retention similarly is not a free-space guard.

The audit pipeline redacts credential header **values** (including Set-Cookie)
and selected query-parameter values, rejects malformed audit JSON, and normalises
method labels to the usual methods plus OTHER. It cannot sanitise records already
stored in Loki or raw Kubernetes stdout; assess old credential-bearing evidence
and rotate affected credentials if necessary. No historical logs are deleted by
these changes.

## Validation

`gitops/images/taskflow-caddy-coraza/tests/validate-configs.sh` requires Docker,
Helm, Ruby, Python 3 and kubectl. It renders the pinned charts without applying
anything, tests MetricsQL in a disposable TSDB, and runs synthetic audit secrets
through real Alloy/Loki containers. Assertions cover JSON validity, redaction,
evidence preservation and method-label cardinality. No production secrets or
production telemetry are used by the fixture tests.
