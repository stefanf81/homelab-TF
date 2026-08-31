# Ubuntu 26.04 (Resolute) Cloud Image, pinned to the 2026-08-23 release image.
resource "proxmox_download_file" "ubuntu_cloud_image" {
  content_type        = "iso"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud-images.ubuntu.com/releases/resolute/release-20260823/ubuntu-26.04-server-cloudimg-amd64.img"
  checksum            = "8196be9d7958059cb56c6c75c80fdf6cee8a8885bc149ea791d7db1c7ef93035"
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
  - qemu-guest-agent
  - curl
  - nfs-common
  - open-iscsi
  - jq

write_files:
  - path: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.ipv4.ip_forward = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      fs.inotify.max_user_instances = 8192
      fs.inotify.max_user_watches = 524288
      vm.max_map_count = 262144
      fs.file-max = 2097152
      fs.aio-max-nr = 1048576
      vm.swappiness = 1

  - path: /etc/multipath.conf
    content: |
      defaults {
          user_friendly_names yes
      }
      blacklist {
          devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
          devnode "^hd[a-z]"
          devnode "^sda[0-9]*"
          devnode "^longhorn"
          devnode "^sd[a-z]"
      }

runcmd:
  - swapoff -a
  - sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  - sysctl --system
  - sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=100M/' /etc/systemd/journald.conf
  - systemctl restart systemd-journald
  - systemctl enable iscsid
  - systemctl start iscsid
  - systemctl restart multipathd || true
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
  - curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} K3S_TOKEN=${var.k3s_token} sh -s - server --tls-san=${split("/", var.ip_address)[0]} --kubelet-arg="system-reserved=cpu=200m,memory=500Mi" --kubelet-arg="kube-reserved=cpu=200m,memory=500Mi" --node-label="topology.kubernetes.io/region=homelab" --node-label="topology.kubernetes.io/zone=${var.proxmox_node}" --disable servicelb --disable traefik --disable coredns --disable metrics-server --flannel-backend=none --disable-network-policy
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
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [tags, initialization[0].user_account, network_device[0].mac_address]
  }
}

output "k3s_node_ip" {
  value       = proxmox_virtual_environment_vm.k3s_node.ipv4_addresses[1][0]
  description = "The IP address of the deployed VM"
}

output "k3s_node_id" {
  value       = proxmox_virtual_environment_vm.k3s_node.id
  description = "The unique Proxmox ID of the virtual machine"
}
