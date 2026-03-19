output "linode_ip" {
  description = "Public IP of the SearXNG instance"
  value       = linode_instance.searxng.ip_address
}

output "searxng_url" {
  description = "URL for SearXNG"
  value       = "https://search.catlan.net"
}
