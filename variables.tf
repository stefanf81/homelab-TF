variable "proxmox_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox API (e.g. https://192.168.1.100:8006/)"
}

variable "proxmox_api_token" {
  type        = string
  description = "The API token for Proxmox (e.g. user@pam!token_id=secret)"
  sensitive   = true
}

variable "proxmox_insecure" {
  type        = bool
  description = "Allow insecure (TLS-verification-skipped) connections to the Proxmox API. SAFE ONLY for homelabs using Proxmox's self-signed cert. Set to false (and trust the cert / use a CA) for any non-trivial environment — leaving this true disables MITM protection for API tokens."
  default     = true
}

variable "proxmox_node" {
  type        = string
  description = "The name of the Proxmox node to deploy the VM to"
}

variable "datastore_id" {
  type        = string
  description = "The datastore to use for the VM disk (e.g. local-lvm or local-zfs)"
  default     = "local-lvm"
}

variable "cloudinit_datastore_id" {
  type        = string
  description = "The datastore for the VM's cloud-init drive. Defaults to local-lvm, the provider's previous implicit choice, so existing VMs see no change; set it when the host has no local-lvm (e.g. local-zfs)."
  default     = "local-lvm"
}

variable "network_bridge" {
  type        = string
  description = "The network bridge to attach the VM to"
  default     = "vmbr0"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to inject into the VM"
}

variable "vm_name" {
  type        = string
  description = "Name of the VM"
  default     = "k3s-node-01"
}

variable "vm_id" {
  type        = number
  description = "ID of the VM"
  default     = 900
}

variable "ip_address" {
  type        = string
  description = "The static IP address and CIDR for the VM (e.g. 192.168.1.50/24). Set once: cloud-init is disabled after the first boot, so a change is not applied inside the running guest (and the kubeconfig fetch would then wait on the new address)."

  validation {
    condition     = can(cidrhost(var.ip_address, 0))
    error_message = "ip_address must include the prefix length, e.g. 192.168.1.50/24."
  }
}

variable "gateway" {
  type        = string
  description = "The gateway IP address (e.g. 192.168.1.1)"
}

variable "cpu_cores" {
  type        = number
  description = "Number of CPU cores to allocate to the VM"
  default     = 6
}

variable "memory_size" {
  type        = number
  description = "Amount of memory in Megabytes to allocate to the VM"
  # 12 GiB on the 15 GiB host: at 14 GiB the host swapped ~2.2 GiB, 661 MiB of it guest
  # memory (docs/NODE_HOST_TUNING.md, host memory). Pod requests are ~8.5 GiB.
  default = 12288
}

variable "disk_size" {
  type        = number
  description = "Size of the root disk in Gigabytes. Raising it grows the Proxmox disk only: cloud-init is disabled after the first boot, so grow the partition and filesystem on the node (growpart /dev/sda 1 && resize2fs /dev/sda1)."
  default     = 100
}

variable "ssh_user" {
  type        = string
  description = "The user cloud-init creates on the node (SSH key, passwordless sudo) and the kubeconfig fetch logs in as"
  default     = "ubuntu"
}

variable "k3s_token" {
  type        = string
  description = "The token for k3s cluster authentication"
  sensitive   = true
}

variable "k3s_version" {
  type        = string
  description = "The k3s release to install on newly provisioned nodes"
  # renovate: datasource=github-releases depName=k3s-io/k3s
  default = "v1.37.2+k3s1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must look like v1.37.2+k3s1 (the INSTALL_K3S_VERSION format)."
  }
}

variable "docker_hub_mirror" {
  type        = string
  description = "Optional URL for a Docker Hub mirror registry (e.g. https://mirror.gcr.io)"
  default     = ""
}

variable "kubeconfig_path" {
  type        = string
  description = "Where to store the kubeconfig fetched from the k3s node"
  default     = "./kubeconfig.yaml"
}
