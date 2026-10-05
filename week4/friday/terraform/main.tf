# One module call, three servers. Each key in var.servers becomes one VM.
module "app_server" {
  source   = "./modules/app_server"
  for_each = var.servers

  name                = "${var.name_prefix}-${each.key}"
  image               = var.vm_image
  cpus                = each.value.cpus
  memory              = each.value.memory
  disk                = each.value.disk
  ssh_public_key_path = var.ssh_public_key_path
}
