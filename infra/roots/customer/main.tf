# Customer-side resources of ONE customer, in two accounts that may differ:
# the Kiro account (region of the Kiro profile) and the Identity Center account.
#
#   terraform init -backend-config="path=../../../customers/<slug>/state-customer/terraform.tfstate"
#   terraform plan -var-file=../../../customers/<slug>/customer.tfvars
#
# Every apply is a [XÁC NHẬN] task. Each layer is off until its task enables it.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
  }
  backend "local" {}
}

variable "slug" {
  type = string
}

variable "observability_account_id" {
  type = string
}

variable "kiro_account_id" {
  type = string
}

variable "kiro_region" {
  type = string
}

variable "kiro_profile" {
  description = "Local CLI profile for the Kiro account."
  type        = string
  default     = null
}

variable "identity_center_account_id" {
  type = string
}

variable "identity_center_region" {
  type = string
}

variable "identity_center_profile" {
  type    = string
  default = null
}

# ---- task 4.9 / 5.8: report bucket policy
variable "report_bucket" {
  type    = string
  default = null
}

variable "report_existing_policy_file" {
  description = "customers/<slug>/survey/bucket-policy-report.json written by the survey."
  type        = string
  default     = null
}

variable "report_reader_role_arns" {
  description = "CID LambdaRoleArn, then also the sample's normalizer role (task 5.8)."
  type        = list(string)
  default     = []
}

# ---- task 5.6 / 5.8: Identity Center read role (D8)
variable "enable_idc_read_role" {
  type    = bool
  default = false
}

variable "identity_store_id" {
  type    = string
  default = null
}

variable "external_id" {
  type    = string
  default = null
}

variable "identity_map_role_arn" {
  type    = string
  default = null
}

# ---- task 6.3: trail (layer 4)
variable "enable_trail" {
  type    = bool
  default = false
}

variable "trail_bucket_name" {
  type    = string
  default = null
}

variable "trail_event_names" {
  type    = list(string)
  default = []
}

# ---- task 7.1 / 7.5: prompt logs (layer 5) and metadata (D4)
variable "enable_prompt_logs" {
  type    = bool
  default = false
}

variable "prompt_retention_days" {
  type    = number
  default = null
}

variable "prompt_auditor_principal_arns" {
  type    = list(string)
  default = []
}

variable "prompt_replication_source_role_arns" {
  description = "Replication roles of the landing buckets of the other Kiro accounts (central bucket)."
  type        = list(string)
  default     = []
}

variable "prompt_reader_role_arns" {
  description = "D11: observability-account roles that read the full text."
  type        = list(string)
  default     = []
}

variable "enable_prompt_metadata" {
  type    = bool
  default = false
}

variable "promptmeta_destination_bucket" {
  type    = string
  default = null
}

provider "aws" {
  alias               = "kiro"
  region              = var.kiro_region
  profile             = var.kiro_profile
  allowed_account_ids = [var.kiro_account_id]
  default_tags {
    tags = { Project = "kiro-monitoring", ManagedBy = "terraform" }
  }
}

provider "aws" {
  alias               = "idc"
  region              = var.identity_center_region
  profile             = var.identity_center_profile
  allowed_account_ids = [var.identity_center_account_id]
  default_tags {
    tags = { Project = "kiro-monitoring", ManagedBy = "terraform" }
  }
}

module "report_bucket_policy" {
  count                = var.report_bucket == null ? 0 : 1
  source               = "../../customer/report-bucket-policy"
  providers            = { aws = aws.kiro }
  bucket               = var.report_bucket
  existing_policy_json = var.report_existing_policy_file == null ? "" : file(var.report_existing_policy_file)
  reader_role_arns     = var.report_reader_role_arns
}

module "idc_read_role" {
  count                    = var.enable_idc_read_role ? 1 : 0
  source                   = "../../customer/idc-read-role"
  providers                = { aws = aws.idc }
  slug                     = var.slug
  identity_store_id        = var.identity_store_id
  observability_account_id = var.observability_account_id
  external_id              = var.external_id
  identity_map_role_arn    = var.identity_map_role_arn
}

module "trail" {
  count                    = var.enable_trail ? 1 : 0
  source                   = "../../customer/trail"
  providers                = { aws = aws.kiro }
  bucket_name              = var.trail_bucket_name
  observability_account_id = var.observability_account_id
  event_names              = var.trail_event_names
  tags                     = { Customer = var.slug }
}

module "prompt_logs" {
  count                    = var.enable_prompt_logs ? 1 : 0
  source                   = "../../customer/prompt-logs"
  providers                = { aws = aws.kiro }
  slug                     = var.slug
  observability_account_id = var.observability_account_id
  retention_days           = var.prompt_retention_days
  auditor_principal_arns   = var.prompt_auditor_principal_arns

  replication_source_role_arns = var.prompt_replication_source_role_arns
  reader_role_arns             = var.prompt_reader_role_arns
}

module "prompt_metadata" {
  count                    = var.enable_prompt_logs && var.enable_prompt_metadata ? 1 : 0
  source                   = "../../customer/prompt-metadata"
  providers                = { aws = aws.kiro }
  slug                     = var.slug
  prompt_bucket_name       = module.prompt_logs[0].bucket_name
  destination_bucket       = var.promptmeta_destination_bucket
  observability_account_id = var.observability_account_id
}

output "idc_read_role_arn" {
  value = try(module.idc_read_role[0].role_arn, null)
}

output "trail_arn" {
  value = try(module.trail[0].trail_arn, null)
}

output "prompt_logs_s3_uri" {
  description = "Enter this in Kiro console > Settings > Logging (task 7.2)."
  value       = try(module.prompt_logs[0].s3_uri_for_kiro_console, null)
}
