# ==============================================================================
# VetSync PRD — OpenTofu / Terraform, Scaleway provider
#
# OpenTofu is preferred over Terraform here: MPL licence, same Scaleway
# provider, and native S3 state locking (`use_lockfile`) with no extra
# lock table to operate.
#
#   tofu init -backend-config=backend.hcl
#   tofu plan  -var-file=prd.tfvars
#   tofu apply -var-file=prd.tfvars
# ==============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.57"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State lives in Scaleway Object Storage, encrypted and versioned.
  # Values come from backend.hcl, which is NOT committed.
  backend "s3" {
    # bucket   = "vetsync-tfstate"
    # key      = "prd/terraform.tfstate"
    # region   = "nl-ams"
    # endpoints = { s3 = "https://s3.nl-ams.scw.cloud" }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    # Native lockfile — no DynamoDB equivalent required.
    use_lockfile = true
  }
}

provider "scaleway" {
  # Credentials come from the environment, never from a .tf file:
  #   SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_ORGANIZATION_ID
  project_id = var.project_id
  zone       = var.zone
  region     = var.region
}
