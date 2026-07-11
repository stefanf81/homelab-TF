# Cilium Gateway API Access Guide: Zero-Config Hostname and Raw IP Routing

This guide explains how to access your TaskFlow application and monitoring stack directly on your local area network (LAN) without editing your `/etc/hosts` file or configuring custom local DNS records on your workstation.

---

## 1. The Wildcard Gateway Discovery

Both your application route (`taskflow-route`) and your monitoring route (`monitoring-routes`) are configured without any strict `hostnames:` matches:

```yaml
spec:
  parentRefs:
    - name: taskflow-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /grafana
```

Because the `hostnames` attribute is omitted, the Cilium Gateway behaves as a **wildcard catch-all router**. It routes traffic based *strictly* on path prefixes (`/`, `/api`, `/grafana`, `/vmsingle`), regardless of what domain or Host header is passed in.

This allows you to bypass name-based DNS entirely and use two much simpler, zero-config access patterns.

---

## 2. Option A: Direct Raw IP Access (Easiest)

You can access every service directly using the static IP address of your Kubernetes node VM (`192.168.50.55`):

| Service | Access URL | Description |
| :--- | :--- | :--- |
| **TaskFlow Web App** | [http://192.168.50.55/](http://192.168.50.55/) | The Angular 22 Frontend |
| **TaskFlow API Backend** | [http://192.168.50.55/api/...](http://192.168.50.55/api/) | The Spring Boot 3.5.3 REST API |
| **Grafana Metrics UI** | [http://192.168.50.55/grafana](http://192.168.50.55/grafana) | Real-time performance dashboards |
| **VictoriaMetrics TSDB** | [http://192.168.50.55/vmsingle/](http://192.168.50.55/vmsingle/) | Scraped time-series metrics |

### 🔒 The Same-Origin CORS Advantage
In traditional microservice setups, the frontend (e.g. `http://localhost:4200`) makes calls to a different API backend URL (e.g. `http://localhost:8080`), forcing you to manage complex CORS headers and origin policies. 

Because we use **Cilium Unified Gateway Routing**, both `/` (frontend) and `/api` (backend) are served on the **exact same origin/IP** (`192.168.50.55`). The browser performs relative API fetches, treating them as **Same-Origin requests**. **CORS is completely bypassed**, ensuring 100% functional, secure, out-of-the-box operations on raw IPs!

---

## 3. Option B: Wildcard Public DNS (`nip.io` or `sslip.io`)

Some advanced services (like OIDC providers, external webhooks, or browser password managers) refuse to work on raw IP addresses and require a valid, structured domain name.

Instead of editing your `/etc/hosts` file (which only works on your specific machine), you can use free, wildcard public DNS resolvers like **`nip.io`** or **`sslip.io`**. 

These services automatically resolve any domain name containing an IP address back to that IP:
- `192.168.50.55.nip.io` → Resolves directly to `192.168.50.55`
- `192.168.50.55.sslip.io` → Resolves directly to `192.168.50.55`

### Zero-Config Domain URLs:
You can use these URLs from **any device on your LAN** (including phones, tablets, or other laptops) without any network configuration:

* **TaskFlow Web App:**
  👉 [http://192.168.50.55.nip.io/](http://192.168.50.55.nip.io/)  *(or `sslip.io`)*

* **Grafana Dashboards:**
  👉 [http://192.168.50.55.nip.io/grafana](http://192.168.50.55.nip.io/grafana) *(or `sslip.io`)*

* **VictoriaMetrics UI:**
  👉 [http://192.168.50.55.nip.io/vmsingle/](http://192.168.50.55.nip.io/vmsingle/) *(or `sslip.io`)*

---

## 4. Why this is superior to `/etc/hosts`

1. **Zero Workstation Pollution:** Keeps your Mac/workstation `/etc/hosts` file clean.
2. **Multi-Device Testing:** You can pull out your mobile phone or tablet, connect to your home Wi-Fi, and open `http://192.168.50.55.nip.io/` immediately to test responsiveness.
3. **No VPN/DNS Tunneling Hurdles:** Ideal for testing on virtual machines or isolated dev instances that can route to `192.168.50.55` but don't share your host's local hosts file.
4. **Seamless SSL (Future-Proof):** When we eventually generate TLS certs via cert-manager, we can use HTTP-01 solvers on public subdomains (like `nip.io`) much more easily than on private `.local` domains!
