# Kyverno Policy Engine & Policy Reporter Dashboard (Flux GitOps)

This document describes how the Kyverno policy engine and the Policy Reporter UI are
installed and operated in this repository via Flux CD. It is the companion reference to
the short notes in `gitops/README.md`.

- **Kyverno** — Kubernetes-native policy engine (validate / mutate / generate) driven by
  CEL `ValidatingPolicy` custom resources (`policies.kyverno.io/v1`). Acts as a mutating +
  validating admission webhook. The legacy `ClusterPolicy` type was deprecated in Kyverno 1.19
  and is removed in 1.20; this repo migrated on 2026-10-22.
- **Policy Reporter** — a read-only web dashboard that visualises the `ClusterPolicyReport`
  / `PolicyReport` objects produced by **Kyverno**, **Trivy** (via the
  `trivy-operator-polr-adapter`), and **Falco**. Exposed at `https://kyverno.jokelab.dev`
  (protected by GitHub OAuth).

Both are managed entirely through Git; nothing is applied imperatively.

Kyverno's own controller metrics (policy results, blocked admissions, admission
requests and latency, controller health and resources) are on the Grafana dashboard
**Kyverno** (`/d/kyverno`, Security folder,
`gitops/monitoring/app/dashboards/kyverno.json`). Per-resource violations stay in
Policy Reporter.

How to read it: result and admission counters are created at their first event
and every Kyverno restart starts new series, so the dashboard counts series born
inside the range with `increase_pure()` and series that already existed with
`increase()` (a plain `increase()` drops a first scrape of 10 or more, a plain
`increase_pure()` would count a whole lifetime after a scrape gap). Admission
results include server-side dry runs, so Flux's drift check re-counts a failing
object on every reconcile. CEL policies report under
`kyverno_validating_policy_results_total` (no rule names) and Kyverno 1.19 exports
no info, readiness or change metric for them, so *Active policies* counts the
policies seen by the hourly background scan. Both policies are `Deny`, which
Kyverno evaluates synchronously, so admission latency includes rule cost.
Kyverno's histograms start at a 5 ms bucket, so
quantiles below 5 ms are interpolated; finer buckets need
`metricsConfig.bucketBoundaries` in the Kyverno HelmRelease and a restart of all
controllers at once.

---

## 1. Architecture in this repo (file map)

```
gitops/
├── infrastructure/controllers/
│   ├── kyverno/                     # Kyverno controller (reconciled by infra-controllers)
│   │   ├── namespace.yaml           # kyverno ns + PSA enforce:privileged
│   │   ├── repository.yaml          # HelmRepository kyverno @ https://kyverno.github.io/kyverno/
│   │   ├── release.yaml             # HelmRelease kyverno v3.9.2, single-replica, crds: Skip
│   │   └── kustomization.yaml
│   └── policy-reporter/             # Policy Reporter + UI (its OWN cluster Kustomization)
│       ├── namespace.yaml                # policy-reporter ns
│       ├── repository.yaml               # HelmRepository policy-reporter @ https://kyverno.github.io/policy-reporter
│       ├── trivy-adapter-repository.yaml # HelmRepository trivy-operator-polr-adapter @ https://fjogeleit.github.io/trivy-operator-polr-adapter
│       ├── policy-reporter-secrets.yaml  # (legacy) SOPS OAuth secret, unused after the oauth2-proxy migration
│       ├── policy-reporter-ui-oauth-secrets.yaml # SOPS OAuth credentials for oauth2-proxy (client-id/client-secret/cookie-secret)
│       ├── oauth2-proxy-repository.yaml  # HelmRepository oauth2-proxy
│       ├── oauth2-proxy-release.yaml     # HelmRelease oauth2-proxy (github_users allow-list)
│       ├── oauth2-proxy-network-policy.yaml # Gateway -> oauth2-proxy ingress only
│       ├── release.yaml                  # HelmRelease policy-reporter v3.11.1, ui + plugins, ui.oauth disabled, metrics on, crds: Skip
│       ├── trivy-adapter-release.yaml    # HelmRelease trivy-operator-polr-adapter v0.11.5 (Trivy CRDs -> PolicyReports)
│       ├── route.yaml                    # HTTPRoute -> policy-reporter-ui-oauth2-proxy:80 on taskflow-gateway (:443)
│       └── kustomization.yaml
├── apps/
│   └── kyverno-policies/            # CEL ValidatingPolicies (Deny, fail-open)
│       ├── kustomization.yaml
│       ├── require-common-labels.yaml
│       └── disallow-latest-tag.yaml
└── clusters/taskflow/
    ├── infra-controllers.yaml       # reconciles infrastructure/controllers (incl. kyverno)
    ├── kyverno-policies.yaml        # reconciles apps/kyverno-policies (dependsOn infra-controllers)
    └── policy-reporter.yaml         # reconciles infrastructure/controllers/policy-reporter
                                     #   (dependsOn infra-controllers + taskflow-app)
```

> **Note on placement:** `policy-reporter/` lives physically under `infrastructure/controllers/`
> but is intentionally **not** listed in `infrastructure/controllers/kustomization.yaml`. It is
> reconciled by its own `policy-reporter` Kustomization so it can `dependsOn: taskflow-app`
> (the Gateway owner) — see §3.

---

## 2. Reconciliation order

```
GitRepository (flux-system)
  └─ infra-controllers  ──────────────►  kyverno HelmRelease  (+ Kyverno CRDs)
        └─ kyverno-policies  ──────────►  ValidatingPolicy objects (CRDs now exist)
  └─ infra-configs
  └─ taskflow-app  ───────────────────►  Cilium Gateway + cert + taskflow workloads
        └─ policy-reporter  ───────────►  Policy Reporter + UI + HTTPRoute (Gateway now exists)
```

- `kyverno-policies` `dependsOn: infra-controllers` so the `ValidatingPolicy` CRD exists before
  policies are applied (avoids `no matches for kind "ValidatingPolicy"`).
- `policy-reporter` `dependsOn: [infra-controllers, taskflow-app]` so Kyverno's PolicyReport
  CRDs and the Gateway both exist before the dashboard + route are reconciled.

---

## 3. Why Policy Reporter gets its own Kustomization

`infra-controllers` uses `wait: true`. If the `policy-reporter` HTTPRoute were nested inside
it, Flux would wait for that route to become **Programmed** — but the Gateway is created later
by `taskflow-app`. The route would never program during that sync, `wait` would time out, and
`infra-controllers` (and therefore `kyverno`, the apps, etc.) could stall.

Giving Policy Reporter its own Kustomization that `dependsOn: taskflow-app` guarantees the
Gateway exists first, so the route programs immediately and `wait` succeeds.

---

## 4. Kyverno controller details

### Chart & version
- Chart: `kyverno/kyverno` from `https://kyverno.github.io/kyverno/`
- Pinned: **3.9.2** (ships Kyverno **v1.19.2**). Requires k8s ≥ ~1.25 (the
  provisioned cluster is configured for k3s `v1.36.4+k3s1`).

### CRD handling — important gotcha
Chart **v3** ships its CRDs as **templated resources** controlled by the `crds.install: true`
value (the default). They are owned by the Helm release.

Do **NOT** set `install.crds: CreateReplace` on the Flux `HelmRelease` (as many older blog
posts suggest). That tells Flux to also install CRDs from the chart's `crds/` directory, which
conflicts with the Kyverno-owned templated CRDs and fails with:

```
... cannot be imported into the current release: invalid ownership metadata;
annotation validation error: key "meta.helm.sh/release-name" must equal "kyverno"
```

Correct config (what is deployed):
```yaml
spec:
  install:
    createNamespace: true
    crds: Skip          # Kyverno owns its CRDs via crds.install: true (values)
  upgrade:
    crds: Skip
  values:
    crds:
      install: true     # Kyverno-managed, properly owned by the release
```

### Namespace exclusions
Two layers keep the platform out of policy evaluation:

- **Global resource filters.** The chart's default `resourceFilters` already skip `kube-system`,
  `kube-public`, `kube-node-lease` and `kyverno`; `config.resourceFiltersIncludeNamespaces` adds
  `flux-system` and `cert-manager`. (Do not use `resourceFiltersExcludeNamespaces`: despite the
  name it *removes* a namespace from the default filters.)
- **Per policy.** Each `ValidatingPolicy` also states its scope in
  `matchConstraints.namespaceSelector`, so the policy file alone shows where it applies.
  Cilium runs in `kube-system`; there is no `cilium` namespace.

### Resources (minimal / single-replica, homelab)
All four controllers run 1 replica:
- `admissionController` — requests 256Mi / limits 512Mi
- `backgroundController`, `cleanupController`, `reportsController` — requests 128Mi / limits 256Mi

`features.autoUpdateWebhooks.enabled: true` lets Kyverno manage its webhook configurations per
policy; each `ValidatingPolicy` gets a webhook with the policy's own `failurePolicy`.

---

## 5. Policies (enforced)

Policies live in `gitops/apps/kyverno-policies/`, reconciled by the `kyverno-policies`
Kustomization. Both are CEL `ValidatingPolicy` objects with `validationActions: [Deny]`,
`failurePolicy: Ignore` and background scanning on:

| Policy | Scope | Rule |
|---|---|---|
| `disallow-latest-tag` | Pods in every namespace except `kube-system`, `kyverno`, `flux-system`, `cert-manager`; autogen for Deployments, StatefulSets, DaemonSets, Jobs, CronJobs | Every container and init container uses an `@sha256` digest or an explicit tag other than `latest`. Untagged images are rejected; `:latest@sha256:…` is allowed because the digest is immutable; a registry port (`host:5000/app`) is not mistaken for a tag. |
| `require-common-labels` | Deployments and StatefulSets in `taskflow` | `app.kubernetes.io/name` and `app.kubernetes.io/part-of` are set. |

Design choices:

- **Fail open.** Kyverno runs one admission replica and there is no alerting, so with
  `failurePolicy: Fail` a crash-looping Kyverno would block every new Pod in scope. These are
  hygiene rules, not a security boundary: while Kyverno is down Pods are admitted unchecked, and
  the hourly background scan reports anything that slipped through. Pod security belongs in Pod
  Security Admission namespace labels, which have no webhook to fail.
- **Autogen without ReplicaSets.** Validating the controllers makes a bad manifest fail at Flux
  apply time instead of producing a ReplicaSet that cannot create Pods. ReplicaSets are left out
  because the Deployment controller updates old revision-history ReplicaSets, which must not be
  blocked.

### How to add a policy
1. Write a `ValidatingPolicy` (`policies.kyverno.io/v1`) in `gitops/apps/kyverno-policies/`,
   starting with `validationActions: [Audit]`, and add it to that folder's `kustomization.yaml`.
2. Check it compiles: `kubectl apply --dry-run=server -k gitops/apps/kyverno-policies`
   (Kyverno's policy webhook rejects invalid CEL).
3. Commit & push, wait for the first background scan (up to 1 h), then check the reports
   (§7) before switching to `Deny` (§8).

Exceptions use `policies.kyverno.io/v1` `PolicyException` objects in the `kyverno` namespace
(`features.policyExceptions.namespace`), referencing the policy in `spec.policyRefs` and selecting
resources with CEL `matchConditions`.

---

## 6. Policy Reporter + UI

### Install
- Chart: `policy-reporter/policy-reporter` from `https://kyverno.github.io/policy-reporter`
- Pinned: **3.11.1** (ships Policy Reporter + UI app **3.11.1**)
- Values: `ui.enabled: true` (UI subchart, service `policy-reporter-ui:8080`),
  `plugin.kyverno.enabled: true` + `plugin.trivy.enabled: true` (enrich the UI with
  policy descriptions/YAML and Trivy vulnerability details), `ui.oauth` (GitHub OAuth,
  see below), `ui.sources` (six Trivy sources, see below), `install.crds: Skip`.

### Trivy Plugin & Adapter
Two components surface Trivy results in the UI:

1. **`plugin.trivy.enabled: true`** — the Policy Reporter **Trivy plugin** watches the
   `aquasecurity.github.io` report CRDs Trivy Operator produces (`VulnerabilityReport`,
   `ConfigAuditReport`, `RbacAssessmentReport`, `ExposedSecretReport`, ...). Policy Reporter
   then emits its WAF-like `policy` metrics (`policy_report_info`, `policy_report_result`,
   ...) so findings also appear in the main Policy Reporter metrics.
2. **`trivy-operator-polr-adapter`** (HelmRelease `trivy-operator-polr-adapter` v0.11.5,
   chart from `https://fjogeleit.github.io/trivy-operator-polr-adapter`) — converts the
   Trivy CRDs into vanilla `wgpolicyk8s.io/v1alpha2` `PolicyReport` /
   `ClusterPolicyReport` objects, so they are visible directly in the UI's **report
   list**. All adapters are enabled (vulnerability, config-audit, RBAC, exposed-secret,
   compliance, infra-assessment, cluster variants).
   
> **Why both?** The UI report list reads `wgpolicyk8s.io` reports. Trivy does **not**
> write those natively — hence the adapter. Without the adapter the report list stays
> Kyverno/Falco-only; without the plugin the `policy` Prometheus metrics stay
> Kyverno-only. See `docs/TRIVY_SECURITY_SCANNING.md` §6 for what each Trivy report type
> maps to.

> **Compliance detail caveat:** the adapter's compliance adapter requires the Trivy
> operator to emit **detailed** compliance reports. The HelmRelease is configured with
> `compliance.reportType: all` (detailed) — if that is switched back to `summary`, no
> `ClusterComplianceReport`-derived PolicyReports will be created (the summary reports do
> not carry per-check results).

Policy Reporter reads the `wgpolicyk8s.io` `PolicyReport` / `ClusterPolicyReport` CRDs that
**Kyverno already installs** (`crds.groups.wgpolicyk8s` is enabled by default in the Kyverno
chart). It installs no CRDs of its own, so `install.crds: Skip` is correct.

### Exposure via Cilium Gateway
The UI is published through the **shared** `taskflow-gateway` (Cilium, `cilium` gatewayClass)
exactly like Grafana:

```yaml
# gitops/infrastructure/controllers/policy-reporter/route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: policy-reporter-ui
  namespace: policy-reporter
spec:
  parentRefs:
    - name: taskflow-gateway
      namespace: taskflow
      sectionName: https          # :443 only; plaintext :80 is redirected by http-to-https-redirect
  hostnames:
    - "kyverno.jokelab.dev"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: policy-reporter-ui
          port: 8080
```

The Gateway's `allowedRoutes` selector (`gitops/apps/taskflow/gateway.yaml`) was extended to
include the `policy-reporter` namespace on **both** the `http` and `https` listeners — without
this the route is never programmed.

TLS is terminated by the Gateway using `taskflow-tls-secret`, which is issued from the
`letsencrypt-http01-production` ClusterIssuer.

### DNS & certificate
The UI is served with TLS using the **shared** `taskflow-jokelab-cert`
(`gitops/apps/taskflow/certificate.yaml`), which must carry the `kyverno.jokelab.dev` SAN
alongside `jokelab.dev`, `www.jokelab.dev`, `grafana.jokelab.dev`.

> **Ordering is critical.** A DNS A/CNAME record for `kyverno.jokelab.dev` → Gateway IP
> (`192.168.50.201`, same as `grafana.jokelab.dev`) **must exist before** the SAN is added.
> cert-manager solves the Let's Encrypt HTTP-01 challenge by reaching
> `http://kyverno.jokelab.dev/.well-known/acme-challenge/...` through the Gateway, which
> requires the hostname to resolve. If the SAN is added while the DNS record is missing, the
> cert stays `InProgress`, and because `taskflow-app` health-checks that Certificate
> (`wait: true`), the **main app Kustomization goes `Progressing`/`NotReady`** — which also
> blocks `policy-reporter` (`dependsOn: taskflow-app`). Create the DNS record first, then add
> the SAN; re-issuance validates and `taskflow-app` returns to Ready.
>
> **Hairpin NAT caveat.** Even when the DNS record exists and resolves to the Gateway's
> external IP, cert-manager's self-check may **time out** behind a router that doesn't
> support hairpin NAT (or has it disabled). The cert-manager pod resolves the domain to the
> **public** IP, sends the GET request, the packet leaves the LAN, and the router can't
> forward it back to the internal Gateway — so the challenge hangs `pending` with:
> ```
> Waiting for HTTP-01 challenge propagation: failed to perform self check GET request
> 'http://kyverno.jokelab.dev/.well-known/acme-challenge/...':
> context deadline exceeded (Client.Timeout exceeded while awaiting headers)
> ```
> **Fix a — CoreDNS override (permanent, recommended):** Override cluster-internal DNS to
> resolve the domain directly to the Gateway's internal IP by patching CoreDNS:
> ```bash
> kubectl -n kube-system patch configmap coredns --type merge -p '{"data":{"Corefile":".:53 {\n    errors\n    health\n    hosts {\n        192.168.50.201 kyverno.jokelab.dev\n        fallthrough\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n        pods insecure\n        fallthrough in-addr.arpa ip6.arpa\n    }\n    prometheus :9153\n    forward . /etc/resolv.conf\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"}}'
> kubectl -n kube-system rollout restart deploy/coredns
> ```
> After ~10s cert-manager retries the challenge, resolves to `192.168.50.201` over LAN, and
> the challenge completes. Reverts cleanly by removing the `hosts` block from the Corefile.
>
> **Fix b — DNS-01 challenge (alternative):** Switch the ClusterIssuer to use DNS-01 with a
> Cloudflare API token. This avoids HTTP-01 entirely and works through any NAT setup, but
> requires creating a SOPS-encrypted API token secret and modifying the ClusterIssuer.
>
> If the order is already `invalid`, cert-manager will not create a new CertificateRequest
> on its own — the controller sits on a retry backoff. To force a fresh attempt:
> ```bash
> # Nuclear option — delete the Certificate and let Flux recreate it
> kubectl -n taskflow delete certificate taskflow-jokelab-cert
> flux -n flux-system reconcile ks taskflow-app
> ```
> This resets all issuance state to zero; Flux re-applies the Certificate from Git and a new
> order is created immediately. See §10 Troubleshooting.

### Authentication (GitHub OAuth via oauth2-proxy)
The Policy Reporter UI's built-in GitHub OAuth has **no user/org allow-list**, so
`ui.oauth.enabled` is disabled and the UI is fronted by an oauth2-proxy
(`gitops/infrastructure/controllers/policy-reporter/oauth2-proxy-release.yaml`):

- `provider = "github"` with `redirect_url = https://kyverno.jokelab.dev/oauth2/callback`
- Login is restricted with `github_users = ["stefanf81"]`; with no org/repo
  configured, every other GitHub account is rejected by oauth2-proxy.
- Credentials (`client-id` / `client-secret` / `cookie-secret`) live in the
  SOPS-encrypted `policy-reporter-ui-github-oauth` Secret
  (`policy-reporter-ui-oauth-secrets.yaml`). Create a GitHub OAuth App with the
  callback above, replace the `PLACEHOLDER_*` values, and re-encrypt:
  `sops -e -i gitops/infrastructure/controllers/policy-reporter/policy-reporter-ui-oauth-secrets.yaml`.
  Until then login fails closed.
- The old `policy-reporter-github-oauth` secret is unused after the migration.
- The HTTPRoute targets the oauth2-proxy (`policy-reporter-ui-oauth2-proxy:80`),
  not the UI Service.

---

## 7. Verification

```bash
# Kustomizations
flux get kustomizations | grep -E 'infra-controllers|kyverno'

# Helm releases
flux get hr -n kyverno
flux get hr -n policy-reporter

# Pods
kubectl -n kyverno get pods            # 4 controllers, 1/1
kubectl -n policy-reporter get pods    # policy-reporter, policy-reporter-ui, policy-reporter-trivy-plugin, trivy-operator-polr-adapter

# CRDs (Kyverno-owned)
kubectl get crds | grep kyverno

# Policies + results
kubectl get validatingpolicies         # require-common-labels, disallow-latest-tag (READY true)
kubectl get policyreports -A -o json | jq -r '.items[].results[]? | select(.source=="KyvernoValidatingPolicy") | "\(.policy) \(.result)"' | sort | uniq -c

# Route
kubectl -n policy-reporter get httproute policy-reporter-ui
```

Then open `https://kyverno.jokelab.dev` (after DNS + cert are ready).

---

## 8. Moving from Audit to Deny

1. Confirm the policy's background-scan results are all `pass` (§7); any `fail` is a resource
   that would be blocked on its next create or update.
2. Change `validationActions: [Audit]` → `[Deny]`, commit and push. Kyverno updates the policy's
   webhook (the `failurePolicy` stays whatever the policy sets).
3. Prove it with server-side dry runs, which persist nothing, for example:

   ```bash
   kubectl -n taskflow run kv-test --image=busybox --dry-run=server   # denied: untagged
   kubectl -n taskflow run kv-test --image=nginx:1.29.3 --dry-run=server   # allowed
   ```

4. Watch *Blocked admissions* on the Grafana Kyverno dashboard; Flux server-side dry runs that
   hit a Deny policy show up there and in the failing Kustomization's status.

**Back out:** set the policy back to `[Audit]` and push; nothing else needs undoing.

---

## 9. Rollback

- **Remove a policy:** delete its file + kustomization entry, commit. Flux prunes it.
- **Remove Policy Reporter:** delete `policy-reporter.yaml` from the cluster kustomization list
  and `gitops/infrastructure/controllers/policy-reporter/`, commit. Flux prunes the release
  (and its owned resources). Optionally remove `kyverno.jokelab.dev` from the cert SAN and the
  `policy-reporter` entry from the Gateway `allowedRoutes`.
- **Remove Kyverno:** remove `kyverno` from `infrastructure/controllers/kustomization.yaml` and
  delete `gitops/apps/kyverno-policies/`, commit. Flux uninstalls the release (Kyverno-owned
  CRDs are removed with it).

---

## 10. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Helm install failed … invalid ownership metadata` on Kyverno | `install.crds: CreateReplace` set on the HelmRelease. Change to `Skip` (§4). |
| `policy-reporter-ui` HTTPRoute shows `Not Programmed` / no address | The `policy-reporter` namespace is missing from the Gateway `allowedRoutes` selector, or the Gateway (`taskflow-app`) hasn't reconciled yet. |
| Certificate `taskflow-jokelab-cert` stays `InProgress` after adding a new SAN | **Two common causes:** (1) DNS record for the new SAN doesn't exist yet — create it first (§6). (2) DNS exists but cert-manager self-check times out (hairpin NAT) — see next row. |
| HTTP-01 self-check times out with `context deadline exceeded` | Hairpin NAT: the router can't forward outbound traffic back to the internal Gateway. **Fix:** add a `hosts` entry in CoreDNS to resolve the domain to the internal Gateway IP (`192.168.50.201`) — see §6 for the exact patch. Alternative: switch to DNS-01 with Cloudflare API token. |
| cert-manager does **not** create a new CertificateRequest after a failed order | The Issuing controller sits on a retry backoff. Deleting the failed CR does **not** reset the timer. **Fix:** delete the Certificate and let Flux recreate it — `kubectl delete certificate -n taskflow taskflow-jokelab-cert && flux -n flux-system reconcile ks taskflow-app`. This resets all issuance state to zero. |
| No `KyvernoValidatingPolicy` results in `kubectl get policyreports -A` | Reports are generated asynchronously by the reports controller after its background scan (on policy change, then hourly). Wait ~1–2 min; if still empty, check `spec.evaluation.background.enabled` and `kubectl -n kyverno logs deploy/kyverno-reports-controller`. |
| A policy doesn't seem to evaluate a namespace | Check its `matchConstraints.namespaceSelector` and the global resource filters (§4); `kubectl get validatingpolicy <name> -o yaml` shows `WebhookConfigured` and `RBACPermissionsGranted` in `status`. |
| A Flux Kustomization fails with `admission webhook "vpol.validate.kyverno.svc-…" denied the request` | A manifest breaks a Deny policy; the message names the containers or labels. Fix the manifest, or add a `PolicyException` (§5) if the exception is intended. |

---

## 11. References
- Kyverno install (Helm): https://kyverno.io/docs/installation/installation/
- Kyverno chart (v3) values: https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Policy Reporter docs: https://kyverno.github.io/policy-reporter-docs/
- Policy Reporter chart: https://github.com/kyverno/policy-reporter
