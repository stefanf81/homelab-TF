terraform {
  # 1.12 is the oldest release line that still gets fixes (1.8 to 1.11 are end of life).
  required_version = ">= 1.12.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.122.0"
    }
  }
}
