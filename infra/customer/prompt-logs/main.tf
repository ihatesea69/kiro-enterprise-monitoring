# Prompt logs (full text) stay in the customer's Kiro account (task 7.1).
# Nothing here names the observability account; a precondition enforces it.
# Provider: customer Kiro account, Region of the Kiro profile.
#
# Bucket policy: statement KiroLogsWrite from the Kiro prompt-logging docs.
# Encryption is SSE-S3 (decided 2026-10-29): no KMS key, so Kiro needs only
# s3:PutObject. Kiro writing into an SSE-S3 bucket is still measured in OQ-9.

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

variable "observability_account_id" {
  description = "Used only to prove no policy here grants it anything."
  type        = string
}

variable "prefix" {
  description = "S3 location prefix entered in the Kiro console."
  type        = string
  default     = "kiro-prompt-logs/"
}

variable "retention_days" {
  description = "Chosen by the customer. No default on purpose."
  type        = number
}

variable "auditor_principal_arns" {
  description = "Customer principals allowed to assume kiro-prompt-auditor. Empty = no auditor role."
  type        = list(string)
  default     = []
}

variable "create_athena" {
  type    = bool
  default = true
}

variable "force_destroy" {
  type    = bool
  default = false
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  p           = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket      = "${var.slug}-kiro-prompt-logs-${local.account_id}"
  bucket_arn  = "arn:${local.p}:s3:::${local.bucket}"
  kiro_source = "arn:${local.p}:codewhisperer:${local.region}:${local.account_id}:*"
  auditor     = length(var.auditor_principal_arns) > 0
  results     = "athena-results/"
  db          = "kiro_prompt_audit_${replace(var.slug, "-", "_")}"
  tags        = { Project = "kiro-monitoring", Customer = var.slug, DataClass = "prompt-full-text" }

  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "KiroLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "q.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/${var.prefix}*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = local.kiro_source }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  auditor_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.auditor_principal_arns }
    }]
  })

  auditor_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadPromptLogs", Effect = "Allow", Action = ["s3:GetObject"], Resource = "${local.bucket_arn}/${var.prefix}*" },
      { Sid = "ListPromptLogs", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = local.bucket_arn },
      { Sid = "AthenaResults", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${local.bucket_arn}/${local.results}*" },
      {
        Sid      = "QueryOneWorkgroup"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]
        Resource = "arn:${local.p}:athena:${local.region}:${local.account_id}:workgroup/kiro-prompt-audit-${var.slug}"
      },
      {
        Sid    = "ReadCatalog"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
        Resource = [
          "arn:${local.p}:glue:${local.region}:${local.account_id}:catalog",
          "arn:${local.p}:glue:${local.region}:${local.account_id}:database/${local.db}",
          "arn:${local.p}:glue:${local.region}:${local.account_id}:table/${local.db}/*",
        ]
      },
    ]
  })

  all_policies = join("\n", [local.bucket_policy, local.auditor_trust, local.auditor_policy])
}

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket
  force_destroy = var.force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "expire-prompt-logs"
    status = "Enabled"
    filter {
      prefix = var.prefix
    }
    expiration {
      days = var.retention_days
    }
  }
  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter {
      prefix = local.results
    }
    expiration {
      days = 7
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = local.bucket_policy
  depends_on = [aws_s3_bucket_public_access_block.this]

  lifecycle {
    precondition {
      condition     = !strcontains(local.all_policies, var.observability_account_id)
      error_message = "A prompt-log policy names the observability account. Full text must not leave the customer account."
    }
  }
}

resource "aws_iam_role" "auditor" {
  count              = local.auditor ? 1 : 0
  name               = "kiro-prompt-auditor"
  description        = "Reads full-text Kiro prompt logs of this account - audit only"
  assume_role_policy = local.auditor_trust
  tags               = local.tags
}

resource "aws_iam_role_policy" "auditor" {
  count  = local.auditor ? 1 : 0
  name   = "read-prompt-logs"
  role   = aws_iam_role.auditor[0].id
  policy = local.auditor_policy
}

resource "aws_athena_workgroup" "this" {
  count         = var.create_athena ? 1 : 0
  name          = "kiro-prompt-audit-${var.slug}"
  force_destroy = var.force_destroy
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${local.bucket}/${local.results}"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
  tags = local.tags
}

resource "aws_glue_catalog_database" "this" {
  count = var.create_athena ? 1 : 0
  name  = local.db
}

# Reads every file under the prompt prefix. The exact Kiro path below the
# prefix (log type, region, date, hour) is measured in task 3.6; partition
# projection is added after that.
resource "aws_glue_catalog_table" "prompt_logs" {
  count         = var.create_athena ? 1 : 0
  database_name = aws_glue_catalog_database.this[0].name
  name          = "prompt_logs"
  table_type    = "EXTERNAL_TABLE"
  parameters    = { "EXTERNAL" = "TRUE", "classification" = "json" }

  storage_descriptor {
    location      = "s3://${local.bucket}/${var.prefix}"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = { "case.insensitive" = "TRUE" }
    }
    columns {
      name = "records"
      type = "array<struct<generateassistantresponseeventrequest:struct<prompt:string,chattriggertype:string,customizationarn:string,userid:string,timestamp:string,modelid:string>,generateassistantresponseeventresponse:struct<assistantresponse:string,followupprompts:string,messagemetadata:struct<conversationid:string,utteranceid:string>,requestid:string>,generatecompletionseventrequest:struct<leftcontext:string,rightcontext:string,filename:string,userid:string,timestamp:string>,generatecompletionseventresponse:struct<completions:array<string>,requestid:string>>>"
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "s3_uri_for_kiro_console" {
  value = "s3://${local.bucket}/${var.prefix}"
}

output "policies_json" {
  value = local.all_policies
}
