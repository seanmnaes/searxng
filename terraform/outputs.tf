output "linode_ip" {
  description = "Public IP of the SearXNG instance"
  value       = tolist(linode_instance.searxng.ipv4)[0]
}

output "linode_ipv6" {
  description = "Public IPv6 of the SearXNG instance"
  value       = trimsuffix(linode_instance.searxng.ipv6, "/128")
}

output "searxng_url" {
  description = "URL for SearXNG"
  value       = "https://${var.domain}"
}
