variable "pve_endpoint" {
  type = string
}

variable "pve_api_token" {
  type      = string
  sensitive = true
}

variable "template_id" {
  type        = number
  description = "cloud-init template VM id"
}

variable "ssh_pubkey" {
  type = string
}
