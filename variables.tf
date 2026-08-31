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
  description = "The static IP address and CIDR for the VM (e.g. 192.168.1.50/24)"
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
  default     = 14336
}

variable "disk_size" {
  type        = number
  description = "Size of the root disk in Gigabytes"
  default     = 100
}

variable "ssh_user" {
  type        = string
  description = "The SSH user used to connect to the k3s node"
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
  default     = "v1.36.4+k3s1"
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
