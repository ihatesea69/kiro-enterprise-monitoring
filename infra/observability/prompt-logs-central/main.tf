# Read the central prompt-log bucket of ONE customer organization from the
# dashboard account (D11, 2026-11-05).
#
# Creates in the dashboard account (Region of the dashboard):
#   - a Glue database + table prompt_logs whose LOCATION is the customer's
#     central bucket (another account, Kiro Region). It is a table of this
#     account's own catalog, so Athena views may be built on it (a view over a
#     cross-account catalog is not supported). Athena reads S3 across Regions
#     (docs: querying-across-regions); inter-Region transfer is charged.
#   - ONE inline policy on the QuickSight role: read that bucket prefix only.
# The customer side of the grant is reader_role_arns of infra/customer/prompt-logs.
#
# Partition projection: account_id (enum, the Kiro accounts) and log_date.
# The path below the prefix is the one measured on real Kiro logs by
# Classmethod (KiroLogs/GenerateAssistantResponse/<region>/YYYY/MM/DD/HH/);
# it is NOT yet measured on this customer's bucket (task 7.3). If it differs,
# the table returns 0 rows and only storage.location.template changes.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

variable "slug" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.slug))
    error_message = "slug: lowercase letters, digits, hyphens, start with a letter, max 15."
  }
}

variable "central_bucket" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{2,62}$", var.central_bucket))
    error_message = "central_bucket is not a valid bucket name."
  }
}

variable "prefix" {
  type    = string
  default = "kiro-prompt-logs/"
}

variable "kiro_region" {
  type    = string
  default = "us-east-1"
}

variable "kiro_account_ids" {
  description = "Every Kiro account whose logs land in the central bucket (management + members)."
  type        = list(string)
  validation {
    condition     = length(var.kiro_account_ids) > 0 && alltrue([for a in var.kiro_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "kiro_account_ids: at least one 12-digit account id."
  }
}

variable "projection_range" {
  description = "Rolling window; keep it at the retention (D12 = 180 days) or shorter."
  type        = string
  default     = "NOW-6MONTHS,NOW"
  validation {
    condition     = can(regex("^NOW-[0-9]{1,2}(MONTHS|WEEKS|DAYS)(,NOW)$", var.projection_range))
    error_message = "projection_range must be NOW-<n>MONTHS|WEEKS|DAYS,NOW."
  }
}

variable "quicksight_role_name" {
  type    = string
  default = "aws-quicksight-service-role-v0"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_iam_role" "quicksight" {
  name = var.quicksight_role_name
}

locals {
  p          = data.aws_partition.current.partition
  own        = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  db         = "kiro_${replace(var.slug, "-", "_")}_prompts"
  bucket_arn = "arn:${local.p}:s3:::${var.central_bucket}"
  base       = "s3://${var.central_bucket}/${var.prefix}AWSLogs/"
  template   = "${local.base}$${account_id}/KiroLogs/GenerateAssistantResponse/${var.kiro_region}/$${log_date}/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ReadCentralPromptLogs"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/${var.prefix}*"
      },
      {
        Sid       = "S3ListCentralPromptLogs"
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = local.bucket_arn
        Condition = { StringLikeIfExists = { "s3:prefix" = "${var.prefix}*" } }
      },
      {
        Sid    = "GlueReadPromptTable"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"]
        Resource = [
          "arn:${local.p}:glue:${local.region}:${local.own}:catalog",
          "arn:${local.p}:glue:${local.region}:${local.own}:database/${local.db}",
          "arn:${local.p}:glue:${local.region}:${local.own}:table/${local.db}/*",
        ]
      },
    ]
  })
}

resource "aws_glue_catalog_database" "this" {
  name        = local.db
  description = "Kiro prompt logs (full text) of ${var.slug}, read in place from the customer's central bucket."
}

resource "aws_glue_catalog_table" "prompt_logs" {
  database_name = aws_glue_catalog_database.this.name
  name          = "prompt_logs"
  table_type    = "EXTERNAL_TABLE"
  parameters = {
    "EXTERNAL"                          = "TRUE"
    "classification"                    = "json"
    "projection.enabled"                = "true"
    "projection.account_id.type"        = "enum"
    "projection.account_id.values"      = join(",", var.kiro_account_ids)
    "projection.log_date.type"          = "date"
    "projection.log_date.format"        = "yyyy/MM/dd"
    "projection.log_date.range"         = var.projection_range
    "projection.log_date.interval"      = "1"
    "projection.log_date.interval.unit" = "DAYS"
    "storage.location.template"         = local.template
  }

  partition_keys {
    name = "account_id"
    type = "string"
  }
  partition_keys {
    name = "log_date"
    type = "string"
  }

  storage_descriptor {
    location      = local.base
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = { "case.insensitive" = "TRUE" }
    }
    columns {
      name = "records"
      type = "array<struct<generateassistantresponseeventrequest:struct<prompt:string,chattriggertype:string,customizationarn:string,userid:string,timestamp:string,modelid:string>,generateassistantresponseeventresponse:struct<assistantresponse:string,followupprompts:string,messagemetadata:struct<conversationid:string,utteranceid:string>,requestid:string>>>"
    }
  }
}

resource "aws_iam_role_policy" "read" {
  name   = "kiro-${var.slug}-QuickSightPromptLogs"
  role   = data.aws_iam_role.quicksight.name
  policy = local.policy
}

output "reader_role_arn" {
  description = "Give this to the customer's central bucket (prompt_reader_role_arns)."
  value       = data.aws_iam_role.quicksight.arn
}

output "glue_database" {
  value = local.db
}

output "location_template" {
  value = local.template
}

output "policy_json" {
  value = local.policy
}
