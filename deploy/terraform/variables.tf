variable "project_id" {
  description = "Scaleway project UUID."
  type        = string
}

variable "zone" {
  description = "Availability zone. The existing instance lives in nl-ams-1."
  type        = string
  default     = "nl-ams-1"
}

variable "region" {
  description = "Region for regional resources (Object Storage, VPC)."
  type        = string
  default     = "nl-ams"
}

variable "name" {
  description = "Instance and resource name prefix."
  type        = string
  default     = "vetsync-vet-br-prd"
}

variable "instance_type" {
  description = <<-EOT
    Scaleway commercial type. BASIC2-A4C-16G is ARM64 (Ampere):
    4 vCPU / 16 GB / 400 Mbps. All eleven Supabase images plus Caddy
    publish arm64 manifests, so the stack runs natively.
  EOT
  type        = string
  default     = "BASIC2-A4C-16G"
}

variable "image" {
  description = "Base image label."
  type        = string
  default     = "ubuntu_noble"
}

variable "root_volume_size_gb" {
  description = "Root volume size in GB. Must match the live volume: shrinking is not supported and the plan would attempt a destructive change."
  type        = number
  default     = 150
}

variable "data_volume_size_gb" {
  description = <<-EOT
    Dedicated block volume mounted at /srv for Postgres, Storage objects and
    WAL archive. Separate from the boot volume so snapshots and resizes do not
    touch the operating system.
  EOT
  type        = number
  default     = 110
}

variable "data_volume_iops" {
  description = "Block Storage IOPS class: 5000 or 15000."
  type        = number
  default     = 5000
}

variable "admin_ssh_cidrs" {
  description = <<-EOT
    Source ranges allowed to reach TCP/22 as break-glass access.
    Only consulted when enable_public_ssh is true. Defaults to empty because
    the operator chose (2026-08-09) to keep port 22 off the public internet.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.admin_ssh_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open SSH to the whole internet. Use Tailscale for administration."
  }
}

variable "enable_public_ssh" {
  description = <<-EOT
    Whether TCP/22 is reachable from the internet at all.

    Decision of 2026-08-09: false. Administration goes over Tailscale
    (WireGuard on UDP/41641, which the security group does allow), and the
    Scaleway serial console is the recovery path when the tailnet is down —
    it works over the hypervisor, not the network, so it survives a firewall
    or Tailscale failure.

    Setting this to true without a narrow admin_ssh_cidrs list re-exposes SSH.
  EOT
  type        = bool
  default     = false
}

variable "cloud_init_path" {
  description = "Path to the cloud-init user-data file."
  type        = string
  default     = "../cloud-init/vetsync-prd.yaml"
}

variable "backup_bucket_name" {
  description = "Object Storage bucket for encrypted off-box backups."
  type        = string
  default     = "vetsync-prd-backups"
}

variable "backup_retention_days" {
  description = "Lifecycle expiry for backup objects."
  type        = number
  default     = 120
}

variable "tags" {
  description = <<-EOT
    Tags applied to taggable resources. These mirror the tags the instance was
    created with; replacing them with a shorter generic set would lose the
    project/owner/stack metadata used for cost attribution.
  EOT
  type        = list(string)
  default = [
    "project:vetsync-vet",
    "env:prd",
    "role:cpu-instance",
    "stack:supabase",
    "stack:webapp",
    "arch:arm64",
    "owner:wapnet",
  ]
}

variable "backup_agent_key_expires_at" {
  description = <<-EOT
    RFC3339 expiry for the backup agent API key. The organization's security
    settings make this mandatory — the first apply failed without it.

    When it expires, backup.sh starts failing to upload. Renew the key and
    update BACKUP_S3_ACCESS_KEY / BACKUP_S3_SECRET_KEY in /etc/vetsync/prd.env.
  EOT
  type        = string
  default     = "2027-08-09T00:00:00Z"
}
