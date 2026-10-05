variable "name" {
  description = "Multipass VM name (e.g. kijanikiosk-api)"
  type        = string
}

variable "image" {
  description = "Multipass image to launch (e.g. 22.04)"
  type        = string
}

variable "cpus" {
  description = "Number of virtual CPUs"
  type        = number
}

variable "memory" {
  description = "Memory size, Multipass format (e.g. 1G)"
  type        = string
}

variable "disk" {
  description = "Disk size, Multipass format (e.g. 8G)"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the public key to install for the ubuntu user"
  type        = string
}
