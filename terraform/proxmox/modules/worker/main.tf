resource "proxmox_virtual_environment_vm" "worker" {
  name      = var.name
  node_name = var.proxmox_node
  vm_id     = null

  clone {
    vm_id = data.proxmox_virtual_environment_vms.template.vms[0].vm_id
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  # OS disk
  disk {
    datastore_id = "local-lvm"
    size         = var.os_disk_gb
    interface    = "scsi0"
    discard      = "on"
    ssd          = true
  }

  # Longhorn data disk — raw, unformatted
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      datastore_id = "local-lvm"
      size         = var.data_disk_gb
      interface    = "scsi1"
      discard      = "on"
      ssd          = true
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.ip_address}/24"
        gateway = var.gateway
      }
    }
    user_account {
      keys     = [var.ssh_public_key]
      username = "rocky"
    }
  }

  operating_system {
    type = "l26"
  }
}

data "proxmox_virtual_environment_vms" "template" {
  node_name = var.proxmox_node
  tags      = ["template"]

  filter {
    name   = "name"
    values = [var.vm_template]
  }
}
