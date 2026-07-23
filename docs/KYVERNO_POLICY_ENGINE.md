# Kyverno Policy Engine & Policy Reporter Dashboard (Flux GitOps)

This document describes how the Kyverno policy engine and the Policy Reporter UI are
installed and operated in this repository via Flux CD. It is the companion reference to
the short notes in `gitops/README.md`.

- **Kyverno** — Kubernetes-native policy engine (validate / mutate / generate) driven by
  `ClusterPolicy` custom resources. Acts as a mutating + validating admission webhook.
- **Policy Reporter** — a read-only web dashboard that visualises the `ClusterPolicyReport`
  / `PolicyReport` objects Kyverno produces. Exposed at `https://kyverno.jokelab.dev`.

Both are managed entirely through Git; nothing is applied imperatively.

---

## 1. Architecture in this repo (file map)

```
gitops/
├── infrastructure/controllers/
│   ├── kyverno/                     # Kyverno controller (reconciled by infra-controllers)
│   │   ├── namespace.yaml           # kyverno ns + PSA enforce:privileged
│   │   ├── repository.yaml          # HelmRepository kyverno @ https://kyverno.github.io/kyverno/
│   │   ├── release.yaml             # HelmRelease kyverno v3.8.2, single-replica, crds: Skip
│   │   └── kustomization.yaml
│   └── policy-reporter/             # Policy Reporter + UI (its OWN cluster Kustomization)
│       ├── namespace.yaml           # policy-reporter ns
│       ├── repository.yaml          # HelmRepository policy-reporter @ https://kyverno.github.io/policy-reporter
│       ├── release.yaml             # HelmRelease policy-reporter v3.8.1, ui+kyverno plugin, crds: Skip
│       ├── route.yaml               # HTTPRoute -> policy-reporter-ui:8080 on taskflow-gateway (:443)
│       └── kustomization.yaml
├── apps/
│   └── kyverno-policies/            # Example ClusterPolicies (Audit mode)
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
        └─ kyverno-policies  ──────────►  ClusterPolicy objects (CRDs now exist)
  └─ infra-configs
  └─ taskflow-app  ───────────────────►  Cilium Gateway + cert + taskflow workloads
        └─ policy-reporter  ───────────►  Policy Reporter + UI + HTTPRoute (Gateway now exists)
```

- `kyverno-policies` `dependsOn: infra-controllers` so the `ClusterPolicy` CRD exists before
  policies are applied (avoids `no matches for kind "ClusterPolicy"`).
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
- Pinned: **3.8.2** (ships Kyverno **v1.18.2**, including latest July 2026 security fixes). Requires k8s ≥ ~1.25 (cluster is 1.36.2).

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
`config.resourceFiltersExcludeNamespaces` excludes the platform from all policy enforcement:
`kube-system`, `kyverno`, `flux-system`, `cert-manager`, `cilium`. The `kyverno` namespace is
also auto-excluded by Kyverno's own namespace selector.

### Resources (minimal / single-replica, homelab)
All four controllers run 1 replica:
- `admissionController` — requests 256Mi / limits 512Mi
- `backgroundController`, `cleanupController`, `reportsController` — requests 128Mi / limits 256Mi

`features.autoUpdateWebhooks.enabled: true` lets Kyverno dynamically manage its webhook
configurations per-policy (relevant when policies switch between Audit/Enforce).

---

## 5. Policies (Audit mode)

Policies live in `gitops/apps/kyverno-policies/`, reconciled by the `kyverno-policies`
Kustomization. Both shipped examples are `validationFailureAction: Audit` — they **report**
violations but never block admission. This is deliberate for a safe bootstrap:

- `require-common-labels` — Deployments/StatefulSets must carry
  `app.kubernetes.io/name` + `app.kubernetes.io/part-of`.
- `disallow-latest-tag` — flags any container using the mutable `:latest` tag.

Because the TaskFlow images use `:latest`, `disallow-latest-tag` lights up immediately in the
Policy Reporter dashboard — a clean end-to-end proof the pipeline works.

### How to add a policy
1. Drop a `ClusterPolicy` (or namespaced `Policy`) YAML into `gitops/apps/kyverno-policies/`.
2. Add it to that folder's `kustomization.yaml` `resources:` list.
3. Commit & push. Flux applies it automatically (after `infra-controllers` is healthy).

---

## 6. Policy Reporter + UI

### Install
- Chart: `policy-reporter/policy-reporter` from `https://kyverno.github.io/policy-reporter`
- Pinned: **3.8.1**
- Values: `ui.enabled: true` (UI subchart, service `policy-reporter-ui:8080`),
  `plugin.kyverno.enabled: true` (enriches the UI with policy descriptions/YAML),
  `install.crds: Skip`.

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

### Authentication caveat
The Policy Reporter UI is exposed **without authentication**. Anyone able to reach
`kyverno.jokelab.dev` can view policy reports. For a homelab this is usually acceptable, but
to align with the project's zero-trust stance you can enable basic auth:

- Create a SOPS-encrypted secret (same pattern as `gitops/monitoring/platform/grafana-secrets.yaml`)
  holding `username` / `password`.
- Set `ui.basicAuth.secretRef` (or `basicAuth`) in the `policy-reporter` `release.yaml`.

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
kubectl -n policy-reporter get pods    # policy-reporter + policy-reporter-ui

# CRDs (Kyverno-owned)
kubectl get crds | grep kyverno

# Policies + results
kubectl get clusterpolicy              # require-common-labels, disallow-latest-tag (Ready)
kubectl get clusterpolicyreport -A     # audit findings (may take ~1 min after install)

# Route
kubectl -n policy-reporter get httproute policy-reporter-ui
```

Then open `https://kyverno.jokelab.dev` (after DNS + cert are ready).

---

## 8. Moving from Audit to Enforce

1. Edit a policy in `gitops/apps/kyverno-policies/`, change
   `validationFailureAction: Audit` → `Enforce`.
2. Commit & push. Flux reconciles; Kyverno's webhook `failurePolicy` for that rule flips to
   `Fail` automatically (via `autoUpdateWebhooks`).
3. New non-compliant admissions are now **blocked**. System namespaces remain excluded.

Do this **one policy at a time** and watch `kubectl get clusterpolicyreport -A` first to see
the blast radius. Start with low-risk policies (labels) before `:latest`/security-context.

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
| `kubectl get clusterpolicyreport -A` returns nothing | Reports are generated asynchronously by the reports controller after its background scan. Wait ~1–2 min; if still empty, `kubectl -n kyverno logs deploy/kyverno-reports-controller`. |
| Policies don't seem to evaluate `taskflow` | Confirm the policy doesn't `exclude` the `taskflow` namespace, and that `validationFailureAction` is `Audit` (reports only) not erroneously scoped. |

---

## 11. References
- Kyverno install (Helm): https://kyverno.io/docs/installation/installation/
- Kyverno chart (v3) values: https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Policy Reporter docs: https://kyverno.github.io/policy-reporter-docs/
- Policy Reporter chart: https://github.com/kyverno/policy-reporter
