output "name" {
  description = "VM name"
  value       = terraform_data.vm.output.name
}

output "ip" {
  description = "VM IPv4 address, read live from Multipass"
  value       = data.external.vm_info.result.ip
}
