terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "local" {}

resource "local_file" "inventory" {
  filename = "${path.module}/inventory-${var.environment}.ini"
  content  = <<-EOT
    [kijanikiosk_api]
    ${var.vm_name} ansible_host=${var.vm_ip} ansible_user=${var.ssh_user} ansible_ssh_private_key_file=${var.ssh_key_path}
  EOT
}
