variable "ip_address" {
  type = string
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "kubeconfig_path" {
  type    = string
  default = "./kubeconfig.yaml"
}

variable "vm_recreate_id" {
  type        = string
  description = "Changes whenever the VM is recreated (proxmox module output k3s_node_build_id); a change re-fetches the kubeconfig"
}
