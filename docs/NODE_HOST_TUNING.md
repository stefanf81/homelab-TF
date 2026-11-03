# Node OS and Proxmox Host Tuning — Runbook

Network and performance tuning for the Ubuntu 26.04 k3s VM and the Proxmox VE host,
with the commands to apply each change, the evidence behind it, and its risks.

**Expectation.** At this site's traffic none of these is a large win. The big ones are
already in place: kube-proxy replacement, Cilium eBPF host routing with BBR/fq,
Guaranteed QoS for the backend, PostgreSQL on Proxmox CSI and the JVM sizing fixes
(`PERFORMANCE.md`). What remains is mostly latency, reliability and edge cases.
Measure before and after (§5) rather than assuming a gain.

---

## 1. What is already tuned (no action)

| Layer | Setting | Where |
|---|---|---|
| VM | CPU type `host`, `virtio-scsi-single` + IOThread, `ssd`, `discard`, virtio RNG, balloon fixed (`floating = dedicated`) | `modules/proxmox/main.tf` |
| VM | Proxmox firewall off for the NIC (no extra `fwbr` bridge) | provider default |
| Node | inotify, `fs.file-max`, `fs.aio-max-nr`, swap off, journald capped at 100 MB | cloud-init snippet |
| Node | `vm.max_map_count = 1048576` | Ubuntu (`/usr/lib/sysctl.d/55-map-count.conf`); the snippet no longer lowers it to 262144 |
| Node | `default_qdisc=fq`, `tcp_congestion_control=bbr`, `tcp_slow_start_after_idle=0`, 4096 backlogs | Cilium bandwidth manager |
| Node | `kernel.panic=10`, `kernel.panic_on_oops=1`, `vm.overcommit_memory=1` | kubelet (`protectKernelDefaults: false`) |
| Storage | `proxmox-csi` (writethrough) and `proxmox-csi-db` (`cache: none`, `noatime`) classes | `gitops/infrastructure/controllers/proxmox-csi/release.yaml` |

---

## 2. Changes, ranked by impact

| # | Change | Layer | Benefit | Risk | Verdict |
|---|---|---|---|---|---|
| 1 | CPU governor `performance` | Host | The only change that touches every request: no frequency ramp-up latency | More idle power and heat; thermal throttling on small fanless hosts can cancel it | Already set on this host (`amd-pstate-epp`, governor and EPP `performance`, 2026-11-03) |
| 2 | `net.ipv4.tcp_mtu_probing = 1` | Node | Prevents stalls of Cloudflare → Envoy connections when PMTU ICMP is dropped (PPPoE/DS-Lite uplinks) | None known; only activates after a black hole is detected | Do it (in Terraform) |
| 3 | Proxmox VE 8 → 9 | Host | Security support (PVE 8 is past end of life), newer kernel/KVM | **Highest risk on the list**: major Debian upgrade, NIC renames, provider/CSI compatibility | Done: host runs PVE 9.2 (kernel 7.0), checked 2026-11-03 |
| 4 | virtio-net multiqueue (`queues = cpu_cores`) | VM | RX/TX softirq over all vCPUs; one `fq` leaf per queue. Only matters when one vCPU saturates on network work | NIC hot-replug on apply (short outage); slightly more CPU per packet | Do it (in Terraform), in a window |
| 5 | KSM off | Host | Frees host CPU — only if `ksmtuned` is actually scanning (it starts below ~20 % free RAM) | If host RAM is tight, memory use rises and the host may swap | **Keep KSM on here**: on the 15 GiB host it merged ~370 MiB with a 14 GiB VM (2026-11-03) |
| 6 | Microcode | Host | Stability and security, not speed | Rare regressions; mitigations can cost a little speed | Already installed (`amd64-microcode`) |
| 7 | HA services off (standalone) | Host | Fewer small writes to the boot SSD | Must be re-enabled before clustering | Optional |
| 8 | Drop `nfs-common`/`open-iscsi`/multipath; disable snapd, motd-news | Node | Tiny: fewer daemons, tens of MB RAM | Reinstall if NFS/iSCSI storage is added; snaps (e.g. Livepatch) stop working | Done (in Terraform) |
| 9 | Guest I/O scheduler `none` (udev rule) | Node | Probably none: the kernel already picks `none` for multi-queue disks; the rule pins it | On a single-queue disk the guest loses read/write prioritisation (minor) | Done (in Terraform); harmless |
| 10 | Remove `net.bridge.bridge-nf-call-*` | Node | Cleanup; Cilium has no bridge on the pod path | None | Done (in Terraform) |
| 11 | `kernel.core_pattern = \|/bin/false` | Node | Prevents disk fill: the node had the relative pattern `core` (systemd `10-coredump-debian.conf`) and k3s runs with `LimitCORE=infinity`, so a crashing container writes a full core file (JVM ~2 GiB into its writable layer, PostgreSQL into its PVC) | No core dumps for debugging; set a path temporarily when needed | Done (in Terraform) |
| 12 | Drop `vm.max_map_count = 262144` | Node | Keeps Ubuntu's higher default (1048576) instead of lowering it | None | Done (in Terraform) |
| 13 | Graceful node shutdown (kubelet drop-in, 90s / 20s) | Node | Reliability: on a Proxmox shutdown or reboot, pods stop within their grace periods (Postgres checkpoints instead of crash recovery, backend drains) | Shutdown/reboot takes up to 90s longer; unattended-upgrades' 30s logind cap must be masked | Done (in Terraform; live node 2026-11-03) |
| 14 | Kubelet image GC: `imageMaximumGCAge: 168h`, thresholds 75 % / 65 % | Node | Prevents root-disk exhaustion: with the defaults (85 %/80 %, no age limit) GC never ran and containerd reached 68 GB of 96 GB (269 images, 2026-11-03). At ~90 % the kubelet evicts pods, a full outage on one node | Images of idle CronJobs/Jobs are re-pulled after a week | Done (in Terraform) |

### Host memory (finding 2026-11-03)

The host has 15 GiB of RAM and VM 900 was given 14 GiB (`memory = balloon = 14336`). The host had
241 MiB available, 2.2 GiB in swap at `vm.swappiness = 60`, and KSM merging ~370 MiB. Guest
memory the host has swapped out stalls the VM on disk I/O, which outweighs every other tweak in
this document. In order of effect:

1. **More RAM in the host** (the Ryzen 5 7430U board takes DDR4 SO-DIMMs). Removes the problem.
2. **Smaller VM: 12 GiB** (`memory_size` default 12288 since 2026-11-03). Applied with the next
   `make provision` (§3.3); the provider reboots the VM to apply it (`reboot_after_update`).
3. **Host `vm.swappiness = 10`** (§4.2): done 2026-11-03.
4. **Keep KSM on**; HA services stopped (§4.2): done 2026-11-03.

Sizing data (2026-11-03, at 14 GiB):

| Measure | Value |
|---|---|
| Host swap by process | `kvm` 661 MiB; the rest is idle Proxmox Perl daemons (harmless) |
| Guest `free` | 7.7 GiB used, 5.0 GiB page cache, 6.0 GiB available |
| Pod working set (`kubectl top node`) | 7935 Mi |
| Pod memory requests / limits | 8650 Mi / 27978 Mi (66 % / 215 % of allocatable) |

At 12 GiB, allocatable is ~11 GiB (minus the 1000 Mi system/kube reserve and 100 Mi
eviction), so requests use ~78 % and a 2 Gi backend surge pod still fits. The guest loses
~2 GiB of page cache; the host gains ~2 GiB and should stop swapping guest memory.

Do not run `swapoff -a` on the host to pull swapped pages back: it needs as much free RAM as
swap in use, and the OOM killer may pick the VM.

Ballooning is not the answer for Kubernetes: shrinking the guest under the kubelet's feet
invalidates its allocatable memory and leads to OOM kills.

### Conditional host changes (only if a check finds the problem)

| Change | Do it when | Otherwise |
|---|---|---|
| ZFS ARC cap | Host uses ZFS and is short on RAM | Too small hurts ZFS reads; PVE 8.1+ installers already cap ARC at 10 % of RAM |
| Host `vm.swappiness = 10` | Host has swap and swaps | No effect |
| Larger NIC ring buffers | `ethtool -S` shows RX drops/misses | Adds queueing delay |
| `ethtool -K <nic> tso off gso off` | Kernel log shows e1000e/igb "Detected Hardware Unit Hang" | Costs CPU and throughput |

### Deliberately not done

| Change | Why not |
|---|---|
| Rely on apport for core dumps | On the live node `kernel.core_pattern` was the plain `core` from systemd's `10-coredump-debian.conf`, and `sysctl --system` re-applies it over any pipe apport sets. Item 11 sets the pattern explicitly instead |
| Duplicate `kernel.panic*` sysctls | The kubelet already sets them |
| `aio=native` on disks | Blockbridge's benchmark warns it can block on thin LVM; keep the `io_uring` default with an IOThread (§6) |
| 1 GiB hugepages | Small TLB gain; memory is reserved, KSM cannot merge it, and the VM fails to start if pages are not free |
| kubelet `cpu-manager-policy=static` | Pins the backend to 2 cores and squeezes every other pod onto the remaining 4; a botched switch leaves kubelet unable to start |
| `machine = "q35"` | Reboot and changed virtual PCI layout for a minor gain |
| Smaller `vm.dirty_*` limits | Can slow bulk writes (image pulls); measure first |
| 64 MiB `rmem`/`wmem`, `somaxconn` 65535, `tcp_fastopen` | Sized for 10 GbE/QUIC; see `reports/NETWORK_REVIEW_2026-10.md` §2.5 |
| `mitigations=off` | The node is internet-facing |
| `linux-kvm` kernel | May lack modules Cilium needs |

---

## 3. Ubuntu k3s node

### 3.1 In Terraform (new nodes)

`modules/proxmox/main.tf` carries items 2, 4 and 8–14. The cloud-init snippet
is in `ignore_changes` (`reports/REMEDIATION_PLAN_2026-10.md` REL-00), so it only
reaches newly built nodes. The running node needs §3.2, and the NIC change needs §3.3.

### 3.2 Running node — no downtime (do this first)

```bash
ssh ubuntu@192.168.50.55
```

Check the current state. If `snap list` shows a snap you use (e.g. `canonical-livepatch`),
leave snapd out of the disable command below. If `findmnt` prints anything, keep iSCSI/NFS.

```bash
ethtool -l eth0; cat /sys/block/sd*/queue/scheduler; sysctl net.ipv4.tcp_mtu_probing; snap list; findmnt -t nfs,nfs4,iscsi
```

MTU probing, and remove the leftover bridge sysctls:

```bash
printf 'net.ipv4.tcp_mtu_probing = 1\nkernel.core_pattern = |/bin/false\n' | sudo tee /etc/sysctl.d/90-tuning.conf && sudo sed -i '/bridge-nf-call/d; /vm.max_map_count/d' /etc/sysctl.d/99-kubernetes.conf && sudo sysctl -p /etc/sysctl.d/90-tuning.conf && sudo sysctl -w vm.max_map_count=1048576
```

Use `sysctl -p <file>`, not `sysctl --system`, on a running node. `--system` re-applies every
file: Ubuntu's `55-bufferbloat.conf` sets `net.core.default_qdisc` back to `fq_codel` over
Cilium's runtime `fq`, and `10-coredump-debian.conf` resets `kernel.core_pattern`. The
existing `eth0` qdisc keeps `fq`, and Cilium's sysctl reconciler puts `fq` back on its own
(observed on the live node within minutes, no restart). The rp_filter values survive because Cilium
keeps them in `99-zzz-override_cilium.conf`.

I/O scheduler rule:

```bash
echo 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="none"' | sudo tee /etc/udev/rules.d/60-io-scheduler.rules
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=block --action=change
```

Disable unneeded services:

```bash
sudo systemctl disable --now iscsid.socket iscsid.service open-iscsi.service multipathd.socket multipathd.service snapd.socket snapd.service snapd.seeded.service motd-news.timer || true
```

```bash
sudo rm -f /etc/multipath.conf
```

Verify: `1`, `|/bin/false`, `1048576`, `fq` with `bbr`, `[none]`, and `inactive` for each unit.

```bash
sysctl net.ipv4.tcp_mtu_probing kernel.core_pattern vm.max_map_count net.core.default_qdisc net.ipv4.tcp_congestion_control; cat /sys/block/sd*/queue/scheduler; systemctl is-active iscsid.socket iscsid multipathd snapd.socket snapd motd-news.timer
```

If `default_qdisc` still shows `fq_codel` a few minutes after a `sysctl --system`, restart the
Cilium agent so it re-applies `fq`:

```bash
kubectl -n kube-system rollout restart ds/cilium && kubectl -n kube-system rollout status ds/cilium
```

### 3.3 NIC multiqueue — maintenance window (workstation)

```bash
make init && make fmt && make validate && make lint
```

```bash
make plan
```

Expected: `proxmox_virtual_environment_file.cloud_config` **replaced** and
`proxmox_virtual_environment_vm.k3s_node` **updated in place** (`~ queues = <cpu_cores>`; 10 on this host).
With the 12 GiB default, the plan also shows `~ dedicated`/`~ floating` 14336 → 12288 (check
`memory_size` in your `terraform.tfvars` too). The provider reboots the VM for the memory change
(`reboot_after_update`, default true), which also applies the NIC change; if it only prints a
warning, reboot manually as below.
**If the VM shows `-/+` (replace), stop** — that would rebuild the node. The usual cause is a
`# forces replacement` on `disk.file_id` (the cloud image download was re-pinned or replaced);
`disk[0].file_id` is in `ignore_changes` since 2026-11-03 for that reason. Replacing the
`proxmox_download_file` itself (a re-download of the image) and the `cloud_config` snippet is
harmless: the VM's disk is an independent copy, and the snippet is ignored on the running node.
Also check `memory_size` in `terraform.tfvars`: an explicit `14336` there overrides the new
12 GiB default.

```bash
make provision
```

Proxmox hot-replugs the NIC (short outage). Reboot the node so Cilium attaches cleanly:

```bash
ssh ubuntu@192.168.50.55 'sudo reboot'
```

Verify: `Combined:` equal to `cpu_cores` (10 on this host), and `mq` with one `fq` per queue.

```bash
ssh ubuntu@192.168.50.55 'ethtool -l eth0; tc qdisc show dev eth0 | head'
```

`Combined: 1` before this change is expected (pre-set maximum 1: Proxmox exposes a single queue pair, so `ethtool -L` cannot raise it from inside the guest). If Combined is below 6 afterwards:

```bash
ssh ubuntu@192.168.50.55 'sudo ethtool -L eth0 combined 6'
```

Cilium should report `EDT with BPF [BBR] [eth0]`:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -iE 'BandwidthManager|Devices'
```

Rollback: remove the `queues` line from `modules/proxmox/main.tf` and run `make provision`.

### 3.4 Graceful node shutdown (k3s restart: ~30–90 s without the API, pods keep running)

The kubelet default (`0s`) is off, so a Proxmox shutdown lets systemd kill the pods.
k3s reads kubelet drop-ins from `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/`
([k3s docs](https://docs.k3s.io/installation/configuration)). These fields are not
command-line flags, so the REL-00 flag-override problem does not apply.

Check for unattended-upgrades' logind cap (`unattended-upgrades-logind-maxdelay.conf`
limits the delay to 30s; see the [Kubernetes docs](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/)):

```bash
ls /usr/lib/systemd/logind.conf.d/ /etc/systemd/logind.conf.d/ 2>/dev/null
```

```bash
sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-graceful-shutdown.conf <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
shutdownGracePeriod: 90s
shutdownGracePeriodCriticalPods: 20s
EOF
```

If the check listed the unattended-upgrades file, mask it:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d && sudo ln -sf /dev/null /etc/systemd/logind.conf.d/unattended-upgrades-logind-maxdelay.conf
```

```bash
sudo systemctl restart k3s
```

Verify: a `delay` lock from the kubelet, and `t 90000000` (90 s in µs).

```bash
systemd-inhibit --list | grep -i kubelet; busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec
```

Prove it on the next planned reboot. Pods stopped by a graceful shutdown end as `Failed`
("Pod was terminated in response to imminent node shutdown") and their Deployments create new
ones, so check the old pods and the new Postgres log. The old Postgres pod's log should end with
`database system is shut down`, and the grep on the new pod should print nothing (no
`automatic recovery`).

```bash
kubectl get pods -A --field-selector=status.phase=Failed
```

```bash
kubectl -n taskflow logs deploy/postgres-db | grep -iE 'recovery|not properly shut down'
```

Then remove the old pod objects:

```bash
kubectl delete pods -A --field-selector=status.phase=Failed
```

Rollback: delete the drop-in, remove the `/dev/null` symlink, restart k3s.

### 3.5 Root disk: image cleanup (k3s restart for the GC settings)

On 2026-11-03 the root disk was 79 % full: `/var/lib/rancher/k3s/agent/containerd` held
68 GB in 269 images. Data volumes (Postgres, VictoriaMetrics, Loki, Alloy) are separate
Proxmox CSI disks and do not count here.

```bash
sudo du -xh --max-depth=4 /var/lib /var/log 2>/dev/null | sort -rh | head -20
```

One-off cleanup of images no container uses (Jobs/CronJobs re-pull on their next run).
`crictl`'s default 2 s timeout is too short for hundreds of images (`DeadlineExceeded`);
containerd then frees the layers asynchronously, so `df` drops a minute or so later:

```bash
sudo k3s crictl --timeout=2m rmi --prune; sudo k3s crictl images -q | wc -l
```

```bash
df -h /; sudo sh -c 'du -sh /var/lib/rancher/k3s/agent/containerd/*'
```

Result on 2026-11-03: 269 → 73 images, root disk 78 % → 23 % (75 → 22 GB).

Keep it from growing back (the restart is what loads the drop-in):

```bash
sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-image-gc.conf <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageMaximumGCAge: 168h
imageGCHighThresholdPercent: 75
imageGCLowThresholdPercent: 65
EOF
```

```bash
sudo systemctl restart k3s
```

Confirm the kubelet loaded both drop-ins (§3.4 and this one):

```bash
sudo k3s kubectl get --raw "/api/v1/nodes/$(sudo k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}')/proxy/configz" | jq '.kubeletconfig | {shutdownGracePeriod, shutdownGracePeriodCriticalPods, imageMaximumGCAge, imageGCHighThresholdPercent, imageGCLowThresholdPercent}'
```

The other large root-disk user is the policy-reporter Trivy plugin's emptyDir (~1.6 GB): its
local copy of the vulnerability database, re-downloaded on restart and not growing with images.

Leftovers worth removing once confirmed unused:

- `/var/lib/longhorn` (Longhorn replica data, 277 MB; removed 2026-11-03). Confirm no PV
  still references it first. On the node the kubeconfig is root-only, so use `sudo k3s kubectl`:
  `sudo k3s kubectl get pv -o wide | grep -i longhorn` must print nothing.
- Old k3s binary directories in `/var/lib/rancher/k3s/data` (~250 MB each, one per k3s
  upgrade). Keep the ones `current` and `previous` point to, and any a running process
  still uses: container shims started under an older k3s keep running from its directory
  (k3s restarts with `KillMode=process`), and deleting it breaks exec/stop for those pods.

```bash
sudo ls -la /var/lib/rancher/k3s/data/; sudo ls -l /proc/[0-9]*/exe 2>/dev/null | grep -oE 'k3s/data/[0-9a-f]{12}' | sort | uniq -c
```

### 3.6 Further node checks

```bash
findmnt -no OPTIONS /; cat /sys/kernel/mm/transparent_hugepage/enabled; ls -lh /var/lib/rancher/k3s/server/db/; df -h /; dpkg -l needrestart unattended-upgrades 2>/dev/null | grep ^ii
```

| Finding | Meaning |
|---|---|
| `discard` in the root mount options | Online TRIM on every delete; with container churn on thin LVM the weekly `fstrim.timer` alone is usually cheaper. Measure before changing |
| THP `[always]` | Hurts Redis/Postgres latency; set `madvise`. `[madvise]` (Ubuntu default) is fine |
| `state.db` hundreds of MB | kine only VACUUMs when k3s starts; a restart reclaims the space. Tens of MB is fine |
| needrestart / unattended-upgrades installed | Services restart and kernels install on their own schedule; belongs with REL-08 (planned reboots) |

Optional, same drop-in: `serializeImagePulls: false` and `maxParallelImagePulls: 3` for faster
recovery when many images must be pulled. `--disable-helm-controller` (unused: Flux manages Helm)
is an install flag and waits for REL-00.

---

## 4. Proxmox host (root shell)

Not managed by this repository. Use the console, or tmux over SSH, for anything
that can drop the network (§4.3, §4.4).

### 4.1 Checks

```bash
pveversion; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; free -h; swapon --show
```

```bash
cat /sys/kernel/mm/ksm/run /sys/kernel/mm/ksm/pages_sharing; systemctl is-active ksmtuned pve-ha-lrm pve-ha-crm; pvecm status
```

```bash
lvs -o lv_name,data_percent,metadata_percent pve; zpool list 2>/dev/null; qm config 900 | grep -E '^(net0|scsi|cpu|memory|balloon)'
```

```bash
ip -br link; journalctl -k | grep -i 'hardware unit hang'
```

For each physical NIC (example `eno1`):

```bash
ethtool -S eno1 | grep -iE 'drop|miss|err' | grep -v ': 0'
```

### 4.2 Low-risk changes

**CPU governor** (skip if already `performance`):

```bash
apt update && apt install -y linux-cpupower lm-sensors
```

```bash
cat > /etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=Set CPU frequency governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance

[Install]
WantedBy=multi-user.target
EOF
```

```bash
systemctl daemon-reload && systemctl enable --now cpu-performance.service && cpupower frequency-info | grep -E 'governor|current CPU'
```

Watch temperatures under load with `sensors`. Undo:
`systemctl disable --now cpu-performance.service && cpupower frequency-set -g powersave`.

**Microcode.** Confirm `non-free-firmware` is enabled (if nothing prints, add it to the
Debian repository lines), then install `intel-microcode` or `amd64-microcode`. It loads
at the next reboot.

```bash
grep -rn non-free-firmware /etc/apt/sources.list /etc/apt/sources.list.d/
```

```bash
apt update && apt install -y intel-microcode
```

**KSM off** — only with comfortable RAM headroom (available > ~25 % in `free -h`):

```bash
systemctl disable --now ksmtuned && echo 2 > /sys/kernel/mm/ksm/run
```

**HA services off** — only if `pvecm status` reports no cluster configuration
(corosync already does not start on a standalone node). Undo:
`systemctl enable --now pve-ha-crm pve-ha-lrm`.

```bash
systemctl disable --now pve-ha-lrm pve-ha-crm
```

**SSD trim and thin-pool health** (thin pools over-provision; watch Data%/Meta%):

`lvs` Data% on a Proxmox CSI volume counts every block written since the last trim, so it can
far exceed real use: on 2026-11-03 the Trivy server cache (`data-trivy-server-0`, 5 Gi) showed
93 % in `lvs` but 33 % inside the pod, because each DB update rewrites ~1 GB and the node's
`fstrim.timer` runs weekly. Check real use inside the pod (`df`) before resizing anything;
`sudo fstrim -av` on the node returns the blocks at once (2026-11-03: Trivy volume 92.75 % → 35 %,
thin pool 10.66 % → 9.50 %).

A trim only reaches the thin pool if the Proxmox disk has `discard=on`. One CSI volume (`scsi2`,
`vm-9999-pvc-4299…`, 8 Gi) was attached without it by an older plugin version and stayed at
61.62 % after the trim. Add it with the full existing line (keep the `wwn`, which the CSI driver
uses to find the disk); Proxmox applies it at the next VM reboot:

```bash
qm set 900 --scsi2 local-lvm:vm-9999-pvc-4299b1b3-248e-416e-ab15-28d71c74098a,backup=0,cache=writethrough,discard=on,iothread=1,replicate=0,size=8G,ssd=1,wwn=0x5056432d49443032
```

```bash
systemctl enable --now fstrim.timer && lvs -o lv_name,data_percent,metadata_percent pve
```

**Swappiness** — only if `swapon --show` lists swap:

```bash
echo 'vm.swappiness = 10' > /etc/sysctl.d/90-swappiness.conf && sysctl -p /etc/sysctl.d/90-swappiness.conf
```

### 4.3 Conditional changes

**ZFS ARC cap** — only if `zpool list` shows pools (4 GiB shown; adjust):

```bash
echo 'options zfs zfs_arc_max=4294967296' > /etc/modprobe.d/zfs.conf && echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max && update-initramfs -u -k all
```

**Ring buffers** — only if `ethtool -S` showed drops. Read the maximums, then set them:

```bash
ethtool -g eno1
```

```bash
ethtool -G eno1 rx 4096 tx 4096
```

Persist with `post-up /usr/sbin/ethtool -G eno1 rx 4096 tx 4096` under `iface eno1`
in `/etc/network/interfaces`.

**TSO/GSO off** — only if the kernel log showed "Hardware Unit Hang":

```bash
ethtool -K eno1 tso off gso off
```

Persist with `post-up /usr/sbin/ethtool -K eno1 tso off gso off` in the same stanza.

### 4.4 Proxmox VE 8 → 9 upgrade (own window, backup first)

Done on this host (PVE 9.2, kernel 7.0, checked 2026-11-03); kept for reference.

From the [official guide](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9) for a
standalone node on the no-subscription repository; read its known-issues list first.

Update to 8.4.1 or newer:

```bash
apt update && apt dist-upgrade && pveversion
```

Run the checklist; fix and re-run until it is clean:

```bash
pve8to9 --full
```

Switch Debian to Trixie:

```bash
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
```

Remove the old Proxmox repository files from `/etc/apt/sources.list.d/`
(`pve-enterprise.list`, `pve-install-repo.list` or similar), then add the new one:

```bash
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
```

Only the intended repositories should be listed. If the upgrade wants to remove
`proxmox-ve`, stop: a repository is misconfigured.

```bash
apt update && apt policy
```

```bash
apt dist-upgrade
```

```bash
pve8to9 && reboot
```

Afterwards:

- NIC names unchanged (`ip -br link` vs the bridge ports in `/etc/network/interfaces`); `pve-network-interface-pinning` can pin them.
- `/etc/sysctl.conf` is ignored on PVE 9: keep settings in `/etc/sysctl.d/`.
- Governor unit and KSM state as set in §4.2.
- `make plan` from the workstation still works against the 9.x API (bpg provider, Proxmox CSI).

---

## 5. Measuring

Change one thing at a time; compare a week of baseline with the period after.

- **Edge latency:** Envoy p95 in Grafana (`cilium-envoy` VMServiceScrape).
- **Softirq spread** (does multiqueue matter?): `mpstat -P ALL 1` on the node, or `rate(node_cpu_seconds_total{mode="softirq"}[5m])` per CPU.
- **Network:** the netperf procedure in `reports/CILIUM_REVIEW_2026-10.md` §7.1.
- **Disk:** the PromQL in `reports/PERF_DEEP_DIVE_2026-10.md` §2.4, and `fio` on a Proxmox CSI volume.
- **Governor:** repeat the above with only the governor changed.

---

## 6. Community evidence

Most of these tweaks have forum anecdotes or old tests, not controlled benchmarks on
current versions. Checked November 2026.

| Tweak | Best evidence | Strength |
|---|---|---|
| `aio` mode, IOThreads | [Blockbridge PVE 7.2 benchmark](https://kb.blockbridge.com/technote/proxmox-aio-vs-iouring/) (2022, 32 VMs, NVMe/TCP, fio): IOThreads ~15 % at QD1; `native` vs `io_uring` within noise; `aio=native` can block on thin LVM ([forum thread](https://forum.proxmox.com/goto/post?id=505168)) | The only real benchmark here; enterprise storage, older kernel |
| CPU governor | OPNsense VM on Proxmox: ~1.2 Gb/s iperf3 on `powersave`, near line rate (2.5 Gb/s) on `performance` ([forum](https://forum.opnsense.org/index.php?topic=39089.0)); ramp-up "micro lags" ([forum](https://forum.proxmox.com/goto/post?id=213063)) | Anecdotal |
| virtio-net multiqueue | [Original 2012 patch series](https://lwn.net/Articles/503332): large TCP_RR gains, bulk throughput flat (~9.3 Gbps), small-packet regressions | Old; no modern benchmark |
| KSM | PVE 1.5-era reports of `ksmd` at 30–70 % CPU ([forum](https://forum.proxmox.com/goto/post?id=21650)); `ksmtuned` threshold ~20 % free RAM ([forum](https://forum.proxmox.com/goto/post?id=392764)); side-channel warning ([Proxmox wiki](https://pve.proxmox.com/wiki/Kernel_Samepage_Merging_(KSM))) | Old |
| Guest I/O scheduler | [Red Hat](https://access.redhat.com/solutions/5427): `mq-deadline` vs `none` "statistically close"; [virtio-blk patch](https://lkml.iu.edu/hypermail/linux/kernel/2312.0/09249.html): 270k vs 450k IOPS on single-queue virtio-blk | Weak for virtio-scsi |
| Cilium datapath | `reports/CILIUM_REVIEW_2026-10.md` §7 | — |

No published benchmarks exist for `tcp_mtu_probing`, the HA services or the package
cleanup; those are reliability and wear changes, not speed.
