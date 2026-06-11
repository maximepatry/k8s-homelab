output "control_plane_ips" {
  value = { for k, v in module.control_plane : k => v.ip_address }
}

output "worker_ips" {
  value = { for k, v in module.worker : k => v.ip_address }
}
