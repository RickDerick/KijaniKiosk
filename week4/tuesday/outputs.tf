output "api_server_ip" {
  description = "IP address of the KijaniKiosk API server (Multipass VM)"
  value       = var.vm_ip
}

output "ssh_command" {
  description = "SSH command to connect to the API server"
  value       = "ssh -i ${var.ssh_key_path} ${var.ssh_user}@${var.vm_ip}"
}

output "inventory_file" {
  description = "Path to the generated inventory file"
  value       = local_file.inventory.filename
}
