# Customer-side data plane of ONE Kiro account (patch P10).
#
# Everything the monitoring pipeline stores or runs for this account lives in
# this account and is paid by it:
#   report side (Kiro profile Region): report bucket with versioning, the
#     delete guard, and a backup bucket fed by replication.
#   lake side: normalizer Lambda + daily rule, lake bucket with the normalized
#     facts/models, Glue database and the two raw tables the dashboard reads.
# The central dashboard account only READS: it gets s3:GetObject on the lake
# prefix and glue:Get* on this account's catalog, nothing else.
#
# Not here (follow-up patches): the identity map (management account only) and
# the cross-account catalog, views and dataset in the dashboard account.
#
# Providers: aws = lake Region, aws.report = Region of the Kiro profile. They
# may be the same Region; the module never assumes either.
#
# The columns of the two Glue tables are the same lists as
# vendor/.../scripts/build_views.py report_tables_ddl(); a test pins them.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0"
      configuration_aliases = [aws.report]
    }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
  }
}

variable "slug" {
  description = "Short label of this account, used in resource names (for example kiro01)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.slug))
    error_message = "slug: lowercase letters, digits, hyphens, start with a letter, max 15."
  }
}

variable "report_prefix" {
  description = "Prefix entered in the Kiro console. Kiro appends AWSLogs/<account>/KiroLogs/user_report/."
  type        = string
  default     = "kiro/"
  validation {
    condition     = can(regex("^[a-z0-9-]+/$", var.report_prefix))
    error_message = "report_prefix must look like kiro/ (lowercase, ending in a slash)."
  }
}

variable "normalizer_code_file" {
  description = "Path of normalize_report_lambda.py. The default is the vendored sample in this repo."
  type        = string
  default     = null
}

variable "lambda_runtime" {
  type    = string
  default = "python3.14"
}

variable "schedule" {
  description = "Kiro writes the report at 02:00 UTC; the normalizer runs after it."
  type        = string
  default     = "cron(15 3 * * ? *)"
}

variable "projection_range" {
  description = "Days the raw tables project. Every read lists one S3 prefix per day in this window, so keep it rolling and short (never a fixed old start date)."
  type        = string
  default     = "NOW-3MONTHS,NOW"
  validation {
    condition     = can(regex("^NOW-[0-9]{1,2}(MONTHS|WEEKS)(,NOW)$", var.projection_range)) || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2},NOW$", var.projection_range))
    error_message = "projection_range must be NOW-<n>MONTHS,NOW or yyyy-MM-dd,NOW. A future end such as NOW+1YEARS is refused: it lists prefixes that cannot exist yet."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "reserved_concurrency" {
  description = "Null = no reservation. New accounts often have a concurrency limit of 10, and AWS refuses a reservation that leaves fewer than 10 unreserved."
  type        = number
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Optional boundary on the IAM roles of this module (patch P5)."
  type        = string
  default     = null
}

variable "consumer_role_arns" {
  description = "Roles of the dashboard account allowed to READ the lake and the Glue catalog. Empty = no cross-account access yet."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.consumer_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+", a))])
    error_message = "consumer_role_arns must be IAM role ARNs."
  }
}

variable "manage_glue_resource_policy" {
  description = "The Glue resource policy is one per account and Region. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "enable_backup" {
  description = "Backup bucket + replication of the raw report. The report is the only copy of the history."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "lake" {}
data "aws_region" "report" {
  provider = aws.report
}

locals {
  p             = data.aws_partition.current.partition
  account_id    = data.aws_caller_identity.current.account_id
  lake_region   = data.aws_region.lake.region
  report_region = data.aws_region.report.region

  report_bucket = "kiro-user-report-${local.account_id}"
  backup_bucket = "kiro-mon-backup-${local.account_id}"
  lake_bucket   = "kiro-mon-lake-${local.account_id}-${local.lake_region}"
  function_name = "kiro-mon-normalizer-${var.slug}"
  database      = "kiro_${replace(var.slug, "-", "_")}"

  report_arn = "arn:${local.p}:s3:::${local.report_bucket}"
  backup_arn = "arn:${local.p}:s3:::${local.backup_bucket}"
  lake_arn   = "arn:${local.p}:s3:::${local.lake_bucket}"

  raw_prefix = "${var.report_prefix}AWSLogs/${local.account_id}/KiroLogs/user_report/"
  out_prefix = "normalized"

  code_file = coalesce(var.normalizer_code_file, "${path.module}/../../../vendor/sample-kiro-user-analytics-quicksight-dashboard/scripts/normalize_report_lambda.py")
  tags      = merge({ Project = "kiro-monitoring", ManagedBy = "terraform", Account = var.slug }, var.tags)

  # Same names and order as build_views.report_tables_ddl(); all string.
  facts_columns = [
    "date", "userid", "client_type", "chat_conversations", "credits_used", "overage_cap",
    "overage_credits_used", "overage_enabled", "profileid", "subscription_tier", "total_messages",
    "new_user", "email", "src_path", "export_ts", "part_id", "processed_ts", "usage_limit",
  ]
  models_columns = [
    "date", "userid", "client_type", "subscription_tier", "model_name", "messages",
    "src_path", "export_ts", "part_id", "processed_ts",
  ]

  has_consumers = length(var.consumer_role_arns) > 0

  tls_only = {
    Sid       = "DenyInsecureTransport"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = [local.report_arn, "${local.report_arn}/*"]
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }

  report_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "KiroUserReportWrite"
        Effect    = "Allow"
        Principal = { Service = "q.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.report_arn}/${var.report_prefix}*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${local.p}:codewhisperer:${local.report_region}:${local.account_id}:*" }
        }
      },
      local.tls_only,
      {
        Sid       = "DenyReportBucketDelete"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:DeleteBucket"
        Resource  = local.report_arn
      },
    ]
  })

  backup_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      merge(local.tls_only, { Resource = [local.backup_arn, "${local.backup_arn}/*"] }),
      {
        Sid       = "DenyBackupDeletion"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket"]
        Resource  = [local.backup_arn, "${local.backup_arn}/*"]
      },
    ]
  })

  # Read-only grants for the dashboard account. The for/if form keeps one list
  # type whether or not any consumer role is set (a conditional between a list
  # and an empty list is a type error in Terraform).
  consumer_statements = [
    {
      Sid       = "ConsumerReadNormalized"
      Effect    = "Allow"
      Principal = { AWS = var.consumer_role_arns }
      Action    = "s3:GetObject"
      Resource  = "${local.lake_arn}/${local.out_prefix}/*"
    },
    {
      Sid       = "ConsumerListNormalized"
      Effect    = "Allow"
      Principal = { AWS = var.consumer_role_arns }
      Action    = "s3:ListBucket"
      Resource  = local.lake_arn
      Condition = { StringLike = { "s3:prefix" = "${local.out_prefix}/*" } }
    },
    {
      Sid       = "ConsumerBucketLocation"
      Effect    = "Allow"
      Principal = { AWS = var.consumer_role_arns }
      Action    = "s3:GetBucketLocation"
      Resource  = local.lake_arn
    },
  ]

  lake_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [merge(local.tls_only, { Resource = [local.lake_arn, "${local.lake_arn}/*"] })],
      [for s in local.consumer_statements : s if local.has_consumers],
    )
  })

  normalizer_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRawReport"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.report_arn}/${local.raw_prefix}*"
      },
      {
        Sid       = "ListRawReport"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.report_arn
        Condition = { StringLike = { "s3:prefix" = "${local.raw_prefix}*" } }
      },
      {
        Sid      = "WriteNormalized"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${local.lake_arn}/${local.out_prefix}/*"
      },
      {
        Sid       = "ListNormalized"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.lake_arn
        Condition = { StringLike = { "s3:prefix" = "${local.out_prefix}/*" } }
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${local.p}:logs:${local.lake_region}:${local.account_id}:log-group:/aws/lambda/${local.function_name}:*"
      },
    ]
  })

  glue_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ConsumerReadCatalog"
      Effect    = "Allow"
      Principal = { AWS = var.consumer_role_arns }
      Action = [
        "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
        "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
      ]
      Resource = [
        "arn:${local.p}:glue:${local.lake_region}:${local.account_id}:catalog",
        "arn:${local.p}:glue:${local.lake_region}:${local.account_id}:database/${local.database}",
        "arn:${local.p}:glue:${local.lake_region}:${local.account_id}:table/${local.database}/*",
      ]
    }]
  })

  replication_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSourceConfig"
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = local.report_arn
      },
      {
        Sid      = "ReadSourceVersions"
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${local.report_arn}/${var.report_prefix}*"
      },
      {
        Sid      = "WriteBackup"
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateTags"]
        Resource = "${local.backup_arn}/*"
      },
    ]
  })

  raw_table_params = {
    "EXTERNAL"                             = "TRUE"
    "skip.header.line.count"               = "1"
    "projection.enabled"                   = "true"
    "projection.export_date.type"          = "date"
    "projection.export_date.format"        = "yyyy-MM-dd"
    "projection.export_date.range"         = var.projection_range
    "projection.export_date.interval"      = "1"
    "projection.export_date.interval.unit" = "DAYS"
  }
}

# ------------------------------------------------------------------ report bucket

resource "aws_s3_bucket" "report" {
  provider = aws.report
  bucket   = local.report_bucket
  tags     = local.tags

  # The raw report is the only copy of the history.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "report" {
  provider                = aws.report
  bucket                  = aws_s3_bucket.report.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "report" {
  provider = aws.report
  bucket   = aws_s3_bucket.report.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "report" {
  provider = aws.report
  bucket   = aws_s3_bucket.report.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "report" {
  provider = aws.report
  bucket   = aws_s3_bucket.report.id
  versioning_configuration {
    status = "Enabled"
  }
}

# No expiry of current objects. Old versions of a re-exported file are kept a year.
resource "aws_s3_bucket_lifecycle_configuration" "report" {
  provider = aws.report
  bucket   = aws_s3_bucket.report.id
  rule {
    id     = "keep-history"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  depends_on = [aws_s3_bucket_versioning.report]
}

resource "aws_s3_bucket_policy" "report" {
  provider   = aws.report
  bucket     = aws_s3_bucket.report.id
  policy     = local.report_policy
  depends_on = [aws_s3_bucket_public_access_block.report]
}

# ------------------------------------------------------------------ backup of the raw report

resource "aws_s3_bucket" "backup" {
  count    = var.enable_backup ? 1 : 0
  provider = aws.report
  bucket   = local.backup_bucket
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  count                   = var.enable_backup ? 1 : 0
  provider                = aws.report
  bucket                  = aws_s3_bucket.backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  count    = var.enable_backup ? 1 : 0
  provider = aws.report
  bucket   = aws_s3_bucket.backup[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count    = var.enable_backup ? 1 : 0
  provider = aws.report
  bucket   = aws_s3_bucket.backup[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  count    = var.enable_backup ? 1 : 0
  provider = aws.report
  bucket   = aws_s3_bucket.backup[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "backup" {
  count      = var.enable_backup ? 1 : 0
  provider   = aws.report
  bucket     = aws_s3_bucket.backup[0].id
  policy     = local.backup_policy
  depends_on = [aws_s3_bucket_public_access_block.backup]
}

resource "aws_iam_role" "replication" {
  count                = var.enable_backup ? 1 : 0
  name                 = "kiro-mon-report-replication-${var.slug}"
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  count  = var.enable_backup ? 1 : 0
  name   = "replicate-report-to-backup"
  role   = aws_iam_role.replication[0].id
  policy = local.replication_policy
}

# Delete markers are NOT replicated, so deleting a report in the source leaves
# the backup copy untouched. Objects that exist before this rule are not copied
# by it: copy them once (docs/MEMBER-ACCOUNTS.md) and check with tools/verify_backup.py.
resource "aws_s3_bucket_replication_configuration" "report" {
  count    = var.enable_backup ? 1 : 0
  provider = aws.report
  bucket   = aws_s3_bucket.report.id
  role     = aws_iam_role.replication[0].arn

  rule {
    id       = "backup-report"
    status   = "Enabled"
    priority = 1
    filter {
      prefix = var.report_prefix
    }
    delete_marker_replication {
      status = "Disabled"
    }
    destination {
      bucket = aws_s3_bucket.backup[0].arn
    }
  }

  depends_on = [aws_s3_bucket_versioning.report, aws_s3_bucket_versioning.backup, aws_iam_role_policy.replication]
}

# ------------------------------------------------------------------ lake bucket

resource "aws_s3_bucket" "lake" {
  bucket = local.lake_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Normalized parts are rebuilt from the raw report, so old versions are short-lived.
resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  depends_on = [aws_s3_bucket_versioning.lake]
}

resource "aws_s3_bucket_policy" "lake" {
  bucket     = aws_s3_bucket.lake.id
  policy     = local.lake_policy
  depends_on = [aws_s3_bucket_public_access_block.lake]
}

# ------------------------------------------------------------------ normalizer

data "archive_file" "normalizer" {
  type        = "zip"
  source_file = local.code_file
  output_path = "${path.module}/.build/normalizer.zip"
}

resource "aws_iam_role" "normalizer" {
  name                 = local.function_name
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "normalizer" {
  name   = "read-report-write-normalized"
  role   = aws_iam_role.normalizer.id
  policy = local.normalizer_policy
}

resource "aws_cloudwatch_log_group" "normalizer" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "normalizer" {
  function_name                  = local.function_name
  role                           = aws_iam_role.normalizer.arn
  runtime                        = var.lambda_runtime
  architectures                  = ["arm64"]
  handler                        = "normalize_report_lambda.handler"
  filename                       = data.archive_file.normalizer.output_path
  source_code_hash               = data.archive_file.normalizer.output_base64sha256
  timeout                        = 900
  memory_size                    = 256
  reserved_concurrent_executions = var.reserved_concurrency == null ? -1 : var.reserved_concurrency
  tags                           = local.tags

  environment {
    variables = {
      RAW_BUCKET = local.report_bucket
      RAW_PREFIX = local.raw_prefix
      OUT_BUCKET = local.lake_bucket
      OUT_PREFIX = local.out_prefix
    }
  }

  depends_on = [aws_cloudwatch_log_group.normalizer, aws_iam_role_policy.normalizer]
}

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${local.function_name}-daily"
  schedule_expression = var.schedule
  state               = "ENABLED"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "daily" {
  rule = aws_cloudwatch_event_rule.daily.name
  arn  = aws_lambda_function.normalizer.arn
}

resource "aws_lambda_permission" "daily" {
  statement_id  = "AllowEventBridgeDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.normalizer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}

# ------------------------------------------------------------------ Glue

resource "aws_glue_catalog_database" "this" {
  name        = local.database
  description = "Kiro user activity of account ${var.slug} (normalized report)."
  tags        = local.tags
}

resource "aws_glue_catalog_table" "facts_raw" {
  database_name = aws_glue_catalog_database.this.name
  name          = "report_facts_raw"
  table_type    = "EXTERNAL_TABLE"
  parameters = merge(local.raw_table_params, {
    "storage.location.template" = "s3://${local.lake_bucket}/${local.out_prefix}/facts/export_date=$${export_date}/"
  })

  partition_keys {
    name = "export_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.lake_bucket}/${local.out_prefix}/facts/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters            = { separatorChar = ",", quoteChar = "\"" }
    }
    dynamic "columns" {
      for_each = local.facts_columns
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}

resource "aws_glue_catalog_table" "models_raw" {
  database_name = aws_glue_catalog_database.this.name
  name          = "report_models_raw"
  table_type    = "EXTERNAL_TABLE"
  parameters = merge(local.raw_table_params, {
    "storage.location.template" = "s3://${local.lake_bucket}/${local.out_prefix}/models/export_date=$${export_date}/"
  })

  partition_keys {
    name = "export_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.lake_bucket}/${local.out_prefix}/models/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters            = { separatorChar = ",", quoteChar = "\"" }
    }
    dynamic "columns" {
      for_each = local.models_columns
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}

# One per account and Region: it REPLACES an existing policy.
resource "aws_glue_resource_policy" "consumers" {
  count         = local.has_consumers && var.manage_glue_resource_policy ? 1 : 0
  policy        = local.glue_policy
  enable_hybrid = "TRUE"
}

# ------------------------------------------------------------------ outputs

output "report_bucket" {
  value = local.report_bucket
}

output "report_s3_uri_for_kiro_console" {
  description = "Enter this in the Kiro console, user activity report. It must end with /kiro/."
  value       = "s3://${local.report_bucket}/${var.report_prefix}"
}

output "lake_bucket" {
  value = local.lake_bucket
}

output "backup_bucket" {
  value = var.enable_backup ? local.backup_bucket : null
}

output "glue_database" {
  value = local.database
}

output "normalizer_function" {
  value = local.function_name
}

output "report_policy_json" {
  value = local.report_policy
}

output "backup_policy_json" {
  value = local.backup_policy
}

output "lake_policy_json" {
  value = local.lake_policy
}

output "normalizer_policy_json" {
  value = local.normalizer_policy
}

output "glue_policy_json" {
  value = local.glue_policy
}

output "facts_columns" {
  value = local.facts_columns
}

output "models_columns" {
  value = local.models_columns
}
