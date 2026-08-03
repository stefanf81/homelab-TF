# Hubble UI + CLI Setup

Public Hubble network observability at `https://hubble.jokelab.dev` with GitHub OAuth authentication, plus local `cilium`/`hubble` CLI for flow inspection.

## Architecture

```
Browser → Cloudflare → Cilium Gateway (TLS) → oauth2-proxy (GitHub OAuth) → Hubble UI (kube-system)
                                                                                   ↑
Local CLI → kubectl port-forward → Hubble Relay (kube-system) ──────────────────────┘
```

### Components

| Component | Namespace | Service | Port | Purpose |
|-----------|-----------|---------|------|---------|
| Hubble UI | `kube-system` | `hubble-ui` | 80 | Web interface for network flow visualization |
| Hubble Relay | `kube-system` | `hubble-relay` | 80 → 4245 | gRPC relay for CLI access |
| oauth2-proxy | `hubble-ui` | `hubble-ui-oauth2-proxy` | 4180 | GitHub OAuth authentication proxy |
| Cilium Agent | `kube-system` | — | — | eBPF dataplane + Hubble exporter |

### Traffic Flow (Public)

1. Browser requests `https://hubble.jokelab.dev`
2. Cloudflare proxies to cluster IP `192.168.50.201`
3. Cilium Gateway terminates TLS (certificate: `taskflow-tls-secret`)
4. HTTPRoute `hubble-ui` routes `/` → `hubble-ui-oauth2-proxy:4180`
5. oauth2-proxy checks GitHub session cookie
6. If no session: redirects to GitHub OAuth → callback at `https://hubble.jokelab.dev/callback`
7. If authenticated: forwards request to `hubble-ui.kube-system.svc.cluster.local:80`
8. Hubble UI displays live network flows from eBPF

### Traffic Flow (CLI)

```bash
kubectl port-forward -n kube-system svc/hubble-relay 4244:80
# hubble observe → 127.0.0.1:4244 → hubble-relay:80 → Cilium Agent
```

## Resources Created

### Infrastructure

| File | Resource |
|------|----------|
| `gitops/infrastructure/controllers/cilium/release.yaml` | Updated: enabled `hubble`, `hubble.relay`, `hubble.ui`, `hubble.metrics` |
| `gitops/infrastructure/controllers/coredns/release.yaml` | Updated: added `hubble.jokelab.dev` to hosts |

### Hubble UI (`gitops/infrastructure/controllers/hubble-ui/`)

| File | Resource |
|------|----------|
| `namespace.yaml` | `hubble-ui` namespace |
| `repository.yaml` | HelmRepository `oauth2-proxy` (`https://oauth2-proxy.github.io/manifests`) |
| `release.yaml` | HelmRelease `hubble-ui-oauth2-proxy` (oauth2-proxy chart 10.7.0) |
| `route.yaml` | HTTPRoute `hubble-ui` → `hubble-ui-oauth2-proxy:4180` |
| `hubble-ui-secrets.yaml` | SOPS-encrypted Secret (GitHub OAuth credentials) |
| `network-policy.yaml` | CiliumNetworkPolicy `allow-gateway-to-hubble-ui` |
| `kustomization.yaml` | Kustomization listing all resources |

### App Layer Updates

| File | Change |
|------|--------|
| `gitops/apps/taskflow/certificate.yaml` | Added `hubble.jokelab.dev` SAN |
| `gitops/apps/taskflow/gateway.yaml` | Added `hubble-ui` namespace to both HTTP/HTTPS listener `allowedRoutes` |
| `gitops/apps/taskflow/http-redirect.yaml` | Added `hubble.jokelab.dev` to HTTP→HTTPS redirect |
| `gitops/apps/taskflow/cloudflare-ddns.yaml` | Added `hubble.jokelab.dev` to DNS domains |
| `gitops/clusters/taskflow/hubble-ui.yaml` | Flux Kustomization for hubble-ui |
| `gitops/clusters/taskflow/kustomization.yaml` | Added `hubble-ui.yaml` |

### Documentation

| File | Content |
|------|---------|
| `docs/TASKFLOW_WAF_ARCHITECTURE.md` | Full WAF + logging architecture |
| `docs/HUBBLE_SETUP.md` | This file |
| `docs/TASKFLOW_WAF_RUNBOOK.md` | Operational runbook with troubleshooting |

## GitHub OAuth App

- **Application name**: `Hubble UI`
- **Homepage URL**: `https://hubble.jokelab.dev`
- **Callback URL**: `https://hubble.jokelab.dev/oauth2/callback`
- **Client ID and client secret**: stored in the SOPS-encrypted `hubble-ui-github-oauth` Secret

### Authentication Comparison

Kyverno Policy Reporter and Hubble UI both use GitHub OAuth Apps, but their OAuth
servers differ. Policy Reporter implements OAuth itself and uses `/callback`.
Hubble UI is protected by oauth2-proxy, which owns the `/oauth2/callback` endpoint.
Each needs its own GitHub OAuth App and exact callback URL.

The oauth2-proxy Helm chart reads credentials from `config.existingSecret`. The
Secret must use its required keys: `client-id`, `client-secret`, and `cookie-secret`.
The Flux `hubble-ui` Kustomization decrypts this Secret with the `sops-age` key
before applying it. Supplying values through the chart's `env` field is ineffective:
the chart-generated credential environment variables take precedence.

## Local CLI Setup

### Installation

```bash
# cilium CLI (v0.19.7)
curl -s -L https://github.com/cilium/cilium-cli/releases/latest/download/cilium-darwin-amd64.tar.gz | tar xz -C ~/bin cilium

# hubble CLI (v1.19.4)
curl -s -L https://github.com/cilium/hubble/releases/latest/download/hubble-darwin-amd64.tar.gz | tar xz -C ~/bin hubble
chmod +x ~/bin/cilium ~/bin/hubble
```

### Usage

```bash
# Start port-forward (run in background)
nohup kubectl port-forward -n kube-system svc/hubble-relay 4244:80 &

# Check connectivity
~/bin/hubble status --server 127.0.0.1:4244

# Observe all flows
~/bin/hubble observe --server 127.0.0.1:4244

# Filter by namespace
~/bin/hubble observe --server 127.0.0.1:4244 -n taskflow

# Filter by verdict (dropped traffic)
~/bin/hubble observe --server 127.0.0.1:4244 --verdict DROPPED

# Filter by pod
~/bin/hubble observe --server 127.0.0.1:4244 -l app=taskflow-frontend-waf

# Filter by DNS
~/bin/hubble observe --server 127.0.0.1:4244 --dns

# Cilium status
~/bin/cilium status

# Cilium connectivity test
~/bin/cilium connectivity test
```

## Cilium Hubble Configuration

Added to `gitops/infrastructure/controllers/cilium/release.yaml`:

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - icmp
      - http
```

## Network Policy

`allow-gateway-to-hubble-ui` allows only the Cilium Gateway (identified by `reserved:ingress` label) to reach the oauth2-proxy on port 4180:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-to-hubble-ui
  namespace: hubble-ui
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: oauth2-proxy
  ingress:
    - fromEndpoints:
        - matchExpressions:
            - key: reserved:ingress
              operator: Exists
      toPorts:
        - ports:
            - port: "4180"
              protocol: TCP
```

## Reconcile Commands

```bash
# Reconcile Cilium (enables Hubble)
flux reconcile helmrelease cilium -n kube-system --force

# Reconcile and decrypt the hubble-ui stack
flux reconcile kustomization hubble-ui -n flux-system --with-source

# Force reconcile oauth2-proxy
flux reconcile helmrelease hubble-ui-oauth2-proxy -n hubble-ui --force

# Check all resources
kubectl get pods -n hubble-ui
kubectl get pods -n kube-system -l k8s-app=hubble-ui
kubectl get svc -n kube-system | grep hubble
kubectl get httproute hubble-ui -n hubble-ui
```

## Troubleshooting

### oauth2-proxy CrashLoopBackOff

**Cause**: Missing `email_domains` or `authenticated-emails-file` in oauth2-proxy config.

**Fix**: Ensure the `configFile` includes `email_domains = ["*"]`:
```yaml
configFile: |-
  provider = "github"
  email_domains = ["*"]
  ...
```

### GitHub returns 404 from `/login/oauth/authorize`

**Cause**: oauth2-proxy is sending an unrecognized client ID. The common cause is
letting the Helm chart generate its own placeholder Secret instead of configuring
`config.existingSecret`.

**Fix**:
1. Confirm the GitHub OAuth App callback is exactly `https://hubble.jokelab.dev/oauth2/callback`.
2. Confirm the deployment reads `hubble-ui-github-oauth:client-id`:
   ```bash
   kubectl get deploy hubble-ui-oauth2-proxy -n hubble-ui \
     -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.valueFrom.secretKeyRef.name}{":"}{.valueFrom.secretKeyRef.key}{"\n"}{end}'
   ```
3. Confirm startup logs show the registered Client ID:
   ```bash
   kubectl logs -n hubble-ui deploy/hubble-ui-oauth2-proxy --tail=20
   ```

### Cookie secret is rejected

**Cause**: oauth2-proxy requires a literal 16, 24, or 32-byte cookie secret.

**Fix**: Generate and SOPS-encrypt a 32-character value, then restart the proxy:
```bash
openssl rand -hex 16
kubectl delete pod -n hubble-ui -l app.kubernetes.io/name=oauth2-proxy
```

### Hubble UI shows "No flows"

**Cause**: Hubble metrics not enabled, or eBPF not loaded.

**Fix**:
```bash
~/bin/cilium status  # Check eBPF dataplane
kubectl logs -n kube-system -l k8s-app=cilium --tail=20  # Check Cilium logs
```

### Hubble CLI connection refused

**Cause**: Port-forward not running.

**Fix**:
```bash
pkill -f "kubectl port-forward.*hubble-relay"
nohup kubectl port-forward -n kube-system svc/hubble-relay 4244:80 &
~/bin/hubble status --server 127.0.0.1:4244
```

### Hubble CLI version mismatch warning

**Cause**: CLI version (1.19.4) older than relay version (1.20.0).

**Fix**: Update CLI:
```bash
curl -s -L https://github.com/cilium/hubble/releases/latest/download/hubble-darwin-amd64.tar.gz | tar xz -C ~/bin hubble
```

### GitHub OAuth redirect loop

**Cause**: Cookie domain mismatch or callback URL incorrect.

**Fix**: Verify:
- GitHub OAuth App callback URL is exactly `https://hubble.jokelab.dev/oauth2/callback`
- oauth2-proxy `cookie_domains = [".jokelab.dev"]`
- Browser is accessing `https://hubble.jokelab.dev` (not `http`)

### DNS not resolving hubble.jokelab.dev

**Cause**: `/etc/hosts` entry missing.

**Fix**:
```bash
sudo sh -c 'echo "192.168.50.201 hubble.jokelab.dev" >> /etc/hosts'
```

## Security Notes

- Cookie is secure-only (HTTPS)
- Cookie domain scoped to `.jokelab.dev`
- oauth2-proxy runs with read-only root filesystem
- CiliumNetworkPolicy limits ingress to Gateway only
- Hubble UI has no public LoadBalancer or NodePort
