# TaskFlow — Performance Analysis

> **Scope note:** The initial review was static analysis (cluster unreachable). The monitoring stack (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) is deployed, and the backend plus GitOps configuration now expose its existing Micrometer Prometheus registry for in-cluster scraping. JVM, HTTP, Hikari, PostgreSQL, Redis, node, and disk metrics are configured for the TaskFlow Performance Grafana dashboard after the normal application deployment.

---

## 1. Tier 1 — Likely real problems (fix first)

### 1.1 JVM off-heap memory is unbounded → OOM-restart risk (HIGH) — ✅ RESOLVED

> **Resolved:** The JVM sizing has been fixed. The backend uses deployment-supplied `JAVA_TOOL_OPTIONS` with `MaxRAMPercentage=50.0` for a 1 GiB heap at the 2 GiB limit, plus `MaxDirectMemorySize=256m` and `MaxMetaspaceSize=256m`, with Guaranteed QoS (`requests == limits == 2Gi/2000m`). See `BACKEND_INTEGRATION_CONTEXT.md` for the full contract.

**Previous config (for reference):**
```
-Xms1536m -Xmx1536m ... -XX:+ExitOnOutOfMemoryError
resources:
  requests: cpu 1000m, memory 2048Mi
  limits:   cpu 4000m, memory 2560Mi
```

**Current config** (`backend.yaml` + image Dockerfile):
```yaml
# backend.yaml — JAVA_TOOL_OPTIONS (only GC/logging, no heap override)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
resources:
  requests: { cpu: "2000m", memory: "2Gi" }   # Guaranteed QoS
  limits:   { cpu: "2000m", memory: "2Gi" }
```
The deployment owns heap sizing via `JAVA_TOOL_OPTIONS` and
`-XX:MaxRAMPercentage=50.0` → 1 GiB heap at the 2 GiB limit.

### 1.2 ~~No observability → you are tuning blind~~ (RESOLVED)
**Files:** `gitops/monitoring/platform/release.yaml` (VictoriaMetrics stack), `gitops/monitoring/app/vmservicescrapes.yaml` (app scrapes)

> **Resolved:** The monitoring stack is deployed and collecting cluster-wide metrics:
> - **VictoriaMetrics** (VMSingle + vmagent) — replaces Prometheus, ~⅓ the RAM
> - **Grafana** — dashboards queryable at `https://grafana.jokelab.dev`
> - **kube-state-metrics** — pod/Deployment/replica/namespace resource metrics
> - **node-exporter** — host-level CPU/memory/disk/network per node
> - **PostgreSQL exporter** — DB query latency, active connections, cache hit ratio
> - **Redis exporter** — cache hit rate, memory usage, evictions
> - **Falco** — runtime security event metrics
> - **Spring Boot Actuator + Micrometer** — JVM, HTTP latency, and Hikari connection-pool metrics from `/actuator/prometheus`; the endpoint is reachable without application credentials only from the monitoring namespace.
>
> The backend Service and VMServiceScrape use the same named `http` port, so discovery does not depend on an unnamed numeric Service port.

#### Monitoring stack tuning (October 2026)

- **No duplicate scrapes:** the stack's own CoreDNS scrape is disabled (`coreDns.enabled: false`; the custom `coredns` VMServiceScrape selects the same pods), and the `loki` VMServiceScrape skips the chart's headless Service. Both previously ingested every series twice.
- **CPU limits:** Loki and VMSingle limits raised from 500m to 1 CPU so split Loki queries run in parallel and VMSingle merges are not throttled; memory limits (768Mi / 1Gi) stay the protective limit.
- **Loki:** in-process results cache (100 MB, no memcached pod); a repeated range query went from 4.4 s to 0.009 s in the lab. Tenant ingestion set explicitly to 8 MB/s with a 16 MB burst (the 4/6 MB default made the 15 MB per-stream burst unreachable).
- **Grafana:** the VictoriaMetrics datasource sets `timeInterval: 30s` to match the scrape interval.
- **Dashboards:** the WAF and Rate Limits overviews read Alloy-derived counters instead of scanning Loki: log data read per dashboard open at 6h fell from 949 to 89 MB (WAF) and 2,108 to 516 MB (Rate Limits).
- **Open:** drop unused high-cardinality series (API server histograms, unused cAdvisor metrics) after checking the VMUI cardinality explorer.

### 1.3 ~~PostgreSQL runs on Longhorn (network storage)~~ (RESOLVED)
**File:** `gitops/apps/taskflow/postgres-pvc.yaml` (`storageClassName: proxmox-csi`)

> **Resolved:** PostgreSQL has been migrated from Longhorn to native **Proxmox CSI** storage. Disk space is scaled to `10Gi` and volumes are dynamically provisioned on your Proxmox VE hypervisor with backing snapshots and backups handled natively at the hypervisor layer. This bypasses in-cluster network storage overhead entirely, providing local-SSD-grade performance.

---

## 2. Tier 2 — Tuning mismatches

### 2.1 `effective_cache_size` is overstated (MEDIUM) — ✅ RESOLVED

> **Resolved:** `effective_cache_size` is now `256MB` in `postgres-db.yaml` (lowered from `700MB` on 2026-10-22).

**Previous config (for reference):**
```yaml
effective_cache_size=1152MB   # but container memory limit is only 1024Mi
```

**Current config** (`postgres-db.yaml`):
```yaml
effective_cache_size=256MB    # matches realistic cache inside the 512Mi cap
```

> **2026-10-22:** container cut to 512 MiB and `shared_buffers` to 128 MB (database
> is ~17 MB), so the hint dropped from 700 MB to 256 MB. The history below explains
> the earlier 1152 MB → 700 MB correction.

The value was corrected because the container is capped at 1024 MiB; Postgres RSS is ~384 (shared_buffers) + ~300 (30 backends × ~10 MiB) ≈ 800–900 MiB, leaving only ~300 MiB of real OS page cache. The original 1152 MiB hint (~2×+ reality) made index scans look artificially cheap and could cause suboptimal plans under load.

### 2.2 Backend is "Burstable" QoS → CPU throttling under load (MEDIUM) — ✅ RESOLVED

> **Resolved:** The backend now uses Guaranteed QoS (`requests == limits == 2000m` CPU).

**Previous config:**
```yaml
requests: { cpu: "1000m" }
limits:   { cpu: "4000m" }    # Burstable QoS
```

**Current config** (`backend.yaml`):
```yaml
requests: { cpu: "2000m", memory: "2Gi" }
limits:   { cpu: "2000m", memory: "2Gi" }   # Guaranteed QoS
```

### 2.3 Redis is ephemeral → cold-cache stampede on restart (MEDIUM)
**File:** `gitops/apps/taskflow/redis.yaml`

`/data` is an `emptyDir` with a clear comment that persistence is intentionally off. That's a legitimate L2-cache choice, **but** on every Redis pod restart (or the node rebooting) the entire cache is lost and the backend falls back to PostgreSQL — a cache stampede that can spike DB latency/CPU until the cache warms. With a single replica there's no warm standby.

**Fix:** Accept it (documented tradeoff) **or** back Redis with a small Proxmox CSI PVC + `appendonly yes` so restartswarm doesn't start fully cold. At minimum, ensure the backend degrades gracefully (it presumably does, since Redis is "L2").
### 2.4 Default connection pool vs `max_connections=50` (LOW-MEDIUM)

**File:** `gitops/apps/taskflow/postgres-db.yaml` (`max_connections=50`)

Spring Boot's default HikariCP `maximumPoolSize` is 10, while `postgres-db.yaml` budgets for a 25-connection pool. With one backend replica that's fine, but if the backend ever scales, each replica multiplies the pool and can exhaust `max_connections=50` with no headroom for `psql`/migrations/admin.

**Fix:** Pin `spring.datasource.hikari.maximum-pool-size` explicitly in the app (≤25 total across replicas) and keep `max_connections` sized from that number, or raise `max_connections` to ~50–100 (cheap at this RAM).

---

## 3. Tier 3 — Minor / nice-to-have

| # | Item | Where | Note |
|---|------|-------|------|
| 3.1 | `synchronous_commit` tuning | `postgres-db.yaml` | `synchronous_commit=off` trades the last WAL-writer interval of acknowledged writes for lower commit latency; it is suitable only for this explicitly accepted homelab durability profile. |
| 3.2 | Compression / `Cache-Control` on nginx | `frontend` repo `nginx.conf` | ✅ Done in the app repo: Brotli and gzip (precompressed `.br`/`.gz` sidecars served statically, level 6 on the fly for the rest), `Cache-Control: public, immutable, max-age=15552000` on the hashed JS/CSS bundles, `no-cache` on the HTML shells. Cloudflare caches the bundles (`cf-cache-status: HIT` after the first request per data center, checked 2026-10-30); Smart Tiered Cache would also remove those first per-location fetches (`reports/NETWORK_REVIEW_2026-10.md` §2.6). |
| 3.3 | HTTP/2 | `backend.yaml` Service, `backend-waf.yaml` | Backend `server.http2.enabled=true` (app repo) and `appProtocol: kubernetes.io/h2c` on the backend Service, but no hop uses it: the Gateway routes to the WAFs (`gatewayAPI.enableAppProtocol` is off) and the backend WAF pins its upstream to HTTP/1.1. Intentional, see `reports/NETWORK_REVIEW_2026-10.md` §2.7. |
| 3.4 | JVM GC logging / `-XX:MaxGCPauseMillis` | `backend.yaml` | ✅ Applied: rotated `-Xlog:gc*` + `MaxGCPauseMillis=100`. |
| 3.5 | Single replica / autoscaling | `backend.yaml` | Backend is intentionally fixed at one replica. Local SSE state and the PostgreSQL connection budget must be redesigned before autoscaling is reintroduced. PDBs protect backend and frontend availability. |
| 3.6 | `random_page_cost=1.1` assumes SSD | `postgres-db.yaml` | Reasonable for Proxmox-CSI-backed-SSD; re-check if you move DB to spinning disk. |

---

## 4. Status of recommended actions

| # | Action | Status |
|---|--------|--------|
| 1 | **Monitoring stack** (VictoriaMetrics + Grafana + kube-state-metrics + node-exporter) | ✅ Deployed and collecting metrics |
| 2 | **Backend `/actuator/prometheus`** — Micrometer registry, exposure, SecurityConfig permit, and named VMServiceScrape port | ✅ Configured — the normal application and Flux deployment activates backend JVM, HTTP, and Hikari scrapes alongside existing PostgreSQL, Redis, node, and disk telemetry. |
| 3 | **JVM sizing** — single source of truth via `MaxRAMPercentage=50.0` (deployment), Guaranteed QoS `2Gi` | ✅ Applied — `backend.yaml` `JAVA_TOOL_OPTIONS` owns heap/direct/metaspace sizing |
| 4 | **`effective_cache_size`** corrected to 700MB, then 256MB | ✅ Applied in `postgres-db.yaml` |
| 5 | **Postgres PVC** migrated from Longhorn to Proxmox CSI | ✅ Applied in `postgres-pvc.yaml` |
| 6 | **Harden Redis** — add persistence PVC or document stampede risk | ✅ Resolved (intentionally ephemeral) — RDB/AOF are now explicitly disabled (`--save ""`, `--appendonly no`) so no stray bgsave/fork memory spikes occur; stampede risk on restart is accepted (see §2.3) |
| 7 | **Re-evaluate pool sizes** when adding replicas | Backend autoscaling is disabled. Local SSE state and the Hikari pool require distributed event fan-out and connection-pool redesign before scaling. |
| 8 | **Redis / Jaeger QoS** — Guaranteed (requests==limits) | ⚠️ Redis and Jaeger use Burstable QoS (requests < limits). This is intentional: Redis is ephemeral and Jaeger is a dev tool. Guaranteed QoS is not required for either. |
| 9 | **Backend startup probe** tightened 20→15 failures | ✅ Applied in `backend.yaml` |
| 10 | **Scrape intervals** relaxed to 60s for postgres/redis exporters | ✅ Applied in `vmservicescrapes.yaml` |
| 11 | **Flux image-poll interval** 5m→10m | ✅ Applied in `image-automation/*-repository.yaml` |
### Note on item 3 (JVM sizing) — resolution of the TF-vs-image conflict
The previous config had a **silent bug**: `backend.yaml` set `-Xmx1024m` + `-XX:MaxDirectMemorySize=512m`
in `JAVA_TOOL_OPTIONS`, while the Dockerfile set `MaxRAMPercentage=75.0` + `MaxDirectMemorySize=256m`.
Because Dockerfile CMD args win over `JAVA_TOOL_OPTIONS` (JVM "last-wins"), the in-cluster reality was:
heap = 1GiB (env only source), `MaxDirectMemorySize = 256m` (image won) — so the "512Mi direct"
comment was wrong, and `MaxRAMPercentage` was dead (ignored when `-Xmx` is set).

Resolution: the **deployment owns JVM sizing** via `JAVA_TOOL_OPTIONS` and
`MaxRAMPercentage=50.0` (75% would give 1.5GiB heap at the 2Gi limit and OOMKill the pod given
Netty/Lettuce direct buffers + ~200 thread stacks). The image must not introduce
competing sizing flags. See `BACKEND_INTEGRATION_CONTEXT.md` §0/§4 for the corrected contract.

---

## 5. Quick "before/after" for the highest-impact change (§1.1 / §item 3)

```yaml
# backend.yaml — JAVA_TOOL_OPTIONS (deployment only adds GC/logging; heap owned by image)
env:
  - name: JAVA_TOOL_OPTIONS
    value: >-
      -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ExitOnOutOfMemoryError
      -XX:+UseStringDeduplication -XX:+AlwaysPreTouch
      -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC
      -XX:MaxMetaspaceSize=256m
      -Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=10m
      -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/dump.hprof
# Deployment owns heap: -XX:MaxRAMPercentage=50.0  → 1GiB heap at the 2Gi limit
resources:
  requests: { cpu: "2000m", memory: "2Gi" }   # Guaranteed QoS
  limits:   { cpu: "2000m", memory: "2Gi" }
```

This removes the rigid heap, fixes the silent direct-memory override, and bounds native memory
so `ExitOnOutOfMemoryError` only triggers on a real leak, not a benign spike.

---

## 6. Node OS and Proxmox host tuning (November 2026)

### 6.1 Ubuntu node: what the Terraform now sets

`modules/proxmox/main.tf` (new nodes get it through the cloud-init snippet):

| Change | Why |
|---|---|
| `network_device.queues = var.cpu_cores` | Multiqueue virtio-net: RX/TX softirq spread over all vCPUs instead of one; the Cilium bandwidth manager gets one `fq` leaf per queue |
| `net.ipv4.tcp_mtu_probing = 1` | PMTU black-hole recovery for Envoy → Cloudflare (`reports/NETWORK_REVIEW_2026-10.md` §2.5) |
| `kernel.panic = 10`, `kernel.panic_on_oops = 1` | The node reboots instead of hanging |
| udev rule `60-io-scheduler.rules` → scheduler `none` on `sd*` | The Proxmox host already schedules I/O for virtio-scsi disks |
| Removed `nfs-common`, `open-iscsi`, `/etc/multipath.conf`, iscsid; disabled multipathd, snapd, apport, motd-news | Longhorn is gone and Proxmox CSI attaches plain virtio disks; fewer background daemons and udev scans |
| Removed `net.bridge.bridge-nf-call-*` | No Linux bridge on the Cilium pod path |

BBR, `fq`, `tcp_slow_start_after_idle=0` and the 4096 listen backlogs are set by the
Cilium bandwidth manager and are deliberately not duplicated in sysctl.

**Running node.** The snippet is in `ignore_changes` (REL-00), so apply it by hand:

```bash
sudo tee /etc/sysctl.d/90-tuning.conf <<'CONF'
net.ipv4.tcp_mtu_probing = 1
kernel.panic = 10
kernel.panic_on_oops = 1
CONF
sudo sed -i '/bridge-nf-call/d' /etc/sysctl.d/99-kubernetes.conf
sudo sysctl --system
echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="none"' | sudo tee /etc/udev/rules.d/60-io-scheduler.rules
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=block --action=change
sudo systemctl disable --now iscsid.service iscsid.socket multipathd.service multipathd.socket snapd.service snapd.socket snapd.seeded.service apport.service motd-news.timer || true
```

`tofu apply` then changes the NIC in place (Proxmox hot-replugs it: a short network
outage on this single node, so do it in a maintenance window). Verify:

```bash
ethtool -l eth0                          # Combined: 6 (else: sudo ethtool -L eth0 combined 6)
tc qdisc show dev eth0                   # mq with one fq per queue
cat /sys/block/sd*/queue/scheduler       # [none]
sysctl net.ipv4.tcp_mtu_probing kernel.panic
```

### 6.2 Optional node changes (not applied)

| Change | Benefit | Cost |
|---|---|---|
| kubelet `cpu-manager-policy=static` + `reserved-cpus=0` | Guaranteed pods with integer CPUs (backend, 2000m) get exclusive cores: less JVM jitter | kubelet restart after deleting `/var/lib/kubelet/cpu_manager_state` |
| `machine = "q35"` | Modern PCIe chipset for virtio devices | VM reboot; the NIC name may change (Cilium uses `devices: eth0`) |
| `vm.dirty_background_bytes=64M`, `vm.dirty_bytes=256M` | Smoother writeback on the writethrough storage class | Measure first |

Not worth it here: large `rmem`/`wmem`, `somaxconn` 65535, `tcp_fastopen` (see
NETWORK_REVIEW §2.5), `mitigations=off` (internet-facing), the `linux-kvm` kernel
(may lack modules Cilium needs).

### 6.3 Proxmox host checklist (manual, not managed by this repo)

1. **Stay current.** Proxmox VE 8 reached end of life in 2026; upgrade to 9.x (`pve8to9 --full` first) and keep the latest `proxmox-kernel`.
2. **CPU.** Install `intel-microcode` or `amd64-microcode` (non-free-firmware repo). Governor: `performance` for the lowest latency, or keep `powersave` + EPP `balance_performance` on `intel_pstate`/`amd-pstate` to save idle power. Use `cpupower frequency-set -g performance` in a systemd oneshot.
3. **KSM off.** A single large VM gains almost nothing from KSM and pays the scan CPU: `systemctl disable --now ksmtuned && echo 2 > /sys/kernel/mm/ksm/run`.
4. **HA services off on a standalone node.** `systemctl disable --now pve-ha-lrm pve-ha-crm` (plus `corosync` if the host is not in a cluster). This cuts constant small writes to the boot SSD.
5. **Memory.** Host `vm.swappiness=10`. If the host uses ZFS, cap the ARC (`options zfs zfs_arc_max=<bytes>` in `/etc/modprobe.d/zfs.conf`, then `update-initramfs -u`) so it does not compete with the 14 GiB VM. Ballooning stays effectively off (`floating = dedicated`), which is right for Kubernetes. Optional: 1 GiB hugepages for the VM (`hugepagesz=1G hugepages=14` on the kernel cmdline + `memory.hugepages = "1024"` in Terraform): a small TLB gain, but the memory is reserved.
6. **Storage (`local-lvm` thin).** Watch `lvs` Data%/Meta% (thin pools over-provision), keep `fstrim.timer` enabled, leave NVMe on scheduler `none`. Optionally compare `aio=native` with the default `io_uring` on the PV disks using fio.
7. **Physical NIC.** `ethtool -G <nic> rx <max> tx <max>` (persist via `post-up` in `/etc/network/interfaces`). On Intel e1000e/igb that log "Detected Hardware Unit Hang", run `ethtool -K <nic> tso off gso off`. Keep MTU 1500 unless the whole path supports jumbo frames. The PVE firewall stays off for this VM (no extra `fwbr` bridge).
8. **Check.** `qm config 900 | grep -E 'net0|scsi'`, `cat /sys/kernel/mm/ksm/run` (2), `cpupower frequency-info`.
