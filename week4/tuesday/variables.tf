variable "vm_name" {
  description = "Name of the Multipass VM running KijaniKiosk"
  type        = string
  default     = "kijanikiosk-api"
}

variable "vm_ip" {
  description = "IPv4 address of the Multipass VM (from 'multipass info')"
  type        = string
  # No default: must be provided explicitly
}

variable "ssh_user" {
  description = "SSH user on the VM"
  type        = string
  default     = "ubuntu"
}

variable "ssh_key_path" {
  description = "Path to the private SSH key used to reach the VM"
  type        = string
  default     = "~/.ssh/kijanikiosk"
}

variable "environment" {
  description = "Deployment environment: staging or production"
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Environment must be staging or production."
  }
}
