module "proxmox" {
  source = "./modules/proxmox"

  proxmox_node      = var.proxmox_node
  datastore_id      = var.datastore_id
  network_bridge    = var.network_bridge
  ssh_public_key    = var.ssh_public_key
  vm_name           = var.vm_name
  vm_id             = var.vm_id
  ip_address        = var.ip_address
  gateway           = var.gateway
  cpu_cores         = var.cpu_cores
  memory_size       = var.memory_size
  disk_size         = var.disk_size
  k3s_token         = var.k3s_token
  k3s_version       = var.k3s_version
  docker_hub_mirror = var.docker_hub_mirror
}

module "k3s_kubeconfig" {
  source = "./modules/k3s-kubeconfig"

  ip_address      = module.proxmox.k3s_node_ip
  vm_recreate_id  = module.proxmox.k3s_node_id
  ssh_user        = var.ssh_user
  kubeconfig_path = var.kubeconfig_path

  depends_on = [module.proxmox]
}


