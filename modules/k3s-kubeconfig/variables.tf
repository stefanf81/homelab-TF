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
  description = "Dependency trigger to track VM recreation"
}
