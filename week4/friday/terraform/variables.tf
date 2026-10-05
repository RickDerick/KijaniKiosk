variable "environment" {
  description = "Deployment environment: staging or production"
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Environment must be staging or production."
  }
}

variable "name_prefix" {
  description = "Prefix for every VM name (e.g. kijanikiosk -> kijanikiosk-api)"
  type        = string
  default     = "kijanikiosk"
}

variable "vm_image" {
  description = "Multipass image for all servers (the Multipass equivalent of an AMI lookup)"
  type        = string
  default     = "22.04"
}

variable "servers" {
  description = "Servers to create, keyed by role. Size values are the Multipass equivalent of an instance type."
  type = map(object({
    cpus   = number
    memory = string
    disk   = string
  }))
  # No default: server sizing is environment-specific and must be set in tfvars
}

variable "ssh_user" {
  description = "Default login user on the Ubuntu images"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Public key installed on every VM (the Multipass equivalent of ssh_key_name)"
  type        = string
  default     = "~/.ssh/kijanikiosk.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, used only to build the SSH command outputs"
  type        = string
  default     = "~/.ssh/kijanikiosk"
}
