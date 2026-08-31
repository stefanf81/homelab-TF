variable "proxmox_node" {
  type = string
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "ssh_public_key" {
  type = string
}

variable "vm_name" {
  type    = string
  default = "k3s-node-01"
}

variable "vm_id" {
  type    = number
  default = 900
}

variable "ip_address" {
  type = string
}

variable "gateway" {
  type = string
}

variable "cpu_cores" {
  type    = number
  default = 6
}

variable "memory_size" {
  type    = number
  default = 14336
}

variable "disk_size" {
  type    = number
  default = 100
}

variable "k3s_token" {
  type      = string
  sensitive = true
}

variable "k3s_version" {
  type = string
}

variable "docker_hub_mirror" {
  type    = string
  default = ""
}
