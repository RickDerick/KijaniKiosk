terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "local" {}

resource "null_resource" "kijanikiosk_api" {
  triggers = {
    ip = var.vm_ip
  }

  connection {
    type        = "ssh"
    host        = var.vm_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Connected to ${var.vm_name} (${var.environment})'",
      "uname -a",
      "lsb_release -a"
    ]
  }
}

resource "local_file" "inventory" {
  filename        = "${path.module}/inventory-${var.environment}.ini"
  file_permission = "0644"
  content         = <<-EOT
    [kijanikiosk_api]
    ${var.vm_name} ansible_host=${var.vm_ip} ansible_user=${var.ssh_user} ansible_ssh_private_key_file=${var.ssh_key_path}
  EOT
}
