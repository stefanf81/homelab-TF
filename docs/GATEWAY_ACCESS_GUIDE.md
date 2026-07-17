# Cilium Gateway API Access Guide: Domain Routing

This guide explains how to access your TaskFlow application and monitoring stack directly on your network using the configured domain.

---

## 1. Gateway Hostname Routing

Your application route and monitoring routes each have a strict `hostnames:` match:

- **`taskflow-route`** — `www.jokelab.dev` (the bare apex `jokelab.dev` 301-redirects to `www`)
- **`monitoring-routes`** — `grafana.jokelab.dev`

```yaml
# taskflow-route (gitops/apps/taskflow/httproute.yaml)
spec:
  parentRefs:
    - name: taskflow-gateway
      sectionName: https
  hostnames:
    - "www.jokelab.dev"
```

Because hostname-based filtering is active, the Gateway only responds when the client's TLS SNI matches a known hostname. Requests to the Gateway IP without a matching `Host` header will be rejected (no wildcard fallback).

---

## 2. Accessing Your Services

You can access the services through the Cilium Gateway using the following hostnames:

| Service | Access URL | Description |
| :--- | :--- | :--- |
| **TaskFlow Web App** | `https://www.jokelab.dev/` | The Angular 22 Frontend (bare apex `jokelab.dev` 301-redirects to `www`) |
| **TaskFlow API Backend** | `https://www.jokelab.dev/api/...` | The Spring Boot 3.5.3 REST API (same origin as frontend) |
| **Grafana Metrics UI** | `https://grafana.jokelab.dev/` | Real-time performance dashboards |
| **VictoriaMetrics TSDB** | *(Private)* | Scraped time-series metrics. Accessed securely via `kubectl port-forward -n monitoring svc/vmsingle-victoria-metrics-k8s-stack 8428:8428` at `http://localhost:8428/vmsingle/` |

### 🔒 The Same-Origin CORS Advantage
In traditional microservice setups, the frontend (e.g. `http://localhost:4200`) makes calls to a different API backend URL (e.g. `http://localhost:8080`), forcing you to manage complex CORS headers and origin policies. 

Because we use **Cilium Unified Gateway Routing**, both `/` (frontend) and `/api` (backend) are served on the **exact same origin** (`www.jokelab.dev`). The browser performs relative API fetches, treating them as **Same-Origin requests**. **CORS is completely bypassed** on the canonical `www` hostname, ensuring 100% functional, secure, out-of-the-box operations.

> **Note on the bare apex `jokelab.dev`:** it is covered by the TLS cert and is listed in `configmap.yaml`'s `APP_CORS_ALLOWED_ORIGINS`, but the live `taskflow-route` only serves `www.jokelab.dev`. A browser hitting `https://jokelab.dev` is 301-redirected to `https://www.jokelab.dev` (see `apex-to-www-redirect`), so the effective page origin is always `www` and `/api` stays same-origin. Keep `jokelab.dev` in the CORS list as a safety net, but treat `www.jokelab.dev` as the canonical access URL.

---

## 3. Network Considerations

Since the domain `jokelab.dev` maps to the external IP of your Cilium load balancer, ensure that:
1. The domain's DNS resolution points to the gateway IP you receive in your cluster.
2. If testing locally, your router resolves the public domain to the LAN IP natively (NAT reflection/hairpinning), or you configure your local DNS settings accordingly.
