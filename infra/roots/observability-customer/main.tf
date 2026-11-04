# Observability-account resources of ONE customer. One state per customer:
#
#   terraform init -backend-config="path=../../../customers/<slug>/state-observability/terraform.tfstate"
#   terraform plan -var-file=../../../customers/<slug>/observability.tfvars
#
# Every apply is a [XÁC NHẬN] task: the operator confirms that specific run.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
  backend "local" {}
}

variable "observability_account_id" {
  type = string
}

variable "region" {
  description = "D6."
  type        = string
  default     = "ap-southeast-1"
}

variable "slug" {
  type = string
}

variable "customer_account_id" {
  description = "Customer's Kiro account."
  type        = string
}

variable "kiro_region" {
  type = string
}

variable "enable_trail_bucket" {
  description = "Layer 4. Leave false until OQ-1 shows Kiro emits data events (task 3.6)."
  type        = bool
  default     = false
}

variable "enable_prompt_metadata" {
  description = "D4. Recommended false until OQ-2."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "D5."
  type        = number
  default     = 395
}

variable "glue_database_name" {
  description = "Database of the customer's sample deployment: kiro_<slug> with - replaced by _."
  type        = string
  default     = null
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.observability_account_id]
  default_tags {
    tags = { Project = "kiro-monitoring", Customer = var.slug, ManagedBy = "terraform" }
  }
}

module "trail_bucket" {
  count               = var.enable_trail_bucket ? 1 : 0
  source              = "../../observability/trail-bucket"
  slug                = var.slug
  customer_account_id = var.customer_account_id
  trail_region        = var.kiro_region
  retention_days      = var.retention_days
  glue_database_name  = var.glue_database_name
}

module "prompt_metadata" {
  count               = var.enable_prompt_metadata ? 1 : 0
  source              = "../../observability/prompt-metadata"
  slug                = var.slug
  customer_account_id = var.customer_account_id
  writer_role_arn     = "arn:aws:iam::${var.customer_account_id}:role/kiro-mon-promptmeta-${var.slug}"
  retention_days      = var.retention_days
  glue_database_name  = var.glue_database_name
}

variable "enable_audit_dashboard" {
  description = "Task 8.2. Only after the view exists (task 8.1)."
  type        = bool
  default     = false
}

variable "display_name" {
  type    = string
  default = ""
}

variable "quicksight_owner_arn" {
  type    = string
  default = null
}

variable "quicksight_viewer_arns" {
  description = "D1."
  type        = list(string)
  default     = []
}

variable "request_ids_match" {
  description = "OQ-2."
  type        = bool
  default     = false
}

module "audit" {
  count             = var.enable_audit_dashboard ? 1 : 0
  source            = "../../observability/audit"
  slug              = var.slug
  display_name      = var.display_name
  athena_workgroup  = "kiro_${replace(var.slug, "-", "_")}"
  owner_arn         = var.quicksight_owner_arn
  viewer_arns       = var.quicksight_viewer_arns
  request_ids_match = var.request_ids_match
}

# ---- P11: read access to the data lakes of the Kiro accounts
variable "kiro_lakes" {
  description = "Kiro accounts whose lakes the dashboard reads, keyed by catalog name (kiro01). Empty = nothing is created."
  type = map(object({
    account_id    = string
    glue_database = string
    lake_bucket   = string
    lake_prefix   = optional(string, "normalized")
  }))
  default = {}
}

variable "quicksight_role_name" {
  type    = string
  default = "aws-quicksight-service-role-v0"
}

module "cross_account_catalog" {
  count                = length(var.kiro_lakes) > 0 ? 1 : 0
  source               = "../../observability/cross-account-catalog"
  slug                 = var.slug
  accounts             = var.kiro_lakes
  quicksight_role_name = var.quicksight_role_name
}

output "kiro_lakes_consumer_role_arn" {
  description = "Set as consumer_role_arns in infra/roots/member-account."
  value       = try(module.cross_account_catalog[0].consumer_role_arn, null)
}

output "trail_bucket_name" {
  value = try(module.trail_bucket[0].bucket_name, null)
}

output "promptmeta_bucket_name" {
  value = try(module.prompt_metadata[0].bucket_name, null)
}
