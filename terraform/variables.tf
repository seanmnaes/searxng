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

variable "cloudflare_origin_ca_key" {
  description = "Cloudflare Origin CA key"
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

variable "domain" {
  description = "Domain name for SearXNG (e.g., search.example.com)"
  type        = string
}

variable "deploy_timestamp" {
  description = "Timestamp to force redeployment (set automatically by CI)"
  type        = string
  default     = ""
}
