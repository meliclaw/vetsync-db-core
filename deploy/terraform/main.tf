# ==============================================================================
# VetSync PRD — Scaleway infrastructure
#
# Under IaC: compute, addressing, firewall, storage, backup bucket, IAM.
# NOT under IaC: Postgres data, Storage objects, application releases, and
# any secret value (secrets in variables end up in plaintext in the state).
# ==============================================================================

# ------------------------------------------------------------------- network
resource "scaleway_vpc" "main" {
  name       = var.name
  project_id = var.project_id
  region     = var.region
  tags       = var.tags
}

resource "scaleway_vpc_private_network" "main" {
  name       = "${var.name}-pn"
  vpc_id     = scaleway_vpc.main.id
  project_id = var.project_id
  region     = var.region
  tags       = var.tags
}

resource "scaleway_instance_ip" "v4" {
  project_id = var.project_id
  zone       = var.zone
  type       = "routed_ipv4"
  tags       = var.tags
}

resource "scaleway_instance_ip" "v6" {
  project_id = var.project_id
  zone       = var.zone
  type       = "routed_ipv6"
  tags       = var.tags
}

# ------------------------------------------------------------ security group
#
# Verified against the live project on 2026-08-09: the auto-created
# "Default security group" is STATEFUL, but its inbound default policy is
# ACCEPT with no rules — every inbound port is open at the Scaleway layer.
# Today only 22/80/443 answer because nothing else listens; that is luck,
# not a control.
#
# This group replaces it: stateful, inbound default DROP.
# Public surface is 443/tcp, 443/udp and 80/tcp. Postgres (5432), Supavisor
# (6543), Studio and SSH appear nowhere.
resource "scaleway_instance_security_group" "main" {
  name       = "${var.name}-sg"
  project_id = var.project_id
  zone       = var.zone
  tags       = var.tags

  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # --- HTTPS -----------------------------------------------------------
  inbound_rule {
    action   = "accept"
    port     = 443
    protocol = "TCP"
  }

  # HTTP/3 (QUIC)
  inbound_rule {
    action   = "accept"
    port     = 443
    protocol = "UDP"
  }

  # --- HTTP: ACME challenge and redirect to HTTPS only -----------------
  inbound_rule {
    action   = "accept"
    port     = 80
    protocol = "TCP"
  }

  # --- Tailscale direct connections (falls back to DERP if blocked) ----
  inbound_rule {
    action   = "accept"
    port     = 41641
    protocol = "UDP"
  }

  # --- Break-glass SSH, restricted by source ---------------------------
  #
  # Disabled by default. With enable_public_ssh = false no rule is emitted and,
  # because inbound_default_policy is "drop", TCP/22 is unreachable from the
  # internet. Administration arrives over Tailscale, which rides UDP/41641
  # above; recovery when the tailnet is down is the Scaleway serial console.
  dynamic "inbound_rule" {
    for_each = var.enable_public_ssh ? var.admin_ssh_cidrs : []
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # --- Outbound SMTP: deliberately NOT configured here --------------------
  #
  # Scaleway injects managed anti-abuse rules that DROP outbound 25/465/587,
  # and they are evaluated before any rule declared here. Adding "accept"
  # rules was tried on 2026-08-09 and verified ineffective from the host:
  #
  #   smtp.gmail.com:587        BLOCKED
  #   smtp.gmail.com:465        BLOCKED
  #   smtp-relay.brevo.com:2525 OPEN
  #   api.resend.com:443        OPEN
  #
  # Leaving dead accept rules here would imply a protection that does not
  # exist. GoTrue only speaks SMTP, so configure the provider on port 2525
  # (Brevo, Mailtrap, SendGrid and others offer it) via SMTP_PORT in
  # /etc/vetsync/prd.env. Unblocking 587 requires a Scaleway support request.
}

# -------------------------------------------------------------- data volume
#
# NOT CREATED. The operator decided on 2026-08-09 to run on a single volume
# with moderate monitoring, so /srv shares the 138 GB root device and the
# disk guard timer (host-bootstrap.sh step 5) watches it.
#
# Declaring the resource anyway would make `tofu apply` create a volume that
# nothing mounts and that still bills. To reverse the decision, restore this
# block, add its id to additional_volume_ids, then partition and mount /srv
# on the host before moving any data.
#
# resource "scaleway_block_volume" "data" {
#   name       = "${var.name}-data"
#   project_id = var.project_id
#   zone       = var.zone
#   iops       = var.data_volume_iops
#   size_in_gb = var.data_volume_size_gb
#   tags       = var.tags
#   lifecycle { prevent_destroy = true }
# }

# ----------------------------------------------------------------- instance
resource "scaleway_instance_server" "main" {
  name       = var.name
  project_id = var.project_id
  zone       = var.zone
  type       = var.instance_type
  image      = var.image
  tags       = var.tags

  ip_ids = [
    scaleway_instance_ip.v4.id,
    scaleway_instance_ip.v6.id,
  ]

  security_group_id = scaleway_instance_security_group.main.id

  root_volume {
    volume_type = "sbs_volume"
    size_in_gb  = var.root_volume_size_gb
    sbs_iops    = 5000

    # MUST stay true. The provider defaults this to false, and the first plan
    # against the imported instance showed `boot = true -> false`, which would
    # have left a running production host unable to boot on next restart.
    boot = true

    # Keep the OS disk if the server resource is replaced.
    delete_on_termination = false
  }

  # Single-volume decision (2026-08-09): no additional volumes.
  # additional_volume_ids = [scaleway_block_volume.data.id]

  user_data = {
    cloud-init = file(var.cloud_init_path)
  }

  private_network {
    pn_id = scaleway_vpc_private_network.main.id
  }

  lifecycle {
    # Editing cloud-init must never silently rebuild a production host with
    # live data attached. Apply changes to a fresh instance and cut over.
    ignore_changes = [user_data, image]
  }
}

# --------------------------------------------------------- backup bucket
resource "scaleway_object_bucket" "backups" {
  name       = var.backup_bucket_name
  project_id = var.project_id
  region     = var.region
  tags       = { environment = "prd", app = "vetsync" }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Backups must never be world-readable. Enforced, not assumed.
resource "scaleway_object_bucket_acl" "backups" {
  bucket = scaleway_object_bucket.backups.id
  acl    = "private"
}

# NOTE on the two resources that used to live here (removed 2026-08-09 after
# both failed against the live API):
#
#   scaleway_object_bucket_policy
#     Rejected with MalformedPolicy. Scaleway's S3 policy engine only accepts
#     aws:Referer, aws:SourceIp, s3:if-match, s3:if-none-match, s3:prefix and
#     the s3:x-amz-server-side-encryption-* keys as conditions. There is no
#     scw:ApplicationId condition, so "deny everyone except the backup agent"
#     is not expressible. Access control here is the private ACL above plus the
#     scoped IAM policy below.
#
#   scaleway_object_bucket_server_side_encryption_configuration
#     Rejected with SignatureDoesNotMatch (403) on PutBucketEncryption; the
#     endpoint is not usable this way. This costs nothing in practice: backup.sh
#     encrypts every archive with age BEFORE upload, using a public key whose
#     private half is kept off the VPS. Object Storage never sees plaintext.

# ------------------------------------------------------------------- IAM
#
# The host writes backups with a credential scoped to Object Storage only.
# It cannot create servers, read other buckets, or alter infrastructure.
resource "scaleway_iam_application" "backup_agent" {
  name        = "${var.name}-backup-agent"
  description = "Writes encrypted VetSync backups to Object Storage."
}

resource "scaleway_iam_policy" "backup_agent" {
  name           = "${var.name}-backup-agent"
  description    = "Object Storage write access, scoped to the VetSync project."
  application_id = scaleway_iam_application.backup_agent.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageObjectsWrite"]
  }
}

resource "scaleway_iam_api_key" "backup_agent" {
  application_id     = scaleway_iam_application.backup_agent.id
  description        = "VetSync PRD backup agent"
  default_project_id = var.project_id

  # The organization's security settings REQUIRE an expiry on API keys; the
  # first apply failed without it. Rotating this key means updating
  # BACKUP_S3_ACCESS_KEY / BACKUP_S3_SECRET_KEY in /etc/vetsync/prd.env —
  # put the date in the calendar, because backups fail silently otherwise.
  expires_at = var.backup_agent_key_expires_at
}
