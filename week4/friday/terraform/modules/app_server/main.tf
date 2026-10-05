locals {
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# terraform_data is built into Terraform (no provider needed).
# It represents the VM's lifecycle: launch on create, delete on destroy.
resource "terraform_data" "vm" {
  input = {
    name   = var.name
    image  = var.image
    cpus   = var.cpus
    memory = var.memory
    disk   = var.disk
  }

  # Any change to the VM's definition replaces it (Multipass cannot resize in place).
  triggers_replace = {
    name   = var.name
    image  = var.image
    cpus   = var.cpus
    memory = var.memory
    disk   = var.disk
    key    = sha256(local.public_key)
  }

  # Create: launch only if the VM does not already exist, then make sure
  # our SSH key is authorised (grep guard keeps it idempotent).
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if multipass info ${self.input.name} >/dev/null 2>&1; then
        echo "VM ${self.input.name} already exists - not relaunching"
      else
        multipass launch ${self.input.image} \
          --name ${self.input.name} \
          --cpus ${self.input.cpus} \
          --memory ${self.input.memory} \
          --disk ${self.input.disk}
      fi
      multipass exec ${self.input.name} -- bash -c \
        "grep -qxF '${local.public_key}' ~/.ssh/authorized_keys || echo '${local.public_key}' >> ~/.ssh/authorized_keys"
    EOT
  }

  # Destroy: delete and purge the VM. Guarded so a VM that is already gone
  # does not make destroy fail.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      if multipass info ${self.input.name} >/dev/null 2>&1; then
        multipass delete --purge ${self.input.name}
      else
        echo "VM ${self.input.name} already absent"
      fi
    EOT
  }
}

# Read the VM's IP from Multipass at plan/apply time instead of hardcoding it.
# depends_on defers the read until the VM exists on the first run.
data "external" "vm_info" {
  program = ["python3", "${path.module}/get_vm_ip.py"]

  query = {
    name = var.name
  }

  depends_on = [terraform_data.vm]
}
