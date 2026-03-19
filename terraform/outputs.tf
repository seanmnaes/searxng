output "linode_ip" {
  description = "Public IP of the SearXNG instance"
  value       = tolist(linode_instance.searxng.ipv4)[0]
}

output "searxng_url" {
  description = "URL for SearXNG"
  value       = "https://search.catlan.net"
}
