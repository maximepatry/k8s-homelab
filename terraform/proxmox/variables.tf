variable "proxmox_endpoint" {
  description = "Proxmox API endpoint (e.g. https://192.168.1.10:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API user (e.g. terraform@pve)"
  type        = string
  default     = "terraform@pve"
}

variable "proxmox_password" {
  description = "Proxmox API password"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification (true for self-signed certs)"
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "SSH public key injected into VMs via cloud-init"
  type        = string
}

variable "vm_template" {
  description = "Proxmox template name to clone (Ubuntu 24.04 cloud image)"
  type        = string
  default     = "ubuntu-2404-cloud"
}

variable "nodes" {
  description = "Proxmox node names mapped to their roles"
  type = map(object({
    proxmox_node = string
    role         = string   # control-plane | worker
    cores        = number
    memory_mb    = number
    os_disk_gb   = number
    data_disk_gb = number   # Longhorn disk (workers only, 0 to skip)
    ip_address   = string
    gateway      = string
  }))
  default = {
    n150-cp = {
      proxmox_node = "n150"
      role         = "control-plane"
      cores        = 3
      memory_mb    = 10240
      os_disk_gb   = 40
      data_disk_gb = 0
      ip_address   = "192.168.1.101"
      gateway      = "192.168.1.1"
    }
    ser5-worker-1 = {
      proxmox_node = "ser5-1"
      role         = "worker"
      cores        = 10
      memory_mb    = 28672
      os_disk_gb   = 60
      data_disk_gb = 400
      ip_address   = "192.168.1.102"
      gateway      = "192.168.1.1"
    }
    ser5-worker-2 = {
      proxmox_node = "ser5-2"
      role         = "worker"
      cores        = 10
      memory_mb    = 28672
      os_disk_gb   = 60
      data_disk_gb = 400
      ip_address   = "192.168.1.103"
      gateway      = "192.168.1.1"
    }
  }
}
