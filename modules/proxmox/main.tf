# Ubuntu 26.04 (Resolute) Cloud Image, pinned to the 2026-09-27 release image.
resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud-images.ubuntu.com/releases/resolute/release-20260927/ubuntu-26.04-server-cloudimg-amd64.img"
  checksum            = "8800651811af9a85465ad1d552add729947bb16488dddb4a9b5305a3d97332b2"
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
  - name: ubuntu
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

runcmd:
  # Load the runtime attachment before K3s starts; container profiles stay enforced.
  - apparmor_parser -r /etc/apparmor.d/runc
  - swapoff -a
  - sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  - sysctl --system
  - sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=100M/' /etc/systemd/journald.conf
  - systemctl restart systemd-journald
  - udevadm control --reload-rules
  - udevadm trigger --subsystem-match=block --action=change
  # Not needed on a k3s node: storage is Proxmox CSI (virtio disks, no iSCSI or
  # multipath), and snapd/motd-news only add background wakeups.
  - systemctl disable --now multipathd.service multipathd.socket snapd.service snapd.socket snapd.seeded.service motd-news.timer || true
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
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} K3S_TOKEN='${var.k3s_token}' sh -s - server --tls-san=${split("/", var.ip_address)[0]} --kubelet-arg="system-reserved=cpu=200m,memory=500Mi" --kubelet-arg="kube-reserved=cpu=200m,memory=500Mi" --node-label="topology.kubernetes.io/region=homelab" --node-label="topology.kubernetes.io/zone=${var.proxmox_node}" --disable servicelb --disable traefik --disable coredns --disable metrics-server --disable local-storage --flannel-backend=none --disable-network-policy --disable-kube-proxy
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
  }

  description     = "K3s Single Node Cluster managed by OpenTofu"
  tags            = ["kubernetes", "k3s"]
  stop_on_destroy = true
  on_boot         = true

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

output "k3s_node_id" {
  value       = proxmox_virtual_environment_vm.k3s_node.id
  description = "The unique Proxmox ID of the virtual machine"
}
