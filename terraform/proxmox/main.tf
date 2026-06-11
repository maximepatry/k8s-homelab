locals {
  control_planes = { for k, v in var.nodes : k => v if v.role == "control-plane" }
  workers        = { for k, v in var.nodes : k => v if v.role == "worker" }
}

module "control_plane" {
  for_each = local.control_planes
  source   = "./modules/control-plane"

  name         = each.key
  proxmox_node = each.value.proxmox_node
  cores        = each.value.cores
  memory_mb    = each.value.memory_mb
  os_disk_gb   = each.value.os_disk_gb
  ip_address   = each.value.ip_address
  gateway      = each.value.gateway
  vm_template  = var.vm_template
  ssh_public_key = var.ssh_public_key
}

module "worker" {
  for_each = local.workers
  source   = "./modules/worker"

  name         = each.key
  proxmox_node = each.value.proxmox_node
  cores        = each.value.cores
  memory_mb    = each.value.memory_mb
  os_disk_gb   = each.value.os_disk_gb
  data_disk_gb = each.value.data_disk_gb
  ip_address   = each.value.ip_address
  gateway      = each.value.gateway
  vm_template  = var.vm_template
  ssh_public_key = var.ssh_public_key
}
