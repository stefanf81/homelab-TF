locals {
  # var.ip_address may be plain (192.168.1.50) or CIDR (192.168.1.50/24);
  # strip any CIDR suffix so it can be used for SSH purposes.
  node_ip = split("/", var.ip_address)[0]
}

# k3s itself is installed at boot time via cloud-init in the ../proxmox
# module. This module's only job is to wait for that install to finish and
# pull the generated kubeconfig back to the machine running OpenTofu.
resource "null_resource" "fetch_kubeconfig" {
  triggers = {
    ip_address      = local.node_ip
    ssh_user        = var.ssh_user
    kubeconfig_path = abspath(var.kubeconfig_path)
    vm_recreate_id  = var.vm_recreate_id
  }

  provisioner "local-exec" {
    # SECURITY NOTE: StrictHostKeyChecking is disabled and UserKnownHostsFile=/dev/null so
    # the first boot (unknown host key) doesn't hang. This is acceptable for a single-node
    # homelab but is MITM-exposed. For anything shared, pin the host key: capture it from
    # the VM's cloud-init (echo /etc/ssh/ssh_host_ed25519_key.pub) and use a known_hosts file.
    command = <<-EOT
      set -euo pipefail
      SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
      SSH_TARGET='${var.ssh_user}@${local.node_ip}'

      until ssh $SSH_OPTS "$SSH_TARGET" 'sudo test -f /etc/rancher/k3s/k3s.yaml'; do
        echo "Waiting for cloud-init to finish installing k3s on ${local.node_ip}..."
        sleep 5
      done

      ssh $SSH_OPTS "$SSH_TARGET" 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed 's|127.0.0.1|${local.node_ip}|g' \
        > '${abspath(var.kubeconfig_path)}'

      chmod 600 '${abspath(var.kubeconfig_path)}'
      echo "Kubeconfig fetched successfully: ${abspath(var.kubeconfig_path)}"
    EOT
  }
}

output "kubeconfig_path" {
  value       = abspath(var.kubeconfig_path)
  description = "Absolute path to the downloaded kubeconfig file"
}

output "node_ip" {
  value       = local.node_ip
  description = "The node IP used to fetch the kubeconfig"
}
