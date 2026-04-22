output "server_id" {
  value       = hcloud_server.this.id
  description = "Hetzner server id."
}

output "server_name" {
  value       = hcloud_server.this.name
  description = "Hetzner server name."
}

output "ipv4_address" {
  value       = hcloud_server.this.ipv4_address
  description = "Public IPv4 address."
}

output "ipv6_address" {
  value       = hcloud_server.this.ipv6_address
  description = "Public IPv6 address."
}

output "firewall_id" {
  value       = hcloud_firewall.edge.id
  description = "Hetzner firewall id."
}

output "volume_id" {
  value       = hcloud_volume.data.id
  description = "Persistent data volume id."
}

output "volume_linux_device_path" {
  value       = local.volume_linux_device_path
  description = "Expected Linux device path for the attached Hetzner volume."
}
