# Remediation Plan — October 2026

Issue-by-issue follow-up to `CLUSTER_AUDIT_2026-10.md`. Every issue has:
evidence (file and line), impact, the solution options with trade-offs, a
recommended option with copy-pasteable configuration, how to verify it, and how
to roll it back.

The solutions were researched against the upstream sources of the exact
versions in this repository (k3s v1.36.5 and kine v0.16.5 source, Cilium
v1.20.2, cert-manager v1.21.2, victoria-metrics-k8s-stack 0.96.0, Flux 2.9 /
notification-controller 1.9, Alertmanager v0.34, Grafana 13.2.3, oauth2-proxy,
Falco chart 9.2.0, cloudflared 2026.10.1, CloudNativePG, Kyverno 1.19, Gateway
API v1.6.3). Several vendor documentation sites were unreachable from the
research environment, so the documentation sources on GitHub were read
instead. Statements marked **verify** depend on live cluster state or the
separate backend/frontend repositories; nothing here was applied to the
cluster.

Deep dives: `PERF_DEEP_DIVE_2026-10.md` (PERF-02, PERF-03, PERF-04 — measurements,
mechanisms, sizing and ready-to-commit YAML).

Severity: **High** = data loss, full compromise or silent outage is plausible;
**Medium** = meaningful risk or cost, not immediately exploitable;
**Low** = hygiene.

---

## 1. Issue register

| ID | Issue | Severity | Effort | Downtime | Depends on |
|---|---|---|---|---|---|
| REL-00 | k3s flags on the command line override `config.yaml`; cloud-init can re-run the installer | High | 30 min | k3s restart (pods keep running) | — |
| SEC-01 | Origin reachable without Cloudflare (router port-forward) | High | 2–3 h | seconds per DNS switch | REL-05 |
| SEC-02 | Secrets unencrypted in the k3s datastore and VM backups | High | 30 min | 2 × API restart | REL-00 |
| REL-01 | No alerting, no dead-man's switch | High | 3–4 h | none | — |
| REL-02 | No backups (Postgres, PVCs, keys) | High | ½–1 day | migration window | — |
| REL-03 | Postgres probes can kill crash recovery | High | 5 min | Postgres restart | — |
| SEC-03 | Database accessed as the `postgres` superuser | Medium | 1–2 h | backend restart | — |
| SEC-04 | No egress control | Medium | ½ day per namespace | none if staged | SEC-04a |
| SEC-05 | Unauthenticated UIs/APIs reachable from any pod | Medium | 1 h | none | — |
| SEC-06 | Image automation pushes to `main`; write credential in cluster; no PR validation | Medium | 2–3 h | none | — |
| SEC-07 | oauth2-proxy session cookies collide across subdomains | Medium | 10 min | re-login | — |
| SEC-09 | Falco privileged; detections not alerted | Medium | 30 min | Falco restart | REL-01 |
| SEC-10 | Trivy skips the most privileged images | Medium | 5 min | none | — |
| SEC-11 | Kyverno audit-only on a deprecated API; no Pod Security Admission | Medium | ½ day | none if staged | — |
| SEC-12 | Unsigned images; tag-only third-party images | Medium | ½ day | none | SEC-11 |
| REL-04 | `synchronous_commit=off` on a booking database | Medium | 5 min | Postgres restart | — |
| REL-05 | One 5-name RSA certificate over HTTP-01 | Medium | 1 h | none | — |
| REL-06 | Flux image controllers not in Git; per-release boilerplate | Medium | ½ day | none | — |
| REL-07 | WAF config changes need a manual restart | Low–Med | 1 h | none | — |
| REL-08 | No automated OS reboots / k3s upgrades | Medium | 2 h | planned windows | REL-00/01/02 |
| PERF-01 | kube-proxy still runs next to Cilium | Medium | 20 min | ≈ 30 s | REL-00 |
| PERF-02 | CPU over-reservation, CFS throttling, LimitRange default limit | Medium | 2 h + data | rolling | — |
| PERF-03 | Cilium tuning (`rollOutCiliumPods`, Envoy requests, BBR) | Medium | 30 min | agent restart | — |
| PERF-04 | Postgres tuning and query visibility | Medium | 30 min | Postgres restart | REL-03 |
| SEC-08 | Security headers, HSTS, Grafana session settings | Low–Med | 1 h | none | — |
| SEC-15 | No Kubernetes API audit log | Low–Med | 30 min | API restart | REL-00 |
| SEC-13 | metrics-server skips kubelet TLS verification | Low | 5 min | none | — |
| SEC-14 | Over-broad RBAC, stale OAuth secret, Policy Reporter REST | Low | 30 min | none | — |
| SEC-16 | Provisioning hygiene (root tokens, unverified installer, SSH host key) | Low | 1–2 h | none | — |
| SEC-17 | Private key in env vars and heap dumps | Low | 1 h | backend restart | — |
| PERF-05 | Redis I/O threads in a half-core container | Low | 5 min | Redis restart | — |
| PERF-06 | No `GOMEMLIMIT` on Go services | Low | 10 min | WAF restart | — |
| PERF-07 | JVM flags | Low | 15 min | backend restart | PERF-02 |
| PERF-08 | CoreDNS cache | Low | 10 min | none | — |
| PERF-09 | Edge caching and TLS handshake cost | Low | 30 min | none | REL-05 |
| PERF-10 | Logging pipeline (gateway hop, scope, Loki footprint) | Low | 1 h–1 day | none | — |
| PERF-11 | Kyverno footprint | Low | 10 min | none | SEC-11 |
| PERF-12 | VictoriaMetrics cardinality | Low | 30 min | none | — |

---

## 2. Suggested order (maintenance windows)

**Window 0 — no downtime, do first**

1. REL-02 stopgap: nightly `pg_dump` to object storage; export the SOPS age key,
   the k3s token and (after SEC-02) the encryption config to a password manager.
2. REL-01: alerting, dead-man's switch, external probe.
3. REL-00 part 2: `touch /etc/cloud/cloud-init.disabled` on the node; add
   `user_data_file_id` to `ignore_changes`.

**Window 1 — node, ~45 min, Proxmox snapshot first**

4. REL-00 part 1: move every k3s flag into `config.yaml`.
5. SEC-02: secrets encryption (two restarts), then a second `rotate-keys`.
6. PERF-01 + SEC-15: `disable-kube-proxy`, audit log; reboot to clear `KUBE-*` rules.

**Window 2 — GitOps changes, one PR each, rolling restarts**

7. REL-03 + PERF-04 + REL-04 (one Postgres restart), PERF-05.
8. SEC-03 database roles.
9. SEC-07, SEC-08, SEC-13, SEC-10, SEC-14, PERF-08, PERF-03.
10. PERF-02 sized from the 14 days VictoriaMetrics already holds (LimitRange change in the same commit), PERF-06, PERF-07 — see `PERF_DEEP_DIVE_2026-10.md` §6 for the combined order with PERF-03/04.

**Window 3 — edge**

11. REL-05 DNS-01 wildcard → SEC-01 tunnel with the WAF trusted-proxy change →
    close the router ports.

**Window 4 — guardrails**

12. SEC-04a/SEC-04 egress (audit first), SEC-05.
13. SEC-11 PSA labels and Kyverno policies, SEC-09 Falco, REL-07 Reloader.
14. REL-08 kured + system-upgrade-controller (only after backups and alerts work).

**Window 5 — platform convergence**

15. REL-02 CloudNativePG migration with barman-cloud backups; PVC backups.
16. REL-06 Flux Operator + OCI chart sources; SEC-06 image updates via PR; SEC-12
    signing and verification; PERF-10 VictoriaLogs (optional).

---

## 3. Security

### SEC-01 — The origin is reachable without Cloudflare

| | |
|---|---|
| Severity | High |
| Evidence | `docs/ARCHITECTURE.md:509` and `docs/ABUSEIPDB_CILIUM_BLOCKLIST.md:79` (public IP → router port-forward → `192.168.50.201`); `gitops/infrastructure/configs/cilium/abuseipdb-ingress-deny.yaml:49` (`fromEntities: all`) |
| Effort / downtime | Option A: 2–3 h, a few seconds per DNS switch; option B: 1 h, none |
| Depends on | REL-05 (DNS-01) recommended first |

**Impact.** Cloudflare's WAF, bot protection, DDoS absorption, rate limiting and
the AbuseIPDB edge list only apply to clients that choose to go through
Cloudflare. Anyone who learns the WAN address (internet-wide TLS scans index
certificates by IP) reaches the Gateway, including `grafana.`, `hubble.` and
`kyverno.`, directly. The Cilium AbuseIPDB deny removes only known-bad sources.

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | **Cloudflare Tunnel** (`cloudflared`, outbound only); close 80/443 on the router | No inbound port at all; what onedr0p/buroa/szinn run; DDNS no longer needed | One more Deployment; client-IP chain changes (see below); the Cilium AbuseIPDB deny stops seeing real client IPs (the Cloudflare edge list keeps working) |
| B | Keep the port-forward; allow only Cloudflare ranges + LAN on `reserved:ingress` | No new component | Proves only "came through *some* Cloudflare account"; the Cloudflare range list must be kept current; verify the router does not SNAT forwarded traffic (the Gateway must see public source IPs) |
| C | WireGuard to a small VPS that forwards to the Gateway; allow only the VPS address (bjw-s's model) | Independent of Cloudflare | A VPS to run and patch; client IP needs PROXY protocol |
| — | Cloudflare Authenticated Origin Pulls (mTLS) | — | **Not feasible:** Cilium 1.20.2 lists `GatewayFrontendClientCertificateValidation` as unsupported and ignores `spec.tls.frontend` (`operator/pkg/gateway-api/gatewayclass_status.go`); AOP also does not apply to tunnels |

**Recommended: A.** Implementation:

1. Create a locally-managed tunnel (ingress rules stay in Git):
   `cloudflared tunnel login && cloudflared tunnel create homelab`; store the
   generated `<UUID>.json` as a SOPS secret `tunnel-credentials`
   (key `credentials.json`) in a new `cloudflared` namespace.
2. Deploy (image `cloudflare/cloudflared:2026.10.1`, pin the digest; the image
   runs as UID 65532 with entrypoint `cloudflared --no-autoupdate`):

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: {name: cloudflared-config, namespace: cloudflared}
   data:
     config.yaml: |
       tunnel: <UUID>
       credentials-file: /etc/cloudflared/credentials.json
       originRequest:
         originServerName: jokelab.dev     # SAN on the Gateway certificate (SNI + verification)
         http2Origin: true
       ingress:
         - hostname: jokelab.dev
           service: https://cilium-gateway-taskflow-gateway.taskflow.svc.cluster.local:443
         - hostname: "*.jokelab.dev"
           service: https://cilium-gateway-taskflow-gateway.taskflow.svc.cluster.local:443
         - service: http_status:404        # mandatory catch-all
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata: {name: cloudflared, namespace: cloudflared}
   spec:
     replicas: 2
     selector: {matchLabels: {app: cloudflared}}
     template:
       metadata: {labels: {app: cloudflared}}
       spec:
         automountServiceAccountToken: false
         securityContext:
           runAsNonRoot: true
           runAsUser: 65532
           runAsGroup: 65532
           seccompProfile: {type: RuntimeDefault}
         containers:
           - name: cloudflared
             image: cloudflare/cloudflared:2026.10.1   # + @sha256:<digest>
             args: [tunnel, --config, /etc/cloudflared/config.yaml,
                    --metrics, 0.0.0.0:2000, --output, json, run]
             ports: [{name: metrics, containerPort: 2000}]
             readinessProbe: {httpGet: {path: /ready, port: 2000}, periodSeconds: 10}
             livenessProbe: {httpGet: {path: /healthcheck, port: 2000}, periodSeconds: 10, failureThreshold: 3}
             resources:
               requests: {cpu: 10m, memory: 32Mi}
               limits: {memory: 128Mi}
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: {drop: [ALL]}
             volumeMounts: [{name: cfg, mountPath: /etc/cloudflared, readOnly: true}]
         volumes:
           - name: cfg
             projected:
               sources:
                 - configMap: {name: cloudflared-config}
                 - secret: {name: tunnel-credentials}
   ```

   `/ready` returns 503 while no edge connection is up, so it is the readiness
   probe; `/healthcheck` always answers and is the liveness probe (Cloudflare's
   own example uses `/ready` for liveness, which restarts pods on every edge blip).
3. Egress policy for the connector (port 7844 TCP+UDP to the
   `*.v2.argotunnel.com` edge; DNS SRV/TXT lookups under `argotunnel.com`):

   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata: {name: cloudflared, namespace: cloudflared}
   spec:
     endpointSelector: {matchLabels: {app: cloudflared}}
     egress:
       - toEndpoints:
           - matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s:k8s-app: kube-dns}
         toPorts:
           - ports: [{port: "53", protocol: ANY}]
             rules: {dns: [{matchPattern: "*"}]}
       - toFQDNs: [{matchPattern: "*.v2.argotunnel.com"}]
         toPorts: [{ports: [{port: "7844", protocol: ANY}]}]
       - toEntities: [cluster]     # the Gateway (narrow after checking with hubble)
   ```

4. **Client IP — required WAF change.** Through the tunnel the chain is: Cloudflare
   sets `X-Forwarded-For: <client>` (it never adds its edge IP), cloudflared
   leaves XFF alone, and Cilium's Envoy appends its TCP peer — the cloudflared
   **pod IP**. Caddy therefore receives `XFF: <client>, <cloudflared-pod-IP>`
   from `10.42.0.148`. With today's `trusted_proxies` (Envoy SNAT + Cloudflare
   ranges) the right-to-left walk stops at the cloudflared pod IP, so **every
   visitor would share one rate-limit bucket.** Fix both WAF Caddyfiles in the
   same change:

   ```caddyfile
   trusted_proxies static 10.42.0.0/16    # Envoy SNAT + cloudflared pods
   trusted_proxies_strict
   client_ip_headers X-Forwarded-For
   ```

   Trusting the pod CIDR is safe only if no other pod can reach the Gateway, so
   pair it with the Gateway source policy in step 5. Update the WAF test suite's
   trusted-proxy fixtures at the same time (`tests/gen-config.py`).
5. Replace `abuseipdb-ingress-deny.yaml` with one policy that keeps the deny and
   allows only the tunnel, the LAN and the node:

   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata: {name: gateway-ingress}
   spec:
     endpointSelector: {matchExpressions: [{key: reserved:ingress, operator: Exists}]}
     ingressDeny:
       - fromCIDRSet: [{cidrGroupRef: abuseipdb}]
     ingress:
       - fromEndpoints:
           - matchLabels: {k8s:io.kubernetes.pod.namespace: cloudflared, app: cloudflared}
       - fromCIDRSet: [{cidr: 192.168.50.0/24}]   # LAN clients (split DNS / hairpin)
       - fromEntities: [host]
   ```

   Allow rules are additive and deny always wins, so the old policy's
   `fromEntities: all` must not survive anywhere.
6. DNS cut-over per hostname: remove the name from favonia's `DOMAINS`, delete
   the A record (Cloudflare refuses a CNAME next to an A record), create a
   proxied CNAME to `<UUID>.cfargotunnel.com` (`cloudflared tunnel route dns
   homelab www.jokelab.dev`). Start with `hubble.` and `kyverno.`, then
   `grafana.`, then `www.` and the apex (CNAME flattening handles the apex).
   When no names are left, delete the `cloudflare-ddns` Deployment and its token.
7. Close 80/443 on the router. If HTTP-01 is still in use, move to DNS-01
   (REL-05) first: HTTP-01 through the tunnel only works if the challenge
   reaches the listener the solver route is attached to.

**Verify.** `curl -sI https://www.jokelab.dev` works; `curl --resolve
www.jokelab.dev:443:<WAN-IP> https://www.jokelab.dev` from outside times out;
WAF access logs show real client IPs (not `10.42.x.x`); the rate-limit test from
`docs/TASKFLOW_WAF_RUNBOOK.md` passes.

**Rollback.** Re-open the port-forward, restore the A records (re-add the names
to favonia), restore the old WAF `trusted_proxies` and Cilium policy.

**Option B, if you keep the port-forward.** Add a `CiliumCIDRGroup` (use
`cilium.io/v2`; `v2alpha1` is deprecated) with Cloudflare's published ranges and
use it in the same policy as step 5 instead of the `cloudflared` endpoint rule.
Also add the Cloudflare ranges to `protected-cidrs.txt` in
`abuseipdb/config.yaml`: reputation feeds occasionally list Cloudflare
addresses, and deny wins. First confirm with
`hubble observe --to-identity ingress --since 10m` that external flows arrive
with public source IPs; if the router SNATs forwarded traffic, an IP allowlist
cannot work.

---

### SEC-02 — Secrets are stored unencrypted in the k3s datastore

| | |
|---|---|
| Severity | High |
| Evidence | No `secrets-encryption` in `modules/proxmox/main.tf:87`; datastore is sqlite (`/var/lib/rancher/k3s/server/db/state.db`) |
| Effort / downtime | 30 min / two API-server restarts of a few tens of seconds (pods keep running) |
| Depends on | REL-00 (flags in `config.yaml`) |

**Impact.** Every Secret — including `flux-system/sops-age`, which decrypts the
whole repository — sits in plaintext in `state.db` and in every Proxmox backup
of the VM disk.

**Options**

| Option | What | Note |
|---|---|---|
| A | k3s `secrets-encryption` with the default `aescbc` provider | Supported on existing clusters since v1.33.10/v1.34.6/v1.35.3; works on sqlite (re-encryption goes through the API) |
| B | Same with `secrets-encryption-provider: secretbox` (XSalsa20-Poly1305) | Modern AEAD; set it **before** `rotate-keys`, because the new key is created with the configured provider |
| C | External KMS plugin | Overkill for one node |

**Recommended: B.** Procedure (on the node, after REL-00):

```bash
# 0. Safety copies
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup /root/state-pre-encrypt.db"
sudo cp /var/lib/rancher/k3s/server/token /root/k3s-token.bak

# 1. Prepare and enable
sudo k3s secrets-encrypt status                 # Disabled, no configuration file found
sudo k3s secrets-encrypt enable                 # writes an identity-only config
# /etc/rancher/k3s/config.yaml:
#   secrets-encryption: true
#   secrets-encryption-provider: secretbox
sudo systemctl restart k3s
sudo k3s secrets-encrypt status                 # stage start, all hashes match

# 2. Generate a key and re-encrypt every Secret (~5 Secrets/s)
sudo k3s secrets-encrypt rotate-keys
sudo systemctl restart k3s
sudo k3s secrets-encrypt status                 # Enabled, reencrypt_finished
```

Verify nothing is left in plaintext:

```bash
sudo sqlite3 -readonly /var/lib/rancher/k3s/server/db/state.db "
  SELECT COUNT(*) FROM kine k
  WHERE k.name LIKE '/registry/secrets/%' AND k.deleted = 0
    AND k.id = (SELECT MAX(id) FROM kine WHERE name = k.name)
    AND hex(substr(k.value,1,8)) <> hex('k8s:enc:');"     # expect 0
```

Two caveats from the k3s and kine sources:

- kine keeps the previous value of each row in an `old_value` column, so right
  after the first rotation the plaintext still exists there. Run `rotate-keys` a
  second time; compaction (after ~1000 newer revisions) removes superseded rows
  and kine's `VACUUM` on start frees the space.
- VM backups taken before the change still contain plaintext. Rotate the
  credentials that matter most afterwards (Cloudflare tokens, GHCR token, the
  age key if you want to be thorough — see SEC-06).

Back up `/var/lib/rancher/k3s/server/cred/encryption-config.json`,
`encryption-state.json` and the server `token` **outside** the VM (password
manager or SOPS-encrypted in a private repo). A VM backup holds database, key
and token together, so it is only protected if those files are not in the same
backup set you are worried about; a database-only restore is impossible without
them.

**Rollback.** `k3s secrets-encrypt disable`, restart, `k3s secrets-encrypt
reencrypt --force --skip`.

---

### SEC-03 — Database accessed as the `postgres` superuser

| | |
|---|---|
| Severity | Medium (High if the backend uses it too) |
| Evidence | `gitops/apps/taskflow/postgres-exporter.yaml:39` (`postgresql://postgres:…`), `postgres-db.yaml:99` (`POSTGRES_USER=postgres`), `backend.yaml` reads the same `db-secret/POSTGRES_PASSWORD` and sets no username (**verify** `spring.datasource.username` in the backend image) |
| Effort / downtime | 1–2 h / one backend restart (seconds) |

**Impact.** A superuser can run `COPY … TO PROGRAM '…'`, load untrusted
languages and read any file the `postgres` OS user can read. One SQL injection
in the backend becomes a shell inside the database pod; a leaked exporter
password is a full database compromise.

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Create `taskflow_app` (schema owner) and `postgres_exporter` (`pg_monitor`) roles in the existing instance | Small, no data move, reversible | Manual SQL once; Flyway migrations that need superuser (e.g. untrusted extensions) must be checked |
| B | Migrate to CloudNativePG (REL-02), which creates an `app` owner role and disables superuser access | Solves this and backups together | Larger change |
| C | A, plus a `pg_hba.conf` that rejects network logins for `postgres` | Superuser only via `kubectl exec` (local socket) | One more ConfigMap |

**Recommended: A + C now.** The CloudNativePG migration (REL-02 option B)
later supersedes both: its import re-owns every object to an unprivileged
`taskflow` role and disables superuser access.

1. Add three keys to the SOPS file (`sops gitops/apps/taskflow/taskflow-secrets.yaml`,
   `db-secret` document): `APP_DB_USERNAME: taskflow_app`, `APP_DB_PASSWORD`,
   `EXPORTER_DB_PASSWORD` (generate with `openssl rand -base64 32`).
2. Create the roles (local socket, so no password on the command line):

   ```bash
   kubectl -n taskflow exec -it deploy/postgres-db -- psql -U postgres -d taskflow
   ```

   ```sql
   CREATE ROLE taskflow_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
   \password taskflow_app
   CREATE ROLE postgres_exporter LOGIN;
   \password postgres_exporter
   GRANT pg_monitor TO postgres_exporter;

   ALTER DATABASE taskflow OWNER TO taskflow_app;
   ALTER SCHEMA public OWNER TO taskflow_app;

   -- Hand over every object in `public` that is not part of an extension.
   -- Sequences owned by a column follow their table automatically.
   DO $$
   DECLARE r record;
   BEGIN
     FOR r IN
       SELECT c.relkind, c.relname FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','f')
         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
     LOOP
       EXECUTE format('ALTER %s public.%I OWNER TO taskflow_app',
         CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                        WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END, r.relname);
     END LOOP;
     FOR r IN
       SELECT c.relname FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind = 'S'
         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a','i','e'))
     LOOP
       EXECUTE format('ALTER SEQUENCE public.%I OWNER TO taskflow_app', r.relname);
     END LOOP;
     FOR r IN
       SELECT p.oid::regprocedure AS sig, p.prokind FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
         AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
     LOOP
       EXECUTE format('ALTER %s %s OWNER TO taskflow_app',
         CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, r.sig);
     END LOOP;
   END $$;

   -- Check: nothing in public should still belong to postgres.
   SELECT relname, relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND pg_get_userbyid(c.relowner) = 'postgres';
   ```

   Before running it, grep the backend's Flyway migrations for `CREATE EXTENSION`:
   trusted extensions (e.g. `pgcrypto`, `citext`) can be created by the database
   owner since PostgreSQL 13; anything else must be created once by `postgres`.
3. Point the workloads at the new roles:

   ```yaml
   # backend.yaml, container env (replace the SPRING_DATASOURCE_PASSWORD entry)
   - name: SPRING_DATASOURCE_USERNAME
     valueFrom: {secretKeyRef: {name: db-secret, key: APP_DB_USERNAME}}
   - name: SPRING_DATASOURCE_PASSWORD
     valueFrom: {secretKeyRef: {name: db-secret, key: APP_DB_PASSWORD}}

   # postgres-exporter.yaml
   - name: POSTGRES_PASSWORD
     valueFrom: {secretKeyRef: {name: db-secret, key: EXPORTER_DB_PASSWORD}}
   - name: DATA_SOURCE_NAME
     value: "postgresql://postgres_exporter:$(POSTGRES_PASSWORD)@db:5432/taskflow?sslmode=disable"
   ```

   If the generated passwords can contain `/`, `@` or `:`, URL-encode them or
   use the exporter's `DATA_SOURCE_URI` + `DATA_SOURCE_USER` + `DATA_SOURCE_PASS`
   variables instead of one DSN.
4. Option C — reject the superuser over the network. Add a ConfigMap and two args:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: {name: postgres-hba, namespace: taskflow}
   data:
     pg_hba.conf: |
       # TYPE  DATABASE  USER      ADDRESS  METHOD
       local   all       all                trust          # kubectl exec only
       host    all       postgres  all      reject
       host    all       all       all      scram-sha-256
   ```

   ```yaml
   # postgres-db.yaml: args += ["-c", "hba_file=/etc/postgresql/pg_hba.conf"]
   volumeMounts: [{name: hba, mountPath: /etc/postgresql, readOnly: true}]
   volumes: [{name: hba, configMap: {name: postgres-hba}}]
   ```

**Verify.** `SELECT usename, application_name, client_addr FROM pg_stat_activity;`
shows `taskflow_app` and `postgres_exporter` only; `psql -h db -U postgres` from
another pod is rejected; backend `/actuator/health/readiness` is `UP`; Flyway
history shows no failed migration on the next deploy.

**Rollback.** Revert the env changes (the `postgres` password is unchanged);
remove the `hba_file` arg. Object ownership can stay with `taskflow_app`.

---

### SEC-04 — No egress control

| | |
|---|---|
| Severity | Medium |
| Evidence | `gitops/apps/taskflow/default-deny.yaml:26` and `namespace-default-deny.yaml:9` ("EGRESS is intentionally left allow-all"); `monitoring/platform/network-policies.yaml` header; only `renovate` and `abuseipdb` restrict egress |
| Effort / downtime | Half a day per namespace including observation / none if staged |

**Impact.** Any compromised pod can exfiltrate data to the internet, download
tooling, and reach every unauthenticated in-cluster service (SEC-05). Postgres,
Redis and Jaeger have no reason to open outbound connections at all.

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Kubernetes `NetworkPolicy` egress rules | Portable | No FQDN rules: external dependencies need IP ranges |
| B | `CiliumNetworkPolicy` with `toFQDNs` per workload | FQDN allow-lists (SMTP, Cloudflare API) via Cilium's DNS proxy, same tooling as `abuseipdb-sync` | Cilium-specific |
| C | B, plus a `CiliumClusterwideNetworkPolicy` baseline for all non-system namespaces | One place for the default | Highest blast radius if wrong |

**Recommended: B for `taskflow` first, then `policy-reporter`, `hubble-ui`,
`monitoring`; C only after every namespace has its own allow-list.**

Step 1 — discover real dependencies before enforcing. The backend sends
reminder mails, but no SMTP host is configured in this repo (**verify** in the
backend image or its secrets). Use the staged rollout described in SEC-04a
(policy audit mode) or watch DNS answers for a day:

```bash
cilium hubble port-forward &
hubble observe --namespace taskflow --protocol dns --since 1h -o compact
hubble observe --from-namespace taskflow --to-identity world --since 1h -o compact
```

Step 2 — the policies. A CNP with egress rules switches its endpoints to
egress default-deny, so the first policy below is both the namespace default
and the DNS allowance (with the DNS proxy enabled, which `toFQDNs` needs):

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: egress-baseline-dns, namespace: taskflow}
spec:
  endpointSelector: {}            # every pod in taskflow: egress default-deny + DNS
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}]
          rules:
            dns: [{matchPattern: "*"}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: egress-backend, namespace: taskflow}
spec:
  endpointSelector: {matchLabels: {app: taskflow-backend}}
  egress:
    - toEndpoints: [{matchLabels: {app: postgres-db}}]
      toPorts: [{ports: [{port: "5432", protocol: TCP}]}]
    - toEndpoints: [{matchLabels: {app: redis}}]
      toPorts: [{ports: [{port: "6379", protocol: TCP}]}]
    - toEndpoints: [{matchLabels: {app: jaeger}}]
      toPorts: [{ports: [{port: "4317", protocol: TCP}, {port: "4318", protocol: TCP}]}]
    # Reminder mails. Replace with the real relay found in step 1.
    - toFQDNs: [{matchName: smtp.example.com}]
      toPorts: [{ports: [{port: "587", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: egress-exporters, namespace: taskflow}
spec:
  endpointSelector:
    matchExpressions: [{key: app, operator: In, values: [postgres-exporter, redis-exporter]}]
  egress:
    - toEndpoints: [{matchLabels: {app: postgres-db}}]
      toPorts: [{ports: [{port: "5432", protocol: TCP}]}]
    - toEndpoints: [{matchLabels: {app: redis}}]
      toPorts: [{ports: [{port: "6379", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: egress-cloudflare-ddns, namespace: taskflow}
spec:
  endpointSelector: {matchLabels: {app: cloudflare-ddns}}
  egress:
    - toFQDNs: [{matchName: api.cloudflare.com}]
      toPorts: [{ports: [{port: "443", protocol: TCP}]}]
    # IP detection (favonia's default `cloudflare.trace` provider). Verify the
    # exact endpoints in step 1; drop this rule once a Cloudflare Tunnel replaces DDNS.
    - toCIDR: [1.1.1.1/32, 1.0.0.1/32]
      toPorts: [{ports: [{port: "443", protocol: TCP}]}]
```

Postgres, Redis, Jaeger and the frontend get DNS only (from the baseline). The
two WAFs already have their own egress policies. The backend's `wait-for-db`
init container is covered by the backend policy (same pod).

**Verify.** `hubble observe --namespace taskflow --verdict DROPPED -f` stays
quiet through a full day (including a reminder-mail run); the app works; the
dropped-flows panel in the existing Hubble/Loki pipeline shows no `taskflow`
egress drops.

**Rollback.** `kubectl -n taskflow delete cnp egress-baseline-dns egress-backend
egress-exporters egress-cloudflare-ddns` restores allow-all egress instantly
(also remove them from Git so Flux does not re-apply).

---

### SEC-04a — Staging network policies safely (Cilium audit mode)

Cilium 1.20 has no per-namespace or per-policy audit switch
(`enableDefaultDeny.egress: false` only stops a policy from creating a default
deny; it is not an audit mode). Two scopes exist:

| Scope | How | Note |
|---|---|---|
| Whole agent | Helm `policyAuditMode: true` + agent restart | **No** policy is enforced anywhere while it is on — including today's ingress policies. Avoid. |
| Per endpoint | `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled` | Temporary: resets when the agent restarts |

Procedure for SEC-04 (per endpoint):

```bash
# endpoint IDs of the taskflow pods
kubectl -n taskflow get cep -o custom-columns=NAME:.metadata.name,ID:.status.id
for id in $(kubectl -n taskflow get cep -o jsonpath='{.items[*].status.id}'); do
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint config "$id" PolicyAuditMode=Enabled
done
# apply the SEC-04 policies, then watch what *would* have been dropped
hubble observe -n taskflow --verdict AUDIT -f
# refine the policies until no AUDIT verdicts remain for a full day (incl. a reminder-mail run), then:
for id in …; do kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint config "$id" PolicyAuditMode=Disabled; done
```

A rolled pod gets a new endpoint ID (and leaves audit mode), so freeze
deployments to the namespace during the observation period.

---

### SEC-05 — Unauthenticated services reachable from any pod

| | |
|---|---|
| Severity | Medium |
| Evidence | Hubble UI/relay in `kube-system` (enabled in `cilium/release.yaml:77`) have no policy; `policy-reporter` UI and core have none (only the oauth2-proxy is protected by `oauth2-proxy-network-policy.yaml`); `rest.enabled: true` in `policy-reporter/release.yaml:34` |
| Effort / downtime | 1 h / none |

**Impact.** oauth2-proxy only guards the public path. From inside the cluster,
`hubble-relay.kube-system:80` streams every network flow and the Policy
Reporter UI/API lists every vulnerability and misconfiguration — a ready-made
reconnaissance kit for an attacker who lands in any pod. (The `monitoring`
namespace is already ingress-default-deny.)

**Recommended:**

```yaml
# kube-system: only the hubble-ui oauth2-proxy (and the node) may reach the UI;
# only the UI (and the node, for `cilium hubble port-forward`) may reach relay.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: hubble-ui-ingress, namespace: kube-system}
spec:
  endpointSelector: {matchLabels: {k8s-app: hubble-ui}}
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: hubble-ui
            app.kubernetes.io/name: oauth2-proxy
      toPorts: [{ports: [{port: "8081", protocol: TCP}]}]
    - fromEntities: [host]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: hubble-relay-ingress, namespace: kube-system}
spec:
  endpointSelector: {matchLabels: {k8s-app: hubble-relay}}
  ingress:
    - fromEndpoints: [{matchLabels: {k8s-app: hubble-ui}}]
      toPorts: [{ports: [{port: "4245", protocol: TCP}]}]
    - fromEntities: [host]
---
# policy-reporter: same-namespace traffic (oauth2-proxy -> UI -> core/plugins),
# monitoring scrapes and the node only. The existing policy already limits the
# oauth2-proxy itself to the Gateway.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: namespace-ingress-default-deny, namespace: policy-reporter}
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints: [{matchLabels: {k8s:io.kubernetes.pod.namespace: policy-reporter}}]
    - fromEndpoints: [{matchLabels: {k8s:io.kubernetes.pod.namespace: monitoring}}]
      toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
    - fromEntities: [host]
```

Ports are the container ports (`hubble-ui` frontend 8081, relay gRPC 4245);
**verify** with `kubectl -n kube-system get svc hubble-ui hubble-relay -o wide`.
Put the two `kube-system` policies under `infrastructure/configs/cilium/` (the
Cilium Kustomization must not own the namespace), and the third next to the
Policy Reporter release.

Then test `rest.enabled: false` on Policy Reporter: the chart documents it only
as "Enables the REST API" and does not say the UI needs it. If the UI still
loads, keep it off.

**Verify.** `kubectl run t --rm -it --image=curlimages/curl -n default --
curl -m3 hubble-relay.kube-system:80` times out; Hubble UI and Policy Reporter
UI still work through their hostnames.

**Rollback.** Delete the policies.

---

### SEC-06 — Image automation pushes unreviewed commits to `main`

| | |
|---|---|
| Severity | Medium |
| Evidence | `gitops/clusters/taskflow/image-automation.yaml:96` (`push.branch: main`); the `flux-system` GitRepository credential must be write-capable; no branch protection; only WAF/dashboard paths are validated in CI (`.github/workflows/validate-waf-config.yaml`) |
| Effort / downtime | 2–3 h / none |

**Impact.** Anyone who can read `flux-system` Secrets (a compromised controller,
a leaked kubeconfig) gets a credential that writes to `main`, and Flux deploys
whatever lands there — cluster compromise becomes persistent repository
compromise. Separately, a broken render reaches the cluster with no CI gate.

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Automation pushes to `flux/image-updates`; a workflow opens an auto-merging PR gated on validation; the sync source becomes read-only | Every change reviewed by CI; least privilege | GitHub App for the workflow token; repo settings |
| B | `push.refspec` | — | Static, still pushes to the checkout branch, PR creation via push options is GitLab/Gerrit/Gitea only — **not useful on GitHub** |
| C | Keep direct push, protect `main` with a ruleset, let Flux bypass it | Simple | On github.com a **deploy key cannot be a bypass actor**; Flux must authenticate as a GitHub App (`GitRepository.spec.provider: github`) that you add as bypass actor — the bypass credential stays powerful and commits stay unreviewed |

**Recommended: A.**

1. Split credentials: `ImageUpdateAutomation.spec.sourceRef` may point at any
   `GitRepository`, and that object's credentials are used for the push.

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata: {name: homelab-write, namespace: flux-system}
   spec:
     interval: 1h
     url: https://github.com/stefanf81/homelab-TF.git
     ref: {branch: main}
     secretRef: {name: homelab-write}     # write-capable token/deploy key, used only here
   ---
   # image-automation.yaml
   spec:
     sourceRef: {kind: GitRepository, name: homelab-write}
     git:
       checkout: {ref: {branch: main}}
       push: {branch: flux/image-updates} # force-pushed from main + change on every run
   ```

   Then replace the `flux-system` credential with a read-only deploy key.
2. Workflow `.github/workflows/image-pr.yaml` (use a GitHub App token — PRs
   created with `GITHUB_TOKEN` do not trigger CI runs without approval):

   ```yaml
   on: {push: {branches: [flux/image-updates]}}
   permissions: {contents: read}
   jobs:
     pr:
       runs-on: ubuntu-latest
       timeout-minutes: 5
       steps:
         - id: app
           uses: actions/create-github-app-token@<sha>     # v3.3.0
           with: {client-id: "${{ vars.APP_CLIENT_ID }}", private-key: "${{ secrets.APP_KEY }}"}
         - env: {GH_TOKEN: "${{ steps.app.outputs.token }}", R: "${{ github.repository }}"}
           run: |
             gh pr view flux/image-updates -R "$R" >/dev/null 2>&1 \
               || gh pr create -R "$R" -H flux/image-updates -B main -t "chore: automated TaskFlow image update" -b "Opened by Flux image automation."
             gh pr merge flux/image-updates -R "$R" --auto --squash
   ```

3. Repository settings: allow auto-merge, automatically delete head branches,
   and a ruleset on `main` requiring the validation check below (and blocking
   force-pushes).
4. Validation on every GitOps change (flux-local renders all Kustomizations and
   HelmReleases and wipes Secret values, so SOPS files need no key; flux-schema
   validates against the CRD schemas):

   ```yaml
   name: validate-gitops
   on:
     pull_request: {branches: [main], paths: ["gitops/**"]}
   permissions: {contents: read}
   jobs:
     flux-local:
       runs-on: ubuntu-latest
       timeout-minutes: 15
       steps:
         - uses: actions/checkout@<sha>                    # v7
           with: {persist-credentials: false}
         - uses: fluxcd/flux2/action@<sha>                 # v2.9.6
         - uses: allenporter/flux-local/action/test@<sha>  # 8.4.0
           with: {path: gitops/clusters/taskflow, enable-helm: true}
   ```

   Optionally add `allenporter/flux-local/action/diff` (HelmRelease diffs as a
   PR comment; needs `pull-requests: write`).

**Verify.** A new image creates/updates one PR, CI runs, the PR merges, Flux
deploys; a direct push to `main` from a workstation is rejected by the ruleset.

---

### SEC-07 — The two oauth2-proxies overwrite each other's sessions

| | |
|---|---|
| Severity | Medium |
| Evidence | `hubble-ui/release.yaml:40` and `policy-reporter/oauth2-proxy-release.yaml:47` (`cookie_domains = [".jokelab.dev"]`, default cookie name) |
| Effort / downtime | 10 min / none (users log in again) |

**Impact.** Both proxies set `_oauth2_proxy` on `.jokelab.dev` with different
secrets. Each one rejects the other's cookie ("cookie signature not valid") and
clears it, so logging into one logs you out of the other; the session cookie is
also sent to `www.jokelab.dev`, where the public app and its WAF logs see it.

**Options:** (A) host-only cookies with distinct names; (B) one shared
`cookie_secret` and name across both proxies for single sign-on.

**Recommended: A** (each UI is a separate trust boundary):

```toml
# hubble-ui proxy (use "__Host-o2p-kyverno" on the other)
cookie_name = "__Host-o2p-hubble"
cookie_samesite = "lax"
cookie_expire = "24h"
# remove: cookie_domains = [".jokelab.dev"]
```

The `__Host-` prefix forces `Secure`, `Path=/` and no `Domain` attribute. Keep
`scope = "user:email read:org"`: oauth2-proxy's GitHub provider always calls
`/user/orgs` while enriching the session and fails without `read:org` (this
corrects the audit's advice to drop it). `whitelist_domains` can be narrowed to
the proxy's own host.

**Verify.** Log into both UIs in one browser; both stay logged in; browser dev
tools show two host-only cookies and none for `.jokelab.dev`.

---

### SEC-08 — Security headers and Grafana session hardening

| | |
|---|---|
| Severity | Low–Medium |
| Evidence | No HSTS/CSP in the Gateway routes or either Caddyfile; `monitoring/platform/release.yaml:200-230` sets no `[security]` options |
| Effort / downtime | 1 h / none |

**Options for HSTS:** (a) Cloudflare edge setting (dashboard, proxied traffic
only, not in Git); (b) Caddy `header` in each WAF (TaskFlow only); (c) a
`ResponseHeaderModifier` filter on every HTTPRoute rule (supported by Cilium
1.20, covers LAN traffic and every host).

**Recommended:** HSTS and generic headers in one place — (c); application CSP
in the frontend WAF; Grafana's own options for Grafana.

```yaml
# every HTTPRoute rule (taskflow-route, monitoring-routes, policy-reporter, hubble)
filters:
  - type: ResponseHeaderModifier
    responseHeaderModifier:
      set:
        - {name: Strict-Transport-Security, value: "max-age=63072000; includeSubDomains"}  # start with max-age=300
        - {name: X-Content-Type-Options, value: nosniff}
        - {name: Referrer-Policy, value: strict-origin-when-cross-origin}
```

```caddyfile
# frontend WAF, inside `handle { … }` before reverse_proxy
header {
    Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; upgrade-insecure-requests"
    Cross-Origin-Opener-Policy same-origin
    Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    X-Frame-Options DENY
    -Server
}
```

Angular needs `style-src 'unsafe-inline'` unless the app sets a CSP nonce
(`ngCspNonce`); test the CSP first as `Content-Security-Policy-Report-Only`.
Set `Cache-Control: no-store` on `/api/*` in the backend.

Grafana (`grafana.ini`), defaults from Grafana 13.2.3 `conf/defaults.ini`:

```yaml
        security:
          cookie_secure: true                       # default false
          cookie_samesite: lax
          strict_transport_security: true           # default false (skip if (c) already sets it)
          strict_transport_security_max_age_seconds: 31536000
          content_security_policy: true             # try content_security_policy_report_only first
          disable_gravatar: true
        auth:
          login_maximum_inactive_lifetime_duration: 1d   # default 7d
          login_maximum_lifetime_duration: 7d            # default 30d
```

`allow_sign_up: false` and `role_attribute_strict: true` (already set) are the
important GitHub settings; keep the default `user:email,read:org` scopes.

---

### SEC-09 — Falco runs privileged and its detections go nowhere actionable

| | |
|---|---|
| Severity | Medium |
| Evidence | `falco/release.yaml:35` (`modern_ebpf`, no `leastPrivileged`), `:64` (Falcosidekick → PolicyReport only); stale `-rc1` comment at `:11` |
| Effort / downtime | 30 min / Falco restart |

**Least privilege.** Two ways to drop `privileged: true`:

| Option | What | Note |
|---|---|---|
| A | `driver.modernEbpf.leastPrivileged: true` | Chart renders `capabilities.add: [BPF, SYS_RESOURCE, PERFMON, SYS_PTRACE]`, plus the deprecated AppArmor *annotation* `…/falco: unconfined` |
| B | Keep `leastPrivileged: false`, set `containerSecurityContext` explicitly | Same capabilities with the current `appArmorProfile` field (a non-empty `containerSecurityContext` replaces the computed one entirely) |

```yaml
    containerSecurityContext:
      capabilities:
        add: [BPF, SYS_RESOURCE, PERFMON, SYS_PTRACE]
      appArmorProfile: {type: Unconfined}
```

**Recommended: B.** Requirements: BPF ring buffer and BTF (kernel ≥ 5.8, which
is also when `CAP_BPF`/`CAP_PERFMON` arrived); Ubuntu's kernel 7.0 qualifies,
though Falco 0.45 on 7.0 in least-privileged mode is not explicitly tested
upstream. The pod still mounts `/proc`, `/etc`, `/sys/kernel` and the containerd
socket directory, so the `falco` namespace stays PSA `privileged`. Verify after
the change that `falcosecurity_falco_rules_matches_total` still increases on a
test event (`kubectl exec` into a pod and `cat /etc/shadow`).

**Alerting.** Falcosidekick has native Alertmanager and Telegram outputs (no
ntfy or Pushover output). Send to Alertmanager so routing, grouping and
silences live in one place (REL-01). The chart's default Alertmanager endpoint
is `/api/v1/alerts`, which Alertmanager ≥ 0.27 rejects with 410, so set v2:

```yaml
    falcosidekick:
      config:
        policyreport: {enabled: true, minimumpriority: notice}
        alertmanager:
          hostport: http://vmalertmanager-victoria-metrics-k8s-stack.monitoring.svc:9093
          endpoint: /api/v2/alerts
          minimumpriority: warning
```

(**verify** the Alertmanager Service name with `kubectl -n monitoring get svc`
once REL-01 is enabled.) Fix the chart comment while there.

---

### SEC-10 — Trivy never scans the most privileged images

| | |
|---|---|
| Severity | Medium |
| Evidence | `gitops/infrastructure/controllers/trivy-operator/release.yaml:32` excludes `kube-system`, `falco`, `csi-proxmox`, `kyverno`, `cert-manager`, `monitoring`, … |
| Effort / downtime | 5 min / none |

**Impact.** Cilium, Falco, the Proxmox CSI node plugin, CoreDNS and Kyverno run
privileged or with host access; a CVE in them is the most dangerous kind on the
node, and nothing reports it.

| Option | What | Cost |
|---|---|---|
| A | Exclude only `kube-public,kube-node-lease,trivy-system` | One extra scan per image per `vulnerabilityScannerReportTTL` (24 h default); config-audit reports for privileged system pods are noisy |
| B | A, and filter the expected config-audit noise in Policy Reporter (`ui.sources[].excludes`) | Same, less noise |
| C | Keep today's list but run `trivy k8s --report summary` weekly from CI | No in-cluster cost, but no continuous reports |

**Recommended: B.** With server mode and `scanJobsConcurrentLimit: 1` the extra
load is a few minutes of one scan job per day.

```yaml
excludeNamespaces: "kube-public,kube-node-lease,trivy-system"
```

---

### SEC-11 — Kyverno: audit-only, deprecated API, unsupported Kubernetes version; no Pod Security Admission

| | |
|---|---|
| Severity | Medium |
| Evidence | `apps/kyverno-policies/*.yaml` (`kyverno.io/v1 ClusterPolicy`, `validationFailureAction: Audit`); `kyverno/release.yaml` (chart 3.9.1 → Kyverno 1.19.1); only `renovate` (restricted) and `kyverno`/`falco` (privileged) carry PSA labels |
| Effort / downtime | ½ day / none if staged |

**Impact.**

- `ClusterPolicy`, `Policy`, `CleanupPolicy` and the legacy `kyverno.io`
  PolicyException are deprecated in Kyverno 1.19 and **removed in 1.20 (expected
  November 2026)** — the two policies stop working on the next minor upgrade.
- Kyverno 1.19 is tested on Kubernetes 1.33–1.35; the cluster runs **1.36**.
- Audit mode blocks nothing, and the `!*:latest` pattern misses untagged images
  (`nginx`) entirely.
- Without PSA labels, nothing at the API level prevents a privileged or
  host-namespace pod in `taskflow`, `monitoring`, `policy-reporter` etc.

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | PSA labels on every namespace (built-in, no webhook) | Zero dependencies, enforced by the API server even when Kyverno is down | Coarse (three levels, per namespace) |
| B | Kyverno 1.19 `ValidatingPolicy` (CEL) for the custom rules, `Audit` → `Deny` | Reports in Policy Reporter, exceptions, background scans | Kyverno must be up for `Deny` to work (webhook) |
| C | Plain Kubernetes `ValidatingAdmissionPolicy` (GA since 1.30) for simple rules | Runs in the API server, no webhook | No PolicyReports (Audit only writes audit-log annotations); no Kyverno CEL libraries |

**Recommended: A + B**, with Kyverno upgraded to the first release that supports
Kubernetes 1.36 after the policies are migrated.

1. PSA labels (dry-run first: `kubectl label --dry-run=server --overwrite ns
   <ns> pod-security.kubernetes.io/enforce=restricted` prints every pod that
   would violate):

   | Namespace | enforce | audit / warn | Why |
   |---|---|---|---|
   | taskflow, abuseipdb, renovate, cloudflared | restricted | restricted | app pods already comply (dry-run to confirm the cert-manager solver pods) |
   | cert-manager, policy-reporter, hubble-ui, flux-system | restricted | restricted | charts/controllers run non-root with RuntimeDefault and drop ALL |
   | monitoring | privileged (or move node-exporter out and use restricted) | baseline | node-exporter needs `hostNetwork`/`hostPID`/hostPath |
   | trivy-system | privileged | restricted | node-collector mounts hostPath (drop to restricted if infra-assessment and compliance scans are disabled) |
   | kube-system, csi-proxmox, falco, kyverno | privileged | — | host access required |

   ```yaml
   metadata:
     labels:
       pod-security.kubernetes.io/enforce: restricted
       pod-security.kubernetes.io/enforce-version: latest
       pod-security.kubernetes.io/audit: restricted
       pod-security.kubernetes.io/warn: restricted
   ```

   Do not add a `Namespace` object for `kube-system` to a pruned Kustomization;
   label it out of band or via a Kustomize patch in a non-pruning Kustomization.
2. Replace the two `ClusterPolicy` files. The image check uses Kyverno's CEL
   image library so digest-pinned refs such as Flux's `…:latest@sha256:…` pass
   and untagged images fail:

   ```yaml
   apiVersion: policies.kyverno.io/v1
   kind: ValidatingPolicy
   metadata: {name: disallow-latest-tag}
   spec:
     validationActions: [Audit]          # → [Deny] after a clean week
     evaluation: {background: {enabled: true}}
     autogen: {podControllers: {controllers: [deployments, statefulsets, daemonsets, jobs, cronjobs]}}
     matchConstraints:
       namespaceSelector:
         matchExpressions:
           - {key: kubernetes.io/metadata.name, operator: NotIn, values: [kube-system, kyverno, flux-system, cert-manager]}
       resourceRules:
         - {apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [pods]}
     variables:
       - name: imgs
         expression: >-
           (object.spec.containers + object.spec.?initContainers.orValue([])
            + object.spec.?ephemeralContainers.orValue([])).map(c, image(c.image))
     validations:
       - expression: variables.imgs.all(i, i.containsDigest() || (i.tag() != '' && i.tag() != 'latest'))
         message: "Pin images by digest or use a non-latest tag."
   ```

   For pod security in Kyverno (in addition to PSA, mainly for reports), use the
   `kyverno-policies` chart 3.9.1 with `policyType: ValidatingPolicy`,
   `podSecurityStandard: restricted`, `validationFailureAction: Audit` and
   `vpolExclude.excludeNamespaces` for the privileged namespaces —
   `ValidatingPolicy` has no `podSecurity` shortcut. Exceptions use
   `policies.kyverno.io/v1 PolicyException` (already enabled in the chart values).
3. Track leftovers with `kyverno_deprecated_api_requests_total`; after upgrading
   to 1.20 run `kyverno migrate`.

**Verify.** Policy Reporter shows the new policies with results; `kubectl run
x --image=nginx -n taskflow` is reported (Audit) and later rejected (Deny);
`kubectl run p --image=busybox --privileged -n taskflow` is rejected by PSA.

---

### SEC-12 — Unsigned images, tag-only third-party images

| | |
|---|---|
| Severity | Medium |
| Evidence | `.github/workflows/build-*.yaml` (no `id-token`, no signing); tag-only images: `postgres:18.6-alpine`, `redis:8.10.2-alpine`, `jaegertracing/jaeger:2.22.0`, both exporters, `favonia/cloudflare-ddns`, `alpine:3.24.2` init container, Falcosidekick, CoreDNS, Caddy and Go base images |
| Effort / downtime | ½ day / none |

**Impact.** A digest says *which* bytes run, not *who* built them. A stolen GHCR
token (or a compromised build) can publish an image that Flux image automation
deploys automatically. Tag-only images can change under the same tag.

**Recommended:**

1. Sign every custom image in CI (here and in the backend/frontend repos):

   ```yaml
   permissions: {contents: read, packages: write, id-token: write}
   steps:
     - uses: sigstore/cosign-installer@<sha>        # v4.1.2 (cosign v3)
     - id: build
       uses: docker/build-push-action@<sha>         # existing step, add:
       with: {provenance: mode=max, sbom: true}
     - env: {DIGEST: "${{ steps.build.outputs.digest }}"}
       run: cosign sign --yes ghcr.io/stefanf81/<image>@${DIGEST}
   ```

   BuildKit's provenance/SBOM attestations are unsigned (useful for inspection,
   not verifiable by Kyverno). For signed SLSA provenance use `actions/attest`
   — on Free/Pro plans only for public repositories. Cosign v3 stores
   signatures as OCI 1.1 referrers in the bundle format; confirm with
   `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com
   --certificate-identity-regexp '^https://github.com/stefanf81/' ghcr.io/stefanf81/<image>@<digest>`.
2. Verify at admission, Audit first:

   ```yaml
   apiVersion: policies.kyverno.io/v1
   kind: ImageValidatingPolicy
   metadata: {name: verify-stefanf81-images}
   spec:
     validationActions: [Audit]
     webhookConfiguration: {timeoutSeconds: 15}
     evaluation: {background: {enabled: true}}
     matchConstraints:
       resourceRules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [pods]}]
     matchImageReferences: [{glob: "ghcr.io/stefanf81/*"}]
     validationConfigurations: {mutateDigest: false, verifyDigest: true, required: true}
     credentials: {secrets: [ghcr-pull]}            # must live in the kyverno namespace
     attestors:
       - name: gha
         cosign:
           keyless:
             identities:
               - issuer: https://token.actions.githubusercontent.com
                 subjectRegExp: '^https://github\.com/stefanf81/[^/]+/\.github/workflows/.+@refs/heads/main$'
           ctlog: {url: https://rekor.sigstore.dev}
     validations:
       - expression: images.containers.map(i, verifyImageSignatures(i, [attestors.gha])).all(e, e > 0)
         message: "Image not signed by a stefanf81 GitHub Actions workflow on main."
   ```

   The policy does not read pod `imagePullSecrets`: copy a GHCR read token into
   the `kyverno` namespace. `mutateDigest: false` because Flux already pins
   digests in Git.
3. Pin the remaining images by digest: Renovate `"pinDigests": true` in a
   `packageRules` entry for `matchManagers: ["kubernetes", "flux", "dockerfile",
   "custom.regex"]` (exclude the two Flux-managed TaskFlow images, as today).

---

### SEC-13 — metrics-server skips kubelet TLS verification

| | |
|---|---|
| Severity | Low |
| Evidence | `gitops/monitoring/platform/metrics-server-release.yaml:38` |
| Effort | 5 min |

k3s signs kubelet serving certificates with `server-ca`, and sets the
controller-manager's `root-ca-file` to the same CA, so the CA bundle mounted
into every pod already verifies kubelets. The kubelet certificates carry the
node's internal IP, matching `--kubelet-preferred-address-types=InternalIP`.
**Simply remove `--kubelet-insecure-tls`** (k3s's own bundled metrics-server runs
that way). To make it explicit:

```yaml
    args:
      - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
      - --kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

Do not mount `/var/lib/rancher/k3s/agent/server-ca.crt` (mode 0600). Verify
with `kubectl top nodes` and no x509 errors in the metrics-server log.

---

### SEC-14 — Small hardening items

**a) `abuseipdb-sync` can rewrite any CiliumCIDRGroup** (`abuseipdb/rbac.yaml:18`).
`create` cannot be restricted by name, but everything else can:

```yaml
rules:
  - apiGroups: [cilium.io]
    resources: [ciliumcidrgroups]
    verbs: [create]
  - apiGroups: [cilium.io]
    resources: [ciliumcidrgroups]
    resourceNames: [abuseipdb]
    verbs: [get, update, patch]
```

Also label the `abuseipdb` namespace `pod-security.kubernetes.io/enforce: restricted`
(the pod already complies).

**b) Stale OAuth secret still deployed** (`policy-reporter/kustomization.yaml:8`).
Remove `policy-reporter-secrets.yaml` from the Kustomization and delete the file
(Flux prunes the Secret), revoke the old app under GitHub → Settings →
Developer settings → OAuth Apps, and fix `gitops/README.md` lines 53, 118, 134.
Check that `policy-reporter-ui-oauth-secrets.yaml` no longer holds the
`PLACEHOLDER` values (`sops -d … | grep -c PLACEHOLDER` should print 0).

**c) Policy Reporter REST API** — see SEC-05.

---

### SEC-15 — No Kubernetes API audit log

| | |
|---|---|
| Severity | Low–Medium |
| Effort / downtime | 30 min / one API-server restart |
| Depends on | REL-00 |

Falco watches syscalls; nothing records who changed what through the API (a
leaked kubeconfig, a compromised controller). k3s runs the API server in-process
and takes `kube-apiserver-arg` from `config.yaml`:

```bash
sudo install -d -m 700 /var/lib/rancher/k3s/server/logs
sudo tee /var/lib/rancher/k3s/server/audit.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:                                   # first match wins
  - level: None
    nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version", "/metrics", "/openapi/*"]
  - level: None
    resources:
      - {group: "", resources: ["events"]}
      - {group: "events.k8s.io"}
      - {group: "coordination.k8s.io", resources: ["leases"]}
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver",
            "system:k3s-supervisor", "system:k3s-controller"]
    verbs: ["get", "list", "watch"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
  - level: Metadata                      # never log Secret/ConfigMap bodies
    resources: [{group: "", resources: ["secrets", "configmaps", "serviceaccounts/token"]}]
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - {group: "rbac.authorization.k8s.io"}
      - {group: "policy"}
      - {group: "admissionregistration.k8s.io"}
      - {group: "networking.k8s.io", resources: ["networkpolicies"]}
      - {group: "cilium.io"}
  - level: Metadata
    resources: [{group: "", resources: ["pods/exec", "pods/attach", "pods/portforward"]}]
  - level: Metadata
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
  - level: None
EOF
```

```yaml
# /etc/rancher/k3s/config.yaml
kube-apiserver-arg:
  - audit-policy-file=/var/lib/rancher/k3s/server/audit.yaml
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxage=14
  - audit-log-maxbackup=5
  - audit-log-maxsize=50
```

An invalid policy stops the API server from starting: keep an SSH session open
and validate with `sudo k3s check-config`-style dry runs (or by watching
`journalctl -u k3s -f`) during the restart. To search the log in Grafana, tail
it with Alloy (`loki.source.file`, requires the DaemonSet variant in PERF-10).

---

### SEC-16 — Provisioning-layer hygiene (low)

| Item | Evidence | Fix |
|---|---|---|
| Terraform uses a `root@pam` token and root SSH | `providers.tf:15,19`, `terraform.tfvars.example` | Create `terraform@pve` with a custom role (VM.*, Datastore.Allocate*, Datastore.Audit, Sys.Audit, SDN.Use) and an API token with privilege separation. The bpg provider still needs SSH for snippet uploads; use a dedicated user with write access to the snippets directory where possible. |
| Proxmox CSI token scope | encrypted in `proxmox-csi-secrets.yaml` | **Verify** it is a dedicated user with only the CSI privileges from the plugin README (`VM.Audit`, `VM.Config.Disk`, `Datastore.Allocate`, `Datastore.AllocateSpace`, `Datastore.Audit`), not root. |
| `curl https://get.k3s.io \| sh` | `modules/proxmox/main.tf:87` | Download `install.sh` from the pinned k3s tag (`https://raw.githubusercontent.com/k3s-io/k3s/<tag>/install.sh`) and check its SHA-256 in cloud-init; the script then verifies the binary checksum itself. |
| SSH host key not verified | `modules/k3s-kubeconfig/main.tf:30` | Inject a pre-generated host key through cloud-init `ssh_keys:` and use a `known_hosts` file instead of `StrictHostKeyChecking=no`. |

---

### SEC-17 — Backend private key in environment and heap dumps (low)

`backend.yaml:101` passes the RSA private key as an env var and the JVM writes
heap dumps to `/tmp` on OOM. Env vars are inherited by child processes and
visible in `/proc/1/environ` to anyone who can exec; a heap dump contains the
key, the DB password and session data, and stays on the node until the pod is
deleted.

Options: mount the Secret as files (`defaultMode: 0400`) and load it with
Spring's `spring.config.import=optional:configtree:/run/secrets/` (file names
must match the property names the app binds — **verify** in the backend repo);
and either keep heap dumps but give `/tmp` a `sizeLimit` (PERF-07) and delete
dumps after analysis, or drop `-XX:+HeapDumpOnOutOfMemoryError` in production
and enable it only while debugging.

---

## 4. Reliability

### REL-00 — Node configuration: flag precedence and the cloud-init re-run hazard

| | |
|---|---|
| Severity | High (precondition for every node change) |
| Evidence | `modules/proxmox/main.tf:87` (all flags on the installer command line), `:142` (`user_data_file_id`), `:154` (`ignore_changes` without it); `README.md` §6 tells you to add `disable: [coredns]` to `config.yaml` |
| Effort / downtime | 30 min / one k3s restart (pods keep running: the unit uses `KillMode=process`) |

**Problem 1 — command-line flags override `config.yaml`.** For repeatable flags
(`--disable`, `--kubelet-arg`, `--node-label`), the command-line list *replaces*
the YAML list. The installer wrote every flag into the systemd unit's
`ExecStart`, so on the live node a `disable: [coredns]` (README §6) or any
`kubelet-arg:` added to `config.yaml` is silently ignored. **Verify now**:

```bash
systemctl cat k3s | grep -A3 ExecStart
sudo cat /etc/rancher/k3s/config.yaml
kubectl -n kube-system get deploy,helmchart -o wide | grep -i coredns   # one CoreDNS only?
```

Fix: move everything into `config.yaml` and reduce `ExecStart` to `k3s server`.
The `disable:` list must be complete — listing only `coredns` would re-deploy
traefik, servicelb, metrics-server and local-storage:

```yaml
# /etc/rancher/k3s/config.yaml
tls-san: [192.168.50.55]
disable: [servicelb, traefik, coredns, metrics-server, local-storage]
flannel-backend: none
disable-network-policy: true
node-label:
  - topology.kubernetes.io/region=homelab
  - topology.kubernetes.io/zone=<proxmox-node>
kubelet-arg:
  - system-reserved=cpu=200m,memory=500Mi
  - kube-reserved=cpu=200m,memory=500Mi
```

```bash
sudo systemctl edit --full k3s     # ExecStart=/usr/local/bin/k3s server
sudo systemctl daemon-reload && sudo systemctl restart k3s
```

**Problem 2 — editing the cloud-init snippet in Terraform is dangerous.**
In bpg/proxmox v0.116 both the snippet's `source_raw.data` and the VM's
`initialization.user_data_file_id` are ForceNew: changing the k3s flags in
Terraform plans a **VM replacement**. Worse, Proxmox derives the NoCloud
instance-id from a hash of the user data, so after a snippet change the next
Proxmox-side stop/start can make cloud-init treat the VM as new and re-run
`runcmd` — re-installing k3s at the *old* pinned version with the old flags
(a downgrade after SUC upgrades, and an overwritten unit). A reboot from inside
the guest (kured) does not restart QEMU and should not trigger it.

Fix:

```hcl
# modules/proxmox/main.tf
lifecycle {
  ignore_changes = [tags, initialization[0].user_account, network_device[0].mac_address,
                    initialization[0].user_data_file_id]
}
```

```bash
# on the running node: never let cloud-init run the installer again
sudo touch /etc/cloud/cloud-init.disabled
```

For future nodes, have cloud-init `write_files` the `config.yaml`, kubelet
drop-ins and `audit.yaml`, and run the installer with only `server`.

---

### REL-01 — No alerting

| | |
|---|---|
| Severity | High |
| Evidence | `monitoring/platform/release.yaml:33,35` (`vmalert`/`alertmanager` disabled); no Flux `Provider`/`Alert`; Falcosidekick → PolicyReport only |
| Effort / downtime | 3–4 h / none |

**Impact.** A reboot, full disk, expiring certificate, failed reconciliation,
crash-looping backend or Falco critical event produces no signal. Dashboards
are only useful when someone looks.

**Receiver options**

| Option | Alertmanager | Flux | Falcosidekick | healthchecks.io | Notes |
|---|---|---|---|---|---|
| ntfy (ntfy.sh or self-hosted) | via webhook + `?template=alertmanager` (ntfy ≥ 2.14) | via `generic` provider (untested) | via Alertmanager | native | Free, no account; on ntfy.sh a long random topic is the password (or self-host with `auth-default-access: deny-all` + token) |
| Telegram | native `telegram_configs` | native | native | native | Only option native everywhere |
| Pushover | native (priority 2 repeats until acknowledged) | — | via Alertmanager | native | $4.99 one-time; breaks through Do Not Disturb |

**Recommended:** Alertmanager → ntfy (or Telegram if you want everything
native), Watchdog → healthchecks.io dead-man's switch, Flux and Falco →
Alertmanager, plus one external probe.

1. Enable vmalert and Alertmanager (chart 0.96.0 wires vmalert's datasource,
   remote read/write and notifiers automatically). Receiver URLs and tokens go
   in a SOPS Secret mounted through `spec.secrets` (`/etc/vm/secrets/<name>/`):

   ```yaml
       kubeEtcd: {enabled: false}
       kubeScheduler: {enabled: false}
       kubeControllerManager: {enabled: false}
       defaultRules:
         rules:
           CPUThrottlingHigh: {enabled: false}   # re-enable once PERF-02 is done
       vmalert:
         enabled: true
         spec:
           evaluationInterval: 30s
           resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {memory: 256Mi}}
       alertmanager:
         enabled: true
         spec:
           secrets: [am-receivers]                # keys: hc-url, ntfy-url, ntfy-token
           resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
           storage:                               # keep silences across restarts
             volumeClaimTemplate:
               spec:
                 storageClassName: proxmox-csi
                 resources: {requests: {storage: 512Mi}}
         config:
           route:
             receiver: phone
             group_by: [alertname, namespace]
             routes:
               - matchers: ['alertname="Watchdog"']
                 receiver: deadman
                 group_wait: 0s
                 group_interval: 1m
                 repeat_interval: 2m
               - matchers: ['alertname="InfoInhibitor"']
                 receiver: blackhole
           receivers:
             - name: blackhole
             - name: deadman
               webhook_configs:
                 - url_file: /etc/vm/secrets/am-receivers/hc-url      # https://hc-ping.com/<uuid>
                   send_resolved: false
             - name: phone
               webhook_configs:
                 - url_file: /etc/vm/secrets/am-receivers/ntfy-url    # https://ntfy.sh/<topic>?template=alertmanager
                   http_config:
                     authorization:
                       credentials_file: /etc/vm/secrets/am-receivers/ntfy-token
   ```

   The default rule set already covers `KubePodCrashLooping`,
   `KubeDeploymentReplicasMismatch`, `KubePersistentVolumeFillingUp`,
   `NodeFilesystemSpaceFillingUp`, `TargetDown` and VMSingle disk alerts.
2. Dead-man's switch: a healthchecks.io check (period 5 min, grace 5 min) with
   its own phone integration. The always-firing `Watchdog` pings it every 2 min;
   when the node, VMSingle, vmalert or Alertmanager dies, the pings stop and
   healthchecks pages you.
3. Cluster-specific rules:

   ```yaml
   apiVersion: operator.victoriametrics.com/v1beta1
   kind: VMRule
   metadata: {name: homelab-extra, namespace: monitoring}
   spec:
     groups:
       - name: homelab
         rules:
           - alert: CertExpiringSoon
             expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
             for: 1h
             labels: {severity: warning}
           - alert: CertNotReady
             expr: certmanager_certificate_ready_status{condition="False"} == 1
             for: 15m
             labels: {severity: warning}
           - alert: HostDiskLow
             expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.15
             for: 15m
             labels: {severity: critical}
           - alert: FalcoCritical          # priority 0–2 = emergency..critical
             expr: sum by (rule_name) (increase(falcosecurity_falco_rules_matches_total{priority=~"[0-2]"}[5m])) > 0
             labels: {severity: critical}
           - alert: FluxNotReady           # needs the kube-state-metrics custom-resource config below
             expr: gotk_resource_info{ready="False", suspended!="true"} == 1
             for: 15m
             labels: {severity: warning}
   ```

   Flux no longer exports `gotk_reconcile_condition`; its documented replacement
   is kube-state-metrics custom-resource-state producing `gotk_resource_info`
   (`fluxcd/flux2-monitoring-example`, `kube-state-metrics-config.yaml`). Merge
   its `rbac.extraRules` and `customResourceState` into the stack's
   `kube-state-metrics:` values, but do **not** copy `collectors: []` or
   `--custom-resource-state-only=true` (that would remove the core metrics the
   default rules use).
4. Flux events → Alertmanager (Provider/Alert are `notification.toolkit.fluxcd.io/v1beta3`;
   there is no native ntfy/Pushover provider):

   ```yaml
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Provider
   metadata: {name: alertmanager, namespace: flux-system}
   spec:
     type: alertmanager
     address: http://vmalertmanager-victoria-metrics-k8s-stack.monitoring.svc:9093/api/v2/alerts/
   ---
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Alert
   metadata: {name: flux-errors, namespace: flux-system}
   spec:
     providerRef: {name: alertmanager}
     eventSeverity: error
     eventSources:
       - {kind: GitRepository, name: '*'}
       - {kind: Kustomization, name: '*'}
       - {kind: HelmRelease, name: '*', namespace: kube-system}
       - {kind: HelmRelease, name: '*', namespace: monitoring}
       # … one HelmRelease entry per namespace that has releases
   ```

   Flux alerts carry no `EndsAt`, so set Alertmanager's `resolve_timeout` (e.g.
   `global: {resolve_timeout: 1h}`). The `monitoring` namespace is
   ingress-default-deny for other namespaces (`platform/network-policies.yaml`),
   so admit the two senders explicitly:

   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata: {name: allow-alert-senders, namespace: monitoring}
   spec:
     endpointSelector: {matchLabels: {app.kubernetes.io/name: vmalertmanager}}   # verify pod labels
     ingress:
       - fromEndpoints:
           - matchLabels: {k8s:io.kubernetes.pod.namespace: flux-system, app: notification-controller}
           - matchLabels: {k8s:io.kubernetes.pod.namespace: falco, app.kubernetes.io/name: falcosidekick}
         toPorts: [{ports: [{port: "9093", protocol: TCP}]}]
   ```
5. External probe (same failure domain problem: anything in-cluster dies with
   the node): Grafana Cloud Synthetic Monitoring (free tier covers a 1-minute
   HTTP + TLS-expiry check from two probes) or UptimeRobot (free, 5-minute
   interval). Cloudflare Health Checks need a paid plan.
6. Optional: a Flux `Receiver` (type `github`, `v1`) behind an HTTPRoute that
   exposes only `/hook/` so pushes reconcile immediately; the payload is
   HMAC-verified, but every request costs an API call, so rate-limit it.

**Verify.** `kubectl -n monitoring get vmalert,vmalertmanager`; the healthchecks
check turns green; `kubectl -n default run crash --image=busybox -- false`
produces a `KubePodCrashLooping` push within ~15 min; delete it.

---

### REL-02 — No backups

| | |
|---|---|
| Severity | High |
| Evidence | No backup tooling anywhere in `gitops/`; `proxmox-csi/release.yaml` (`reclaimPolicy: Retain` is not a backup); `docs/PERFORMANCE.md` §1.3 says backups are "handled natively at the hypervisor", but the Proxmox CSI plugin attaches PV disks with `backup=false` by default (`pkg/csi/parameters.go`) and calls `backup: true` a "dangerous option" — **Proxmox VM backups contain none of the PVC data** |
| Effort / downtime | Stopgap 1 h / none; CloudNativePG migration ½ day / dump + restore time (minutes at this size) |

**Impact.** A bad Flyway migration, an accidental `DELETE`, a deleted PVC, a
failed disk or ransomware on the Proxmox host loses every booking and user
account. There is also no copy of the keys needed to rebuild the cluster from
Git (SOPS age key, k3s token, secrets-encryption config).

**What to back up, and where**

| Data | Tool | Target |
|---|---|---|
| Postgres (`taskflow`) | stopgap: `pg_dump` CronJob; target: CloudNativePG + barman-cloud plugin (WAL archiving, PITR) | R2/B2 bucket, encrypted |
| Grafana PVC (dashboards in Git, but users/preferences/API keys in sqlite) | VolSync restic (`copyMethod: Direct`) or k8up | Same bucket, separate prefix |
| Loki, VMSingle, Alloy WAL, Trivy cache | Usually none (rebuildable telemetry); back up only if history matters | — |
| SOPS age key, k3s server token, `encryption-config.json`, Terraform state | Manual, offline | Password manager |
| VM (OS, k3s datastore) | Proxmox Backup Server with client-side encryption | PBS (keep the key off the host) |

**Postgres options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Nightly `pg_dump` CronJob → rclone crypt → R2 | Small, independent of the database deployment | RPO 24 h; restore = full reload |
| B | CloudNativePG 1.30.1 (chart 0.29.1), one instance, barman-cloud plugin v0.15.1 (chart 0.8.1) | Continuous WAL archiving (RPO ≈ `archive_timeout`, 5 min), point-in-time recovery, scheduled base backups, superuser disabled, app/monitoring roles, built-in metrics; what all five reference repos run | Operator + plugin to run; one migration window |
| C | Proxmox snapshots of the PV disk (CSI `VolumeSnapshot`) | — | Experimental in the plugin, requires `root@pam`, each snapshot is a full copy, not crash-consistent for a running database; not a substitute |

**Recommended: A this week, B within the month.** The in-tree
`barmanObjectStore` is deprecated and planned for removal in CNPG 1.31.0, so use
the plugin from day one.

#### A — stopgap `pg_dump` CronJob

Ready-made images lag behind (the common `postgres-backup-s3` image stops at
PG 16, and `pg_dump` cannot dump a newer server), so build it from the server's
own image plus rclone:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: {name: pg-dump-r2, namespace: taskflow}
spec:
  schedule: "30 2 * * *"
  timeZone: Europe/Brussels
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata:
          labels: {app: pg-backup, app.kubernetes.io/name: pg-backup, app.kubernetes.io/part-of: taskflow}
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, seccompProfile: {type: RuntimeDefault}}
          volumes: [{name: work, emptyDir: {sizeLimit: 2Gi}}]
          initContainers:
            - name: dump
              image: postgres:18.6-alpine          # same major as the server
              command: ["sh", "-c", "pg_dump -h db -U postgres -Fc -Z zstd:6 -f /work/taskflow-$(date -u +%Y%m%dT%H%M%SZ).dump taskflow"]
              env:
                - name: PGPASSWORD
                  valueFrom: {secretKeyRef: {name: db-secret, key: POSTGRES_PASSWORD}}
              securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
              volumeMounts: [{name: work, mountPath: /work}]
          containers:
            - name: upload
              image: rclone/rclone:1.75.2            # verify the current tag, pin the digest
              args: ["copy", "/work", "r2crypt:"]
              envFrom: [{secretRef: {name: rclone-r2}}]
              securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
              volumeMounts: [{name: work, mountPath: /work}]
```

`rclone-r2` (SOPS): `RCLONE_CONFIG_R2_TYPE=s3`, `…_PROVIDER=Cloudflare`,
`…_ENDPOINT=https://<account>.r2.cloudflarestorage.com`, `…_REGION=auto`,
`…_NO_CHECK_BUCKET=true`, `…_ACCESS_KEY_ID`, `…_SECRET_ACCESS_KEY`, and
`RCLONE_CONFIG_R2CRYPT_TYPE=crypt`, `…_REMOTE=r2:homelab-backups/pg-dumps`,
`…_PASSWORD=<rclone obscure output>`. Retention: an R2 lifecycle rule on the
prefix (e.g. delete after 30 days).

Two cluster-specific gotchas:

- `restrict-db-access` (`network-policy.yaml`) admits only the backend and the
  exporter to port 5432. Add `app: pg-backup` to its `from` list, or the dump
  times out.
- With SEC-04 egress policies in place, the backup pod needs DNS and
  `toFQDNs: <account>.r2.cloudflarestorage.com:443`.

Alert on it (REL-01): `kube_cronjob_status_last_successful_time{cronjob="pg-dump-r2"}`
older than 26 h. Test the restore monthly:
`createdb restoretest && pg_restore --no-owner -d restoretest <file>` and compare
row counts.

#### B — CloudNativePG with barman-cloud

1. Install the operator (namespace `cnpg-system`) and the barman-cloud plugin in
   the same namespace (it needs cert-manager, already present).
2. Object store and cluster (values are strings; `shared_preload_libraries`,
   `archive_*`, `listen_addresses`, `ssl*` and logging are operator-managed and
   rejected; `pg_stat_statements` is preloaded automatically):

   ```yaml
   apiVersion: barmancloud.cnpg.io/v1
   kind: ObjectStore
   metadata: {name: r2, namespace: taskflow}
   spec:
     retentionPolicy: "30d"
     configuration:
       destinationPath: s3://homelab-pg/
       endpointURL: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
       s3Credentials:
         accessKeyId: {name: r2-pg, key: ACCESS_KEY_ID}
         secretAccessKey: {name: r2-pg, key: ACCESS_SECRET_KEY}
       wal: {compression: zstd}
       data: {compression: gzip}          # zstd is WAL-only
     instanceSidecarConfiguration:
       resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {memory: 128Mi}}
   ---
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata: {name: taskflow-pg, namespace: taskflow}
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie
     enablePDB: false                     # a single-instance PDB blocks node drains
     storage: {storageClass: proxmox-csi, size: 10Gi}
     resources: {requests: {cpu: 500m, memory: 1Gi}, limits: {memory: 1Gi}}
     postgresql:
       parameters:
         shared_buffers: 384MB
         effective_cache_size: 700MB
         work_mem: 8MB
         maintenance_work_mem: 64MB
         max_connections: "50"
         random_page_cost: "1.1"
         effective_io_concurrency: "200"
         wal_compression: zstd
         max_wal_size: 2GB
         checkpoint_timeout: 15min
         jit: "off"
         track_io_timing: "on"
         # synchronous_commit: see REL-04 (default "on")
     managed:
       services:
         disabledDefaultServices: ["ro", "r"]
     bootstrap:
       initdb:
         database: taskflow
         owner: taskflow
         import:
           type: microservice
           databases: [taskflow]
           source: {externalCluster: legacy}
     externalClusters:
       - name: legacy
         connectionParameters: {host: db, user: postgres, dbname: postgres, sslmode: disable}
         password: {name: db-secret, key: POSTGRES_PASSWORD}
     plugins:
       - name: barman-cloud.cloudnative-pg.io
         isWALArchiver: true
         parameters: {barmanObjectName: r2}
   ---
   apiVersion: postgresql.cnpg.io/v1
   kind: ScheduledBackup
   metadata: {name: taskflow-pg-daily, namespace: taskflow}
   spec:
     schedule: "0 30 2 * * *"             # six fields, seconds first
     backupOwnerReference: self
     immediate: true
     cluster: {name: taskflow-pg}
     method: plugin
     pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
   ```

   The import runs `pg_dump -Fd` against the old server and `pg_restore
   --no-owner --no-acl` into `taskflow`, so every object ends up owned by the
   `taskflow` role (this also closes SEC-03), roles are not copied, and all
   indexes are rebuilt (which avoids carrying musl collation quirks from the
   Alpine image to the glibc-based CNPG image). The dump is staged in the new
   PVC, so size it for data + dump.
3. Cut-over (an offline import — writes after the dump starts are lost):
   scale the backend to 0 → apply the Cluster → `kubectl cnpg status
   taskflow-pg` and compare row counts → switch the backend to the
   `taskflow-pg-app` Secret (`username`, `password`, `jdbc-uri`) and host
   `taskflow-pg-rw` → scale up → confirm the first backup completed.
4. Network policies: the new pods carry `cnpg.io/cluster: taskflow-pg`; extend
   `restrict-db-access` (backend → 5432, monitoring → 9187 metrics) and allow
   the instance egress to the R2 endpoint and the Kubernetes API (the instance
   manager talks to it). Replace postgres-exporter with a `PodMonitor` on port
   `metrics` (`monitoring.enablePodMonitor` is deprecated) — vmagent converts
   PodMonitors.
5. Keep the old Deployment at `replicas: 0` and annotate its PVC
   `kustomize.toolkit.fluxcd.io/prune: disabled` until the new cluster has run
   for a few weeks; a pruned PVC leaves a `Released` PV that needs a manual
   `claimRef` fix to reattach.

Restore / point-in-time recovery goes into a **new** Cluster with
`bootstrap.recovery` (`source: origin`, optional `recoveryTarget.targetTime`)
and an `externalClusters` entry using the plugin with
`serverName: taskflow-pg`; give the new cluster a different `serverName` for its
own archive or it fails with "Expected empty archive". Alert on
`barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` and on a
growing `cnpg_collector_pg_wal_archive_status{value="ready"}` (failed archiving
fills the PVC with WAL).

R2 notes: region is `auto`; R2 requires equal-sized multipart parts — it is not
confirmed whether barman-cloud trips over that, so do a full backup **and a
restore drill** before relying on it (B2 is the fallback).

#### PVC backups (Grafana and anything else stateful)

| Option | Needs VolumeSnapshots | Maturity | Note |
|---|---|---|---|
| VolSync 0.16 (restic mover, `copyMethod: Direct`) | Docs list the snapshot controller as a prerequisite even for `Direct`; no VolumeSnapshotClass needed | Mature | One explicit `ReplicationSource` per PVC |
| k8up 2.16 (restic) | No | Mature | Backs up every PVC in a namespace unless annotated; `k8up.io/backupcommand` for app-aware dumps |
| kopiur 0.10 (Kopia) | `Direct` mode works without | Alpha (`v1alpha1`, created June 2026) | What the reference repos run; restore-on-create via `dataSourceRef` |

**Recommended: VolSync restic `Direct`** (install the external-snapshotter CRDs
and controller v8.7.0 to satisfy its prerequisite), or k8up if you prefer no CSI
dependencies. Revisit kopiur when it leaves alpha.

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata: {name: grafana, namespace: monitoring}
spec:
  sourcePVC: victoria-metrics-k8s-stack-grafana     # verify the PVC name
  trigger: {schedule: "15 3 * * *"}
  restic:
    repository: grafana-restic                      # SOPS Secret: RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_*
    copyMethod: Direct
    pruneIntervalDays: 14
    retain: {daily: 7, weekly: 4, monthly: 3}
    moverSecurityContext: {runAsUser: 472, runAsGroup: 472, fsGroup: 472}
```

#### VM-level backups

Keep Proxmox Backup Server for the VM itself (OS, k3s datastore), in `snapshot`
mode with the guest agent's fs-freeze, and turn on PBS client-side encryption
(keep the key off the Proxmox host). Remember it holds the k3s datastore and,
until SEC-02 and even after it, the keys to decrypt it — treat PBS as sensitive.
Correct `docs/PERFORMANCE.md` §1.3.

**Verify.** One successful run of each job; a restore drill into a scratch
namespace; alerts fire when a backup is older than its schedule allows.

---

### REL-03 — Postgres probes can kill crash recovery

| | |
|---|---|
| Severity | High (data availability) |
| Evidence | `gitops/apps/taskflow/postgres-db.yaml:124-129` (`initialDelaySeconds: 2`, `periodSeconds: 3`, `failureThreshold: 10`); exec probes without `timeoutSeconds` default to **1 s** |
| Effort / downtime | 5 min / one Postgres restart |

**Impact.** After an unclean stop (node crash, OOM kill, power loss),
Postgres replays WAL and `pg_isready` reports "rejecting connections" for the
whole replay. With up to `max_wal_size=2GB` of WAL the replay can exceed the
~32 s startup budget; the kubelet kills Postgres, which starts the replay again,
in a loop. Separately, a 1-second exec timeout on liveness can restart a
healthy but busy database during a checkpoint or vacuum.

**Recommended:**

```yaml
      terminationGracePeriodSeconds: 60   # room for the shutdown checkpoint
      containers:
        - name: postgres
          startupProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 120   # 10 min for crash recovery
          livenessProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 4
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "postgres"]}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 2
```

Liveness only starts after the startup probe succeeds, so the long startup
budget costs nothing in normal operation. Apply the same `timeoutSeconds: 3–5`
to the Redis exec probes (`redis.yaml`), which have the same 1-second default.

---

### REL-04 — `synchronous_commit=off` on a booking database

| | |
|---|---|
| Severity | Medium (product decision) |
| Evidence | `gitops/apps/taskflow/postgres-db.yaml:75-82` |

**Impact.** With `off`, a commit is acknowledged before its WAL reaches disk.
An unclean stop can lose up to ~600 ms (3 × `wal_writer_delay`) of transactions
that users already saw as confirmed. There is no corruption risk. The manifest
comment justifies it with replicas, which is wrong: `on` protects the *local*
commit.

| Option | Durability | Latency |
|---|---|---|
| A — keep `off`, fix the comment, document the RPO | Last ~0.6 s can vanish | Lowest |
| B — `on` (the default) | Committed means on disk | +1 fsync per write transaction; on local SSD-backed LVM-thin usually ≤ 1–2 ms |
| C — `on` globally, `SET LOCAL synchronous_commit = off` in the app for non-critical writes (audit/log tables) | Bookings durable, bulk writes fast | App change |

**Recommended: B** for appointments, then measure: with `track_wal_io_timing=on`
(PERF-04) `pg_stat_io` shows the fsync cost; if it matters, move to C.

---

### REL-05 — One five-name certificate issued over HTTP-01

| | |
|---|---|
| Severity | Medium |
| Evidence | `apps/taskflow/certificate.yaml:8` (5 SANs), `infrastructure/configs/letsencrypt-http01-issuers.yaml` (HTTP-01 via `gatewayHTTPRoute`), `cert-manager/release.yaml:36` (`--enable-gateway-api`) |
| Effort / downtime | 1 h / none (the Gateway picks up the new Secret) |

**Impact.** A failed challenge for one name (e.g. `kyverno.` without a DNS
record) blocks renewal for all five, including `www.`. HTTP-01 needs port 80
reachable from the internet and depends on the CoreDNS hairpin override for the
self-check. RSA-2048 is the default key.

**Options:** (A) per-hostname certificates over HTTP-01; (B) one wildcard over
DNS-01 (what all five reference repos do); (C) B with Let's Encrypt's
`shortlived` profile (160-hour certificates, GA since January 2026, opt-in).

**Recommended: B** (C optional once alerting is in place):

1. Cloudflare API token with `Zone:DNS:Edit` and `Zone:Zone:Read`, limited to
   `jokelab.dev`, stored as a SOPS Secret `cloudflare-api-token` (key
   `api-token`) in the `cert-manager` namespace (ClusterIssuers read Secrets
   from there).
2. Issuers and Helm values:

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata: {name: letsencrypt-dns01-production}
   spec:
     acme:
       server: https://acme-v02.api.letsencrypt.org/directory
       email: <email>
       privateKeySecretRef: {name: letsencrypt-dns01-production-key}
       # profile: shortlived
       solvers:
         - selector: {dnsZones: [jokelab.dev]}
           dns01:
             cloudflare:
               apiTokenSecretRef: {name: cloudflare-api-token, key: api-token}
   # (+ an identical staging issuer against acme-staging-v02)
   ```

   ```yaml
   # cert-manager HelmRelease values
   dns01RecursiveNameservers: "https://1.1.1.1/dns-query,https://1.0.0.1/dns-query"
   dns01RecursiveNameserversOnly: true
   # remove extraArgs: --enable-gateway-api (only needed for HTTP-01 gatewayHTTPRoute
   # or Gateway annotations; v1.21's replacement is config.gatewayAPI.enabled)
   ```

   DNS-over-HTTPS for the propagation check avoids the router/CoreDNS
   split-horizon answers.
3. Wildcard certificate and listener:

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata: {name: jokelab-wildcard, namespace: taskflow}
   spec:
     secretName: jokelab-wildcard-tls
     issuerRef: {kind: ClusterIssuer, name: letsencrypt-dns01-production}
     dnsNames: [jokelab.dev, "*.jokelab.dev"]
     privateKey: {algorithm: ECDSA, size: 256}   # rotationPolicy: Always is the default since v1.18
   ```

   Point the Gateway's `https` listener at `jokelab-wildcard-tls`. Once it is
   `Ready`, delete the old Certificate, the HTTP-01 issuers, the
   `allow-cert-manager-solver` NetworkPolicy and (with SEC-01) the CoreDNS
   `hosts` override.

**Verify.** `kubectl -n taskflow get certificate jokelab-wildcard` is `Ready`;
`openssl s_client -connect www.jokelab.dev:443 -servername www.jokelab.dev
</dev/null | openssl x509 -noout -text | grep -E 'Public Key Algorithm|DNS:'`
shows `id-ecPublicKey` and `*.jokelab.dev`.

**Rollback.** Point the listener back at `taskflow-tls-secret` (keep the old
Certificate until the new one has renewed once).

---

### REL-06 — Flux image controllers not in Git; repetitive release settings

| | |
|---|---|
| Severity | Medium |
| Evidence | `gotk-components.yaml:4` lists four controllers (image-reflector/automation installed by hand, `FLUX_BOOTSTRAP.md` §7.4); 16 `HelmRepository` objects; every HelmRelease repeats install/upgrade remediation blocks |
| Effort / downtime | ½ day / none (the operator adopts the running controllers) |

**Impact.** A re-bootstrap silently drops image automation; Flux itself can only
be upgraded by regenerating a manifest by hand (Renovate is configured to
ignore it).

**Options:** (A) regenerate `gotk-components.yaml` with
`flux install --components-extra=image-reflector-controller,image-automation-controller --export`;
(B) **Flux Operator** (v0.61.0) with a `FluxInstance` — what all five reference
repos run.

**Recommended: B.**

```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator -n flux-system
```

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata: {name: flux, namespace: flux-system}
spec:
  distribution: {version: "2.9.x", registry: ghcr.io/fluxcd}
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster: {type: kubernetes, networkPolicy: true, domain: cluster.local}
  sync:
    kind: GitRepository
    url: https://github.com/stefanf81/homelab-TF.git
    ref: refs/heads/main
    path: gitops/clusters/taskflow
    pullSecret: flux-system
```

The operator strips the bootstrap's Kustomize ownership labels, takes over field
ownership and marks objects `prune: Disabled`, so applying the `FluxInstance`
does not delete the running install (the manually installed image controllers
are adopted too). Then: check `kubectl -n flux-system get fluxinstance flux`
is Ready and `flux trace kustomization flux-system` reports it is no longer
managed by the old Kustomization → delete `gitops/clusters/taskflow/flux-system/`
**and** the `- flux-system` entry in `gitops/clusters/taskflow/kustomization.yaml`
→ optionally manage the operator itself with an `OCIRepository` + `HelmRelease`.
Rollback before the deletion step: annotate the instance
`fluxcd.controlplane.io/reconcile=disabled` and re-apply
`kubectl apply -k gitops/clusters/taskflow/flux-system`.

Follow-ups once the operator runs:

- **OCI chart sources** (`OCIRepository` + HelmRelease `chartRef`; layerSelector
  `application/vnd.cncf.helm.chart.content.v1.tar+gzip`): available for cilium
  (`oci://quay.io/cilium/charts/cilium`), cert-manager
  (`oci://quay.io/jetstack/charts/cert-manager`), coredns
  (`oci://ghcr.io/coredns/charts/coredns`), kyverno and policy-reporter
  (`oci://ghcr.io/kyverno/charts/…`), falco (`oci://ghcr.io/falcosecurity/charts/falco`),
  oauth2-proxy (`oci://ghcr.io/oauth2-proxy/charts/oauth2-proxy`),
  renovate-operator (`oci://ghcr.io/mogenius/helm-charts/renovate-operator`),
  victoria-metrics (`oci://ghcr.io/victoriametrics/helm-charts/…`), loki
  (`oci://ghcr.io/grafana-community/helm-charts/loki`) and the polr adapter
  (`oci://ghcr.io/fjogeleit/charts/…`). Keep `HelmRepository` for
  **trivy-operator** (its OCI copy is stale: 0.32.1 vs 0.37.0), **metrics-server**
  and **alloy** (no official OCI).
- Central HelmRelease defaults (`install/upgrade.strategy`, remediation,
  `crds`) via a Kustomize patch in each cluster Kustomization instead of
  repeating them in every release, as onedr0p does.
- Controller tuning via `kustomize.patches` (e.g. `--concurrent`) only if
  reconciliation is slow; at this size the defaults are fine.

---

### REL-07 — WAF config changes need a manual restart

| | |
|---|---|
| Severity | Low–Medium (silent drift) |
| Evidence | `gitops/apps/taskflow/backend-waf.yaml:1` and `frontend-waf.yaml:1` ("MANUAL RELOAD REQUIRED") |

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Kustomize `configMapGenerator` (content-hash suffix) | No extra controller; every edit rolls the WAF automatically; old ConfigMaps pruned by Flux | Inline Caddyfile moves to files; the CI scripts that read `*-waf.yaml` (`tests/gen-config.py`, `validate-configs.sh`) need updating |
| B | stakater/Reloader with explicit annotations | Also covers Secret rotation (backlog #5); used by all five reference repos | One more controller with cluster-wide watch on ConfigMaps (and Secrets unless disabled) |
| C | Checksum annotation updated by hand or CI | Nothing new | Easy to forget — the current problem |

**Recommended: B**, scoped tightly:

```yaml
# HelmRelease values (chart stakater/reloader; verify key names against the chart's values.yaml)
reloader:
  reloadStrategy: annotations     # patch a pod-template annotation, no env var churn
  ignoreSecrets: false            # set true if only ConfigMaps should trigger
  watchGlobally: true
  deployment:
    resources:
      requests: {cpu: 10m, memory: 64Mi}
      limits: {memory: 256Mi}
```

```yaml
# on each WAF Deployment (explicit instead of `auto`)
metadata:
  annotations:
    configmap.reloader.stakater.com/reload: "taskflow-backend-waf-config"
```

Add `secret.reloader.stakater.com/reload: "db-secret,redis-secret,backend-secret,taskflow-jwt-keys"`
on the backend so credential rotations roll it too.

---

### REL-08 — No automated OS reboots or k3s upgrades

| | |
|---|---|
| Severity | Medium |
| Effort / downtime | 2 h / planned: k3s upgrade ≈ 30–90 s API outage (pods keep running); OS reboot ≈ 3–8 min full outage |
| Depends on | REL-00, REL-01, REL-02 (never automate upgrades without backups and alerts) |

**Options**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | system-upgrade-controller (v0.20.2) for k3s + kured (chart 6.1.0, app 1.23.0) for OS reboots | Declarative, Renovate-bumped versions, maintenance windows | On one node every reboot is a full outage; a failed upgrade leaves the node cordoned |
| B | kured only; k3s upgrades stay manual (Renovate PR → run installer) | Simpler | Manual k3s patching |
| C | Ubuntu `unattended-upgrades` with `Automatic-Reboot "true"` at a fixed time | No cluster component | No drain, no Kubernetes awareness, no notification |
| D | Talos + tuppr (reference repos) | Immutable, API-driven | Re-platforming (backlog #16) |

**Recommended: A**, windows not overlapping:

```bash
kubectl apply \
  -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/crd.yaml \
  -f https://github.com/rancher/system-upgrade-controller/releases/download/v0.20.2/system-upgrade-controller.yaml
# (vendor both files into gitops/infrastructure/controllers/system-upgrade/ for Flux)
```

```yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata: {name: k3s-server, namespace: system-upgrade}
spec:
  concurrency: 1
  cordon: true                  # never `drain` the only node
  nodeSelector:
    matchExpressions: [{key: node-role.kubernetes.io/control-plane, operator: In, values: ["true"]}]
  tolerations:
    - {key: node-role.kubernetes.io/control-plane, operator: Exists}
    - {key: CriticalAddonsOnly, operator: Exists}
  serviceAccountName: system-upgrade
  upgrade: {image: rancher/k3s-upgrade}
  version: v1.36.5+k3s1         # pinned; Renovate bumps it, one minor at a time
  window: {days: [saturday], startTime: "02:00", endTime: "04:00", timeZone: Europe/Brussels}
```

```yaml
# kured HelmRelease values (chart kubereboot/kured 6.1.0)
configuration:
  period: "10m"
  rebootDays: [su]
  startTime: "03:00"
  endTime: "05:00"
  timeZone: Europe/Brussels
  drainTimeout: "10m"
  forceReboot: true             # otherwise a stuck drain retries forever
  blockingPodSelector: ["kured/block-reboot=true"]
  annotateNodes: true
extraEnvVars:
  - name: KURED_NOTIFY_URL      # shoutrrr: ntfy://ntfy.sh/<topic> or telegram://<token>@telegram?chats=<id>
    valueFrom: {secretKeyRef: {name: kured-notify, key: url}}
```

The existing PDBs (`maxUnavailable: 1`) do not block the drain. The
"rebooting" notification may not arrive because CoreDNS has already been
evicted; the healthchecks dead-man's switch covers that.

---

## 5. Performance

### PERF-01 — kube-proxy still runs next to Cilium's replacement

| | |
|---|---|
| Severity | Medium |
| Evidence | `modules/proxmox/main.tf:87` lacks `--disable-kube-proxy`; `cilium/release.yaml:29` `kubeProxyReplacement: true`; `docs/ARCHITECTURE.md` claims no kube-proxy |
| Effort / downtime | 20 min / ≈ 30 s API restart; existing connections may reset |
| Depends on | REL-00 |

k3s's embedded kube-proxy runs in iptables mode and keeps programming `KUBE-*`
chains for every Service/EndpointSlice change, although Cilium's eBPF datapath
already handles the traffic. k3s leaves the rules behind when the flag is set,
so clean them up:

```bash
# /etc/rancher/k3s/config.yaml:  disable-kube-proxy: true
sudo systemctl restart k3s
sudo sh -c 'iptables-save | grep -v KUBE | iptables-restore; ip6tables-save | grep -v KUBE | ip6tables-restore'
# (or simply reboot)
sudo iptables-save | grep -c KUBE          # 0
sudo nft list ruleset | grep -c KUBE       # 0
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep 10.43.0.1
kubectl run t --rm -it --image=busybox:1.37 --restart=Never -- nslookup kubernetes.default
```

Cilium reaches the API server at `192.168.50.55:6443` directly
(`k8sServiceHost`), so it does not depend on the ClusterIP it provides.
**Rollback:** remove the key and restart k3s (kube-proxy rebuilds its rules).
Update `docs/ARCHITECTURE.md` and the Terraform install line (with REL-00's
`ignore_changes`).

---

### PERF-02 — CPU reservations, limits and throttling

> Full investigation, sizing table, side effects and ready-to-commit YAML:
> `PERF_DEEP_DIVE_2026-10.md` §1–3. It also found three resource blocks that
> never applied because the charts read different keys (Kyverno admission
> controller, Alloy, Hubble UI).

| | |
|---|---|
| Severity | Medium (performance and rollout reliability) |
| Evidence | `backend.yaml:166,169` (2 CPU request = limit), Postgres 1 CPU, Redis 500m, frontend 250m, Jaeger 250m; ~6.5 CPU of explicit requests in Git vs 5.6 allocatable at the Terraform default of 6 vCPU; `taskflow` `LimitRange` (`namespace.yaml`) injects `default.cpu: 500m` and sets `max.cpu: 4` |
| Effort / downtime | 2 h + two weeks of data / rolling restarts |

**Impact.** Requests are reservations: CPU reserved by mostly idle pods cannot
be used to schedule others, and the backend's rolling update needs another
2 CPU for its surge pod. Limits are enforced by CFS quota: a JVM that bursts
(JIT, GC, startup, request spikes) is throttled even when the node is idle, and
Guaranteed QoS does not prevent that unless the static CPU manager is on.

**Step 1 — measure** (VictoriaMetrics; run in Grafana Explore):

```promql
# p95 CPU per container over 14 days
quantile_over_time(0.95,
  rate(container_cpu_usage_seconds_total{namespace="taskflow",container!=""}[5m])[14d:5m])

# share of CFS periods that were throttled (> 5–10 % hurts latency)
rate(container_cpu_cfs_throttled_periods_total{namespace="taskflow"}[5m])
  / rate(container_cpu_cfs_periods_total{namespace="taskflow"}[5m])

# how much of the node is reserved
sum(kube_pod_container_resource_requests{resource="cpu"})
  / sum(kube_node_status_allocatable{resource="cpu"})

# peak memory working set over 14 days (for memory limits)
max_over_time(container_memory_working_set_bytes{namespace="taskflow",container!=""}[14d])
```

**Step 2 — choose a model**

| Option | What | Pros | Cons |
|---|---|---|---|
| A | CPU requests ≈ p95 × 1.3, **no CPU limits**, memory request = limit ≈ peak × 1.3 | What onedr0p/buroa do; no throttling; idle CPU is shared | Pods become Burstable QoS (memory request = limit keeps them low on the eviction list); a runaway pod can use spare CPU (still bounded by its request share under contention) |
| B | Keep Guaranteed integer CPUs and enable the kubelet **static CPU manager** (see PERF-02b) | Exclusive cores, truly no throttling | Reserves whole cores; needs a kubelet restart and state-file reset |
| C | VPA in recommendation-only mode (`updateMode: "Off"`) or Goldilocks to compute A's numbers continuously | Data-driven | Extra controller |

**Recommended: A**, starting values to adjust after step 1:

| Workload | CPU request | CPU limit | Memory request = limit |
|---|---|---|---|
| backend | 1 (from 2) | none | 2Gi |
| postgres | 500m (from 1) | none | 1Gi |
| redis | 100m | none | 512Mi |
| frontend | 50m | none | 256Mi |
| jaeger | 50m | none | 256Mi |
| WAFs | 100m / 50m | none | 768Mi / 512Mi |

Required companion changes:

- **LimitRange gotcha:** `namespace.yaml` sets `default.cpu: 500m` **and**
  `max.cpu: 4`. Removing a CPU limit from a container makes the LimitRange
  inject a 500m limit — tighter than today — and once the default is gone, the
  CPU `max` makes the LimitRanger *reject* containers without a CPU limit.
  Remove both `default.cpu` and `max.cpu` (keep `defaultRequest` and the memory
  settings) in the same commit as the Deployment changes.
- **JVM CPU count:** without a CPU limit the JVM sizes GC and JIT threads for all
  6 node CPUs. Add `-XX:ActiveProcessorCount=2` to `JAVA_TOOL_OPTIONS`.
- **Go CPU count:** Go ≥ 1.25 derives `GOMAXPROCS` from the CPU *limit*; without
  one it uses all node CPUs. Harmless for the WAFs at this traffic level; set
  `GOMAXPROCS=2` if you want a cap.
- Keep CPU limits on batch and scan workloads (Trivy scan jobs, Renovate) so a
  scan cannot starve the app.

**Verify.** Throttling ratio near 0; `kubectl describe node` CPU requests well
under 80 %; a backend rollout completes without `Pending`.

---

### PERF-03 — Cilium tuning

> Full investigation: `PERF_DEEP_DIVE_2026-10.md` §4. Key finding: the Gateway's
> `cilium-envoy` runs with `hostNetwork: true`, and the bandwidth manager sets
> `fq`, `bbr` and `tcp_slow_start_after_idle=0` in the host namespace, so BBR
> reaches the Envoy → Cloudflare connections, not only pods. Envoy must be
> restarted after enabling it. netkit cannot be switched in place (defer to a
> rebuild); BIG TCP is not supported on virtio-net.

| | |
|---|---|
| Evidence | `gitops/infrastructure/controllers/cilium/release.yaml` |
| Effort / downtime | 30 min / Cilium agent restart (a few seconds of datapath reload); BBR applies to pods started afterwards |

Recommended values additions:

```yaml
    rollOutCiliumPods: true          # restart agents when cilium-config changes
    operator:
      rollOutPods: true
    envoy:
      rollOutPods: true
      resources:                     # the Gateway's data plane had none
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 512Mi}
    bandwidthManager:
      enabled: true
      bbr: true                      # BBR + EDT pacing for pod egress
    hubble:
      relay:
        rollOutPods: true
      ui:
        rollOutPods: true
```

Do at the next maintenance window (brief datapath disruption):

```yaml
    routingMode: native
    ipv4NativeRoutingCIDR: 10.42.0.0/16
    autoDirectNodeRoutes: true
```

Do at the next node rebuild only: `bpf.datapathMode: netkit` (beta in 1.20,
cannot be switched in place, veth/netkit mixing unsupported).

After enabling the bandwidth manager, restart Envoy
(`kubectl -n kube-system rollout restart ds/cilium-envoy`) so its listening
sockets pick up BBR; `envoy.rollOutPods` does not trigger for this change.

**Verify.** `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -iE 'BandwidthManager|BBR|Routing'`;
restart the app pods afterwards so they pick up BBR.

---

### PERF-04 — PostgreSQL tuning

> Full investigation: `PERF_DEEP_DIVE_2026-10.md` §5 — memory budget, every
> setting against the PG 18 defaults, `pg_test_fsync`/pgbench procedures for
> REL-04, and the storage layer: the `proxmox-csi` class uses
> `cache: writethrough` (Proxmox's default is `none`), which can only change on a
> new PVC. Keep `io_method=worker`: `io_uring` is not in containerd's default
> seccomp profile.

| | |
|---|---|
| Evidence | `gitops/apps/taskflow/postgres-db.yaml` args |
| Effort / downtime | 30 min / one Postgres restart (combine with REL-03) |

Changes and why:

| Change | Why |
|---|---|
| `shared_preload_libraries=pg_stat_statements` + `CREATE EXTENSION pg_stat_statements;` | See which queries cost time; postgres-exporter can export them (`--collector.stat_statements`) |
| `track_io_timing=on`, `track_wal_io_timing=on` | I/O time per query and WAL fsync cost (feeds REL-04) |
| `jit=off` | JIT compile time hurts short OLTP queries; it pays off only for long analytics |
| `checkpoint_timeout=15min` | Fewer checkpoints and full-page writes; `max_wal_size=2GB` already allows it |
| remove `max_parallel_maintenance_workers=2` | Already the default |
| `/dev/shm` as `emptyDir {medium: Memory, sizeLimit: 256Mi}` | Container default is 64 MB; parallel query/vacuum use POSIX shared memory |
| optional: `log_min_duration_statement=500ms`, `idle_in_transaction_session_timeout=5min` | Slow-query log; protect against leaked transactions |

```yaml
# postgres-db.yaml, excerpt under spec.template.spec
containers:
  - name: postgres
    args:
      # … existing settings, minus max_parallel_maintenance_workers …
      - "-c"
      - "shared_preload_libraries=pg_stat_statements"
      - "-c"
      - "track_io_timing=on"
      - "-c"
      - "track_wal_io_timing=on"
      - "-c"
      - "jit=off"
      - "-c"
      - "checkpoint_timeout=15min"
    volumeMounts:
      - {name: postgres-storage, mountPath: /var/lib/postgresql}
      - {name: dshm, mountPath: /dev/shm}
volumes:
  - name: postgres-storage
    persistentVolumeClaim: {claimName: postgres-pvc}
  - name: dshm
    emptyDir: {medium: Memory, sizeLimit: 256Mi}
```

The memory-backed `/dev/shm` counts against the 1Gi limit only when used.
Hardening in the same change: `readOnlyRootFilesystem: true` plus `emptyDir`s at
`/var/run/postgresql` and `/tmp`; pin the image by digest.

**Verify.** `SHOW shared_preload_libraries;`,
`SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;`.

---

### PERF-05 — Redis I/O threads

`redis.yaml:58`: `--io-threads 2` in a 500m container. `redis.conf` recommends
I/O threads only with ≥ 4 cores (one spare) and only when Redis is CPU-bound;
`io-threads-do-reads` is a no-op in Redis 8. Set `--io-threads 1` (or drop the
two lines), fix the comment, add `readOnlyRootFilesystem: true` (only `/data` is
written) and `timeoutSeconds: 3` on the exec probes. Verify with
`redis-cli INFO stats` latency and the redis-exporter dashboard.

---

### PERF-06 — Go memory limit for the WAFs

| | |
|---|---|
| Evidence | `backend-waf.yaml:260` (768Mi limit), frontend WAF 512Mi; no `GOMEMLIMIT` |

Go's GC does not see the container memory limit. Set a soft limit at ~90 %:

```yaml
          env:
            - name: GOMEMLIMIT
              value: "690MiB"     # backend WAF (limit 768Mi); frontend WAF: "460MiB"
```

`resourceFieldRef` cannot express "90 %" (and a `divisor` produces a unitless
number that Go reads as bytes), so a literal value is simplest. Check the Go
version Caddy was built with:
`kubectl -n taskflow exec deploy/taskflow-backend-waf -- caddy build-info | head -3`.
If it is older than 1.25, also set `GOMAXPROCS=1`, otherwise the runtime sees 6
CPUs under a 750m quota. Same treatment for the oauth2-proxy pods
(`extraEnv`) if they ever approach their limits.

---

### PERF-07 — JVM flags

| Change | Where | Note |
|---|---|---|
| `-XX:ActiveProcessorCount=2` | `JAVA_TOOL_OPTIONS` | Required once the CPU limit goes (PERF-02) |
| `-XX:+UseCompactObjectHeaders` | `JAVA_TOOL_OPTIONS` and the image's AOT/CDS training run | JDK 25+ only (`kubectl -n taskflow exec deploy/taskflow-backend -- java -version`); a flag mismatch silently disables the CDS archive and slows startup |
| drop `-XX:+UseContainerSupport` | `JAVA_TOOL_OPTIONS` | Default since JDK 10 |
| `/tmp` `sizeLimit: 2Gi` | `backend.yaml:197` | Heap dumps up to 1 GiB + 50 MB GC logs on an unbounded emptyDir |
| drop `SPRING_REDIS_PASSWORD` | `backend.yaml:111` | Boot 3+ reads `SPRING_DATA_REDIS_PASSWORD` (already set) unless the app reads the old name |

---

### PERF-08 — CoreDNS cache

`coredns/release.yaml:106-111`. Use the block the reference repos use:

```yaml
          - name: kubernetes
            parameters: cluster.local in-addr.arpa ip6.arpa
            configBlock: |-
              pods verified
              fallthrough in-addr.arpa ip6.arpa
          - name: cache
            parameters: 30
            configBlock: |-
              prefetch 20
              serve_stale
              servfail 0
```

`prefetch 20` refreshes names asked for 20+ times before they expire;
`serve_stale` answers from cache when upstream is down; `servfail 0` stops
caching upstream failures. Verify with `coredns_cache_hits_total` /
`coredns_cache_misses_total` on the CoreDNS dashboard.

---

### PERF-09 — Edge caching and TLS cost

- Check that Cloudflare serves the hashed Angular bundles from cache:
  `curl -sI https://www.jokelab.dev/<main-hash>.js | grep -i cf-cache-status`
  should say `HIT` on the second request. Cloudflare caches `.js`/`.css`/fonts
  by default; if not, add a Cache Rule ("URI path ends with .js/.css/.woff2 →
  eligible for cache, respect origin TTL"). Every hit is a request neither WAF
  nor nginx processes. Keep `index.html` uncached so deployments show up.
- ECDSA P-256 certificates (REL-05) make each TLS handshake at the Gateway
  cheaper than RSA-2048.

---

### PERF-10 — Logging pipeline

| Item | Change | Value |
|---|---|---|
| Extra `loki-gateway` nginx hop | Point Alloy (`alloy-release.yaml:598`), the Grafana datasource (`loki-datasource.yaml`) and `abuseipdb-sync` (`LOKI_PUSH_URL`) at `http://loki.monitoring.svc.cluster.local:3100`, update `allow-abuseipdb-sync-to-loki` and the abuseipdb egress policy to port 3100 on the single-binary pod, then `gateway.enabled: false` | One pod and one hop less |
| Logs collected from two namespaces only, via the API server | Alloy as a DaemonSet with `loki.source.file` on `/var/log/pods` for all namespaces (keep the WAF pipelines) | Flux, cert-manager, Kyverno, Falco logs searchable; no log streaming through kube-apiserver |
| Loki memory | Migrate to VictoriaLogs: the k8s-stack chart can deploy `vlsingle` and a `vlagent` collector and provisions the Grafana datasource; Alloy can keep shipping to `/insert/loki/api/v1/push`; vmalert alerts on LogsQL with `type: vlogs` groups | Vendor claims up to 30× less RAM than Loki; **cost:** the six Loki dashboards and the Alloy-derived WAF metrics queries must be rewritten from LogQL to LogsQL (no LogQL API) |

---

### PERF-11 — Kyverno footprint

Four controllers reserve 400m CPU / 640Mi for two Audit policies
(`kyverno/release.yaml`). If no `CleanupPolicy`/`ClusterCleanupPolicy` exists
and no resource uses the `cleanup.kyverno.io/ttl` label, set
`cleanupController.enabled: false`. Simple pod-level rules can move to
Kubernetes-native `ValidatingAdmissionPolicy` (runs inside the API server, no
webhook hop) — see SEC-11 for the policy plan.

---

### PERF-12 — VictoriaMetrics cardinality

Open the VMUI cardinality explorer (`kubectl -n monitoring port-forward
svc/vmsingle-victoria-metrics-k8s-stack 8429` →
`http://localhost:8429/vmsingle/vmui/#/cardinality`), confirm the largest series
are unused API-server histograms, then drop them globally in vmagent:

```yaml
    vmagent:
      spec:
        inlineRelabelConfig:
          - action: drop
            source_labels: [__name__]
            regex: "apiserver_request_sli_duration_seconds_bucket|apiserver_request_body_size_bytes_bucket|apiserver_response_sizes_bucket|apiserver_watch_events_sizes_bucket"
```

Check the Kubernetes API-server dashboard still renders before keeping the
change.

---

## 6. Documentation drift and corrections

Statements in the repository that the review found to be wrong or stale:

| Where | Says | Reality | Issue |
|---|---|---|---|
| `docs/PERFORMANCE.md` §1.3 | PVC "snapshots and backups handled natively at the hypervisor" | Proxmox CSI attaches PV disks with `backup=false`; VM backups contain no PVC data | REL-02 |
| `docs/ARCHITECTURE.md` §10 | Cilium replaces kube-proxy | k3s is not started with `--disable-kube-proxy` | PERF-01 |
| `README.md` §6 | Add `disable: [coredns]` to `/etc/rancher/k3s/config.yaml` | Ignored while `--disable` flags remain on the unit's command line; a YAML list must name every component | REL-00 |
| `gitops/README.md` lines 53, 78, 118, 134 | PDBs use `minAvailable: 1`; Policy Reporter UI uses its built-in GitHub OAuth | PDBs use `maxUnavailable: 1`; built-in OAuth is disabled, oauth2-proxy fronts the UI | SEC-14 |
| `falco/release.yaml:11` | Pinned to `9.2.0-rc1` | `version: 9.2.0` | SEC-09 |
| `postgres-db.yaml:75-81` | `synchronous_commit` is about replicas | It protects the local commit | REL-04 |
| `postgres-db.yaml:48-54` | `max_parallel_maintenance_workers=2` is a PG18 win | It is the default | PERF-04 |
| `backend.yaml` resources comment | Guaranteed QoS means CPU is never throttled | CFS quota still throttles without the static CPU manager | PERF-02 |
| `redis.yaml:50-58` | Reads stay on the main thread unless `io-threads-do-reads` | That option is a no-op in Redis 8 | PERF-05 |
| `kyverno/release.yaml` `admissionController.resources`, `alloy-release.yaml` top-level `resources`, `cilium/release.yaml` `hubble.ui.resources` | Resource requests/limits for these components | The charts read `admissionController.container.resources`, `alloy.resources` and `hubble.ui.backend/frontend.resources`; the blocks are ignored (Alloy runs with no limits at all) | PERF-02 |
| `docs/CLUSTER_AUDIT_2026-10.md` | Narrow oauth2-proxy/Grafana scopes to `user:email` | oauth2-proxy's GitHub provider needs `read:org`; keep the defaults (corrected in the audit) | SEC-07 |

---

## 7. Version and support notes found during research

- Kyverno 1.19 is tested on Kubernetes 1.33–1.35; the cluster runs 1.36.
  Kyverno 1.20 (expected November 2026) removes `ClusterPolicy`. Migrate the
  policies (SEC-11) before upgrading.
- CloudNativePG removes the in-tree `barmanObjectStore` in 1.31.0; start with the
  barman-cloud plugin.
- cert-manager v1.21 renamed the Gateway API switch to
  `config.gatewayAPI.enabled` and removed the Helm values
  `prometheus.servicemonitor.targetPort`/`path` (not used here).
- Newer patch releases available at the time of writing: Cilium 1.20.3,
  Proxmox CSI plugin 0.21.0 (chart 0.5.13, adds snapshot RBAC fixes),
  policy-reporter chart 3.11.1, CoreDNS chart 1.49.0, Loki chart 18.17.1.
- The trivy-operator OCI chart on GHCR is stale (0.32.1 vs 0.37.0 in the HTTP
  repository); keep the `HelmRepository` for it.
