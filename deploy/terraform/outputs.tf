output "public_ipv4" {
  description = "Public IPv4 — the address the DNS A records must point to."
  value       = scaleway_instance_ip.v4.address
}

output "public_ipv6" {
  description = "Public IPv6. Publish AAAA records only after Caddy is verified on v6."
  value       = scaleway_instance_ip.v6.address
}

output "instance_id" {
  value = scaleway_instance_server.main.id
}

# data_volume_id removed: single-volume decision of 2026-08-09.

output "backup_bucket" {
  value = scaleway_object_bucket.backups.name
}

output "backup_agent_access_key" {
  description = "Object Storage access key for the backup agent."
  value       = scaleway_iam_api_key.backup_agent.access_key
  sensitive   = true
}

output "backup_agent_secret_key" {
  description = <<-EOT
    Object Storage secret key. Read once with:
      tofu output -raw backup_agent_secret_key
    Write it straight into /etc/vetsync/prd.env on the host. Do not echo it
    into shell history or a file in the repository.
  EOT
  value       = scaleway_iam_api_key.backup_agent.secret_key
  sensitive   = true
}

output "dns_records_required" {
  description = "Records to create at registro.br / HostGator WHM."
  value = {
    "app.vetsync.com.br"     = "A -> ${scaleway_instance_ip.v4.address} (TTL 300)"
    "admin.vetsync.com.br"   = "A -> ${scaleway_instance_ip.v4.address} (TTL 300)"
    "api.vetsync.com.br"     = "A -> ${scaleway_instance_ip.v4.address} (TTL 300)"
    "console.vetsync.com.br" = "NO public record — Studio is served over Tailscale only"
  }
}
