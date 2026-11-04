# Customer-side data plane of ONE Kiro account of an AWS Organization (patch P10).
# Use it for each member account and, later, for the management account.
#
#   terraform init -backend-config="path=../../../customers/<slug>/state-<account-slug>/terraform.tfstate"
#   terraform plan -var-file=../../../customers/<slug>/<account-slug>.tfvars
#
# One state per account. Every apply is a per-run confirmation task.
# The provider enters the account through OrganizationAccountAccessRole from the
# payer profile, and refuses to run in any other account (allowed_account_ids).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
  }
  backend "local" {}
}

variable "account_id" {
  description = "The Kiro account this root builds in."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

variable "slug" {
  description = "Short label of the account, for example kiro01."
  type        = string
}

variable "lake_region" {
  description = "Region of the lake, the Glue catalog and the Lambda. Must equal the dashboard account's Region: Athena reads another account's catalog only in the same Region."
  type        = string
  default     = "ap-southeast-1"
}

variable "report_region" {
  description = "Region of the Kiro profile, where Kiro writes the report."
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "Local CLI profile that can assume the role (payer), or the account's own profile when assume_role_name is null."
  type        = string
  default     = null
}

variable "assume_role_name" {
  description = "Role entered in the target account. Null = use the profile directly (management account)."
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "consumer_role_arns" {
  description = "Roles of the dashboard account that may read the lake and the catalog. Leave empty until the pilot reads."
  type        = list(string)
  default     = []
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

variable "reserved_concurrency" {
  type    = number
  default = null
}

variable "enable_backup" {
  type    = bool
  default = true
}

variable "manage_glue_resource_policy" {
  type    = bool
  default = true
}

locals {
  role_arn = var.assume_role_name == null ? null : "arn:aws:iam::${var.account_id}:role/${var.assume_role_name}"
}

provider "aws" {
  region              = var.lake_region
  profile             = var.profile
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { Project = "kiro-monitoring", ManagedBy = "terraform" }
  }
  dynamic "assume_role" {
    for_each = local.role_arn == null ? [] : [local.role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "kiro-mon-terraform"
    }
  }
}

provider "aws" {
  alias               = "report"
  region              = var.report_region
  profile             = var.profile
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { Project = "kiro-monitoring", ManagedBy = "terraform" }
  }
  dynamic "assume_role" {
    for_each = local.role_arn == null ? [] : [local.role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "kiro-mon-terraform"
    }
  }
}

module "data_lake" {
  source = "../../customer/data-lake"
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  slug                        = var.slug
  consumer_role_arns          = var.consumer_role_arns
  permissions_boundary_arn    = var.permissions_boundary_arn
  reserved_concurrency        = var.reserved_concurrency
  enable_backup               = var.enable_backup
  manage_glue_resource_policy = var.manage_glue_resource_policy
}

output "report_s3_uri_for_kiro_console" {
  description = "Enter this in the Kiro console, user activity report."
  value       = module.data_lake.report_s3_uri_for_kiro_console
}

output "lake_bucket" {
  value = module.data_lake.lake_bucket
}

output "backup_bucket" {
  value = module.data_lake.backup_bucket
}

output "glue_database" {
  value = module.data_lake.glue_database
}

output "normalizer_function" {
  value = module.data_lake.normalizer_function
}
