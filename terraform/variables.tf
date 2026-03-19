variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID"
  type        = string
}

variable "root_password" {
  description = "Root password for the Linode instance"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for access to the Linode instance"
  type        = string
}

variable "cloudflare_origin_ca_key" {
  description = "Cloudflare Origin CA key"
  type        = string
  sensitive   = true
}
