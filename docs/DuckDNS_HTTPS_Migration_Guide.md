# DuckDNS & HTTPS Public Exposure Guide

This document serves as the historical record and operational runbook for the July 11, 2026 migration of the TaskFlow cluster to a secure, public-facing HTTPS architecture using **DuckDNS**, **Let's Encrypt (HTTP-01)**, and the **Cilium Gateway API**.

---

## 1. Network Topology & IP Mapping

Understanding the IP flow is critical for maintaining this setup:
*   **`84.194.170.2`** — The Public WAN IP (DuckDNS target).
*   **`192.168.50.1`** — The Home Router (ASUS). Port Forwards `80` and `443` internally.
*   **`192.168.50.50`** — The physical Proxmox hypervisor.
*   **`192.168.50.55`** — The K3s Kubernetes Virtual Machine.
*   **`192.168.50.201`** — The Cilium LoadBalancer Gateway IP. Terminates SSL and routes traffic.

---

## 2. Infrastructure Configuration (GitOps)

To convert the cluster from local HTTP to public HTTPS, the following manifest adjustments were committed:

### 2.1 Certificate Issuance
*   **ClusterIssuers (`letsencrypt-http01-issuers.yaml`)**: Configured Let's Encrypt staging and production issuers utilizing the native `gatewayHTTPRoute` solver mechanism.
*   **Certificate (`certificate.yaml`)**: Requested a certificate for `paintlab.duckdns.org` which automatically provisions the `taskflow-tls-secret`.

### 2.2 Gateway & Routing Hardening
*   **Gateway IP Pinning (`gateway.yaml`)**: Hardcoded the LoadBalancer IP to `192.168.50.201` in the Gateway spec to guarantee the router's port forwarding never breaks on a cluster reboot.
*   **HTTPS Listener (`gateway.yaml`)**: Attached port `443` with TLS termination utilizing `taskflow-tls-secret`.
*   **Routing Priority (`httproute.yaml` & `routes.yaml`)**: 
    *   Added `hostnames: ["paintlab.duckdns.org"]` to the main `taskflow-route`.
    *   **Crucial Fix**: Added the same hostname to the `monitoring-routes` to prevent the Gateway API from prioritizing the root `/` path over the `/grafana` subpath.

### 2.3 Application Configurations
*   **CORS (`configmap.yaml`)**: Whitelisted `https://paintlab.duckdns.org` so the Angular frontend can successfully query the Spring Boot backend.
*   **Grafana TLS Termination (`release.yaml`)**: Hardcoded `root_url: "https://%(domain)s/grafana/"`. Because Cilium decrypts the traffic, Grafana perceives the request as HTTP and redirects improperly unless strictly forced to assume HTTPS.

---

## 3. Homelab Networking Solutions (The "Gotchas")

During deployment, three major homelab-specific networking roadblocks were encountered and resolved.

### 3.1 The "Context Deadline Exceeded" Cert-Manager Self-Check
**Symptom**: Let's Encrypt validation failed because `cert-manager`'s internal self-check pod timed out trying to reach `paintlab.duckdns.org`.
**Root Cause**: Hairpin NAT. The pod resolved the domain to the public IP, but the home router dropped the outbound-then-inbound loopback packet.
**Resolution**: **Split-Brain DNS**. We injected a local override directly into K3s's CoreDNS configuration:
1.  Edited `configmap/coredns -n kube-system`.
2.  Added `192.168.50.201 paintlab.duckdns.org` to the `NodeHosts` block.
3.  CoreDNS reloads automatically every 15s. This allowed `cert-manager` to bypass the router and verify itself instantly.

### 3.2 Global DNS Propagation (Secondary Validation Failure)
**Symptom**: Let's Encrypt reported `DNS problem: query timed out looking up A for paintlab.duckdns.org`.
**Root Cause**: DuckDNS updates instantly on the primary DNS server, but Let's Encrypt checks from multiple geographic regions simultaneously. If secondary DNS servers haven't synced, the challenge fails and is marked `invalid`.
**Resolution**: 
1.  Waited 2 minutes.
2.  Verified global propagation using `nslookup paintlab.duckdns.org 1.1.1.1` (Cloudflare).
3.  Deleted the failed certificate (`kubectl delete certificate taskflow-duckdns-cert -n taskflow`) to clear the cache and break the Flux deadlock, forcing an instant, successful retry.

### 3.3 "Host is Down" / Wi-Fi Client Isolation
**Symptom**: The Mac terminal suddenly reported `No route to host` or `Host is down` when pinging `192.168.50.50` (Proxmox), despite having internet access and a `192.168.50.x` IP address.
**Root Cause**: The network interface was isolated from the LAN. This occurs in three primary scenarios:
1.  **Corporate VPN Split-Tunneling**: Activating a work VPN hijacks the `192.168.x.x` subnet routing table to protect enterprise traffic.
2.  **Guest Wi-Fi**: ASUS routers assign Guest networks the same subnet but use `ebtables` to firewall clients from talking to wired LAN devices.
3.  **AP Isolation**: "Set AP Isolated" enabled in the router's wireless settings.
**Resolution**: Ensure corporate VPNs are paused and the device is connected to the primary, non-isolated Wi-Fi SSID.

### 3.4 Bypassing Local Router Hairpin NAT (Browser Loading)
**Symptom**: The site works on cellular data (4G/5G) but times out on the computer connected to the home Wi-Fi.
**Root Cause**: The router lacks or has disabled "NAT Loopback", blocking LAN devices from accessing their own public IP.
**Resolution**: 
*   **Router level**: Enable "NAT Loopback" / "Hairpin NAT" in the ASUS firewall/WAN settings.
*   **Device level**: Edit `/etc/hosts` (Mac/Linux) or `C:\Windows\System32\drivers\etc\hosts` (Windows) and append: `192.168.50.201 paintlab.duckdns.org`.
