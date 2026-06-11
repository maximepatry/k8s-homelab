output "ip_address" {
  value = var.ip_address
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.worker.vm_id
}
