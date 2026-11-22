# Ubuntu 26.04 (Resolute) Cloud Image, pinned to the 2026-11-08 release image.
# The checksum comes from that release's SHA256SUMS, whose signature verifies
# against the Ubuntu cloud image signing key (ubuntu-cloudimage-keyring).
resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud-images.ubuntu.com/releases/resolute/release-20261108/ubuntu-26.04-server-cloudimg-amd64.img"
  checksum            = "7b90593f5532b49b7e3fe3d2743f0d1f0d822e5b07cebcd8e00c0df8069ecab9"
  checksum_algorithm  = "sha256"
  file_name           = "ubuntu-26.04-server-cloudimg-amd64.img"
  overwrite           = false
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = <<EOF
#cloud-config
users:
  - default
  - name: ${var.ssh_user}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${var.ssh_public_key}

package_update: true
package_upgrade: true
packages:
  - apparmor
  - qemu-guest-agent
  - curl
  - jq

write_files:
  # Ubuntu's packaged runc profile only matches /usr/bin and /usr/sbin.
  # K3s bundles runc under its versioned data directory. Without this attachment,
  # Ubuntu 26.04 stacks "unconfined" onto the container profile and denies signals
  # within containers (Postgres authentication and VictoriaMetrics reloads).
  # Keep the standard profile name: containerd permits signals from peer=runc.
  - path: /etc/apparmor.d/runc
    content: |
      abi <abi/5.0>,
      include <tunables/global>

      profile runc /{usr/{bin,sbin},var/lib/rancher/k3s/data/*/bin}/runc flags=(unconfined) {
        userns,
        @{exec_path} mr,
        include if exists <local/runc>
      }

  - path: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.ipv4.ip_forward = 1
      fs.inotify.max_user_instances = 8192
      fs.inotify.max_user_watches = 524288
      fs.file-max = 2097152
      fs.aio-max-nr = 1048576
      vm.swappiness = 1
      # PMTU black-hole recovery for host-namespace sockets (Envoy -> Cloudflare).
      # BBR, fq and the listen backlogs are set by the Cilium bandwidth manager.
      net.ipv4.tcp_mtu_probing = 1
      # Discard core dumps. systemd's 10-coredump-debian.conf sets the relative
      # pattern "core", and k3s runs with LimitCORE=infinity, so a crashing
      # container would write a full core file into its working directory (JVM
      # ~2 GiB into its writable layer, PostgreSQL into its PVC). Pipe helpers run
      # in the host namespaces, so this covers every container.
      kernel.core_pattern = |/bin/false

  # The Proxmox host already schedules I/O for the virtio-scsi disks (root and
  # Proxmox CSI volumes), so a second scheduler in the guest only adds latency.
  - path: /etc/udev/rules.d/60-io-scheduler.rules
    content: |
      ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="none"

  # Cap the journal at 100M with a drop-in: the sed this replaced only edited a
  # commented `#SystemMaxUse=` line in /etc/systemd/journald.conf, which newer
  # systemd packaging no longer ships, and a no-match was silent.
  - path: /etc/systemd/journald.conf.d/10-size.conf
    content: |
      [Journal]
      SystemMaxUse=100M

  # Graceful node shutdown: on a Proxmox shutdown/reboot the kubelet holds a
  # logind delay lock and stops pods within their grace periods (Postgres 60s,
  # backend 45s) instead of letting systemd kill them. 90s fits Proxmox's
  # default 180s VM shutdown timeout. k3s reads drop-ins from this directory.
  - path: /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-graceful-shutdown.conf
    content: |
      apiVersion: kubelet.config.k8s.io/v1beta1
      kind: KubeletConfiguration
      shutdownGracePeriod: 90s
      shutdownGracePeriodCriticalPods: 20s

  # Image GC: the kubelet default (85 % high / 80 % low, no age limit) never ran
  # on the 96 GB root disk, and Flux image automation's old TaskFlow images grew
  # containerd to 68 GB (269 images, 2026-11-03). Unused images are now removed
  # after a week, and threshold GC starts earlier.
  - path: /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-image-gc.conf
    content: |
      apiVersion: kubelet.config.k8s.io/v1beta1
      kind: KubeletConfiguration
      imageMaximumGCAge: 168h
      imageGCHighThresholdPercent: 75
      imageGCLowThresholdPercent: 65

  # Declarative k3s server config (0600 root-only): keeps K3S_TOKEN out of
  # /proc/<pid>/cmdline and systemd ExecStart args, and safely JSON-escapes any
  # special characters in the token.
  - path: /etc/rancher/k3s/config.yaml
    owner: root:root
    permissions: '0600'
    content: |
      token: ${jsonencode(var.k3s_token)}
      tls-san:
        - ${jsonencode(split("/", var.ip_address)[0])}
      kubelet-arg:
        - "system-reserved=cpu=200m,memory=500Mi"
        - "kube-reserved=cpu=200m,memory=500Mi"
      node-label:
        - "topology.kubernetes.io/region=homelab"
        - ${jsonencode("topology.kubernetes.io/zone=${var.proxmox_node}")}
      disable:
        - servicelb
        - traefik
        - coredns
        - metrics-server
        - local-storage
      flannel-backend: "none"
      disable-network-policy: true
      disable-kube-proxy: true

runcmd:
  # Load the runtime attachment before K3s starts; container profiles stay enforced.
  - apparmor_parser -r /etc/apparmor.d/runc
  - swapoff -a
  - sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  - sysctl --system
  - systemctl restart systemd-journald
  - udevadm control --reload-rules
  - udevadm trigger --subsystem-match=block --action=change
  # Not needed on a k3s node: storage is Proxmox CSI (virtio disks, no iSCSI or
  # multipath), and snapd/motd-news only add background wakeups. Same unit list as
  # the live node (docs/NODE_HOST_TUNING.md); the packages stay installed.
  - systemctl disable --now iscsid.socket iscsid.service open-iscsi.service multipathd.service multipathd.socket snapd.service snapd.socket snapd.seeded.service motd-news.timer || true
  # The Ubuntu cloud image enables a getty on ttyS0, but the VM has no serial port:
  # agetty fails ("Input/output error") and systemd restarts it every ~10s, five
  # journal entries per restart (most of journald's ~4 GB/day of writes, 2026-11-03).
  - systemctl mask --now serial-getty@ttyS0.service
  # unattended-upgrades caps logind's InhibitDelayMaxSec at 30s, which sorts after
  # the kubelet's own override and would cut graceful shutdown short. Mask it
  # before k3s starts (workaround from the Kubernetes node-shutdown docs).
  - mkdir -p /etc/systemd/logind.conf.d
  - ln -sf /dev/null /etc/systemd/logind.conf.d/unattended-upgrades-logind-maxdelay.conf
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - |
    if [ -n "${var.docker_hub_mirror}" ]; then
      mkdir -p /etc/rancher/k3s
      cat <<'MIRROR_EOF' > /etc/rancher/k3s/registries.yaml
      mirrors:
        "docker.io":
          endpoint:
            - "${var.docker_hub_mirror}"
    MIRROR_EOF
    fi
  # Commit-pinned and SHA-256-verified k3s installer (from tag v1.37.2+k3s1);
  # the installer itself verifies the downloaded k3s binary against GitHub's
  # published sha256sum-amd64.txt for INSTALL_K3S_VERSION.
  # cloud-init runs runcmd as one plain `sh` script without `set -e`, so each
  # step is chained with && and a failure (download, checksum mismatch or
  # install) exits the script: the unverified installer never runs, and
  # cloud-init stays enabled (the touch below is skipped) so the failure is
  # visible in /var/log/cloud-init-output.log and `cloud-init status`.
  # (`set -e` inside an `if` condition would be ignored, hence the chain.)
  - |
    if curl -fsSLo /tmp/k3s-install.sh https://raw.githubusercontent.com/k3s-io/k3s/f6973cb850e9b245585363d15bde80904ac862fd/install.sh &&
      echo "ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b  /tmp/k3s-install.sh" | sha256sum --check &&
      INSTALL_K3S_VERSION=${jsonencode(var.k3s_version)} sh /tmp/k3s-install.sh server; then
      rm -f /tmp/k3s-install.sh
    else
      rm -f /tmp/k3s-install.sh
      echo "k3s installation failed (download, installer checksum or install step); aborting runcmd" >&2
      exit 1
    fi
  # Cloud-init has done its job once k3s is installed. Without this, a Proxmox-side
  # stop/start after a snippet change gives the VM a new NoCloud instance-id and
  # re-runs this runcmd, re-installing k3s with the old pinned version and flags.
  - touch /etc/cloud/cloud-init.disabled
EOF
    file_name = "k3s-cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "k3s_node" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  agent {
    enabled = true
    trim    = true
    # Nothing reads the agent's IP addresses (the address is static, see the
    # k3s_node_ip output), but by default create and refresh waited up to 15m for
    # the agent to report one. On first boot the agent only starts after
    # package_upgrade, and a stopped VM made every plan wait out the timeout.
    wait_for_ip {
      disabled = true
    }
  }

  description     = "K3s Single Node Cluster managed by OpenTofu"
  tags            = ["kubernetes", "k3s"]
  stop_on_destroy = true
  on_boot         = true

  # This VM is the whole cluster, so an apply must never power it off on its own.
  # The provider default (true) shuts the VM down and starts it again whenever a
  # change is not hot-pluggable (cpu_cores, memory_size in either direction, rng,
  # agent, scsi_hardware, ip_config), and the plan shows only an in-place update.
  # With false the change is stored as pending and the apply ends with a warning;
  # it takes effect at the next Proxmox-side stop/start (`qm reboot <vm_id>` on the
  # host; a reboot from inside the guest does not apply pending changes). The
  # provider reads the configuration with pending changes applied, so later plans
  # are clean: `qm pending <vm_id>` shows what still waits for the restart.
  # A disk_size increase is applied online, but fails if it is combined with such
  # a change in one apply: resize the disk in its own apply.
  reboot_after_update = false

  scsi_hardware = "virtio-scsi-single"

  rng {
    source = "/dev/urandom"
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_size
    floating  = var.memory_size
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = proxmox_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = var.disk_size
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  initialization {
    # Explicit instead of the provider default (local-lvm), so a host without
    # local-lvm can place the cloud-init drive; the default keeps today's value.
    datastore_id = var.cloudinit_datastore_id

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id
  }

  network_device {
    bridge = var.network_bridge
    # One virtio-net queue pair per vCPU spreads RX/TX softirq work across all
    # cores. Proxmox applies a change on a running VM as a NIC hot-replug.
    queues = var.cpu_cores
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # This VM is the whole cluster: its root disk holds the k3s datastore (kine
    # state.db) and nothing backs it up yet (REL-02 in docs/BACKLOG.md). Any
    # plan that would destroy or replace it now fails instead of relying on someone
    # reading the plan. To rebuild or retire the node on purpose, remove this line,
    # apply, and restore it afterwards.
    prevent_destroy = true

    # user_data_file_id is ForceNew: never replace the node because the cloud-init
    # snippet changed. Snippet edits apply to new nodes; the running node is changed
    # by hand (docs/reports/REMEDIATION_PLAN_2026-10.md REL-00).
    # disk[0].file_id is ForceNew too: the root disk is a one-time copy of the cloud
    # image, so re-pinning or re-downloading the image must not rebuild the node
    # (the release-20260927 pin replaced the download and planned a VM replacement).
    ignore_changes = [tags, initialization[0].user_account, network_device[0].mac_address, initialization[0].user_data_file_id, disk[0].file_id]
  }
}

output "k3s_node_ip" {
  # The address is assigned statically through cloud-init, so take it from the input.
  # Indexing the guest agent's interface list (ipv4_addresses[1][0]) fails plan/destroy
  # with "Invalid index" whenever the agent is not reporting (VM stopped or still booting)
  # and silently depends on the NIC being the second interface.
  value       = split("/", var.ip_address)[0]
  description = "The IP address of the deployed VM"
}

output "k3s_node_build_id" {
  # Changes whenever the VM is recreated: Proxmox assigns a new MAC address to the
  # NIC of a new VM, while vm_id (k3s_node_id) stays the same. The kubeconfig
  # module re-fetches on a change of this value (new cluster CA and certs).
  value       = "${proxmox_virtual_environment_vm.k3s_node.id}-${proxmox_virtual_environment_vm.k3s_node.network_device[0].mac_address}"
  description = "An identifier that changes when the VM is rebuilt"
}

output "k3s_node_id" {
  value       = proxmox_virtual_environment_vm.k3s_node.id
  description = "The unique Proxmox ID of the virtual machine"
}
