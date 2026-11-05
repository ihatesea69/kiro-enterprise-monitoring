# Landing bucket for the Kiro prompt logs of ONE account that is not the
# account of the central bucket (2026-11-05).
#
# Kiro writes only into a bucket of its own account (Kiro docs, user activity
# report: cross-account buckets are not supported; prompt logging: "a bucket of
# your choice in your own account"). So this account keeps a short-lived
# landing bucket and S3 replication copies every log into the central bucket
# (infra/customer/prompt-logs in the management account). Same object keys:
# Kiro already puts AWSLogs/<account>/ in them, so accounts never collide.
#
# Provider: this Kiro account, Region of the Kiro profile.

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
  description = "Name of the central prompt-log bucket."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{2,62}$", var.central_bucket))
    error_message = "central_bucket is not a valid bucket name."
  }
}

variable "central_account_id" {
  description = "Account that owns the central bucket."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.central_account_id))
    error_message = "central_account_id must be 12 digits."
  }
}

variable "prefix" {
  description = "S3 prefix entered in the Kiro console. Same prefix as the central bucket."
  type        = string
  default     = "kiro-prompt-logs/"
  validation {
    condition     = can(regex("^[a-z0-9-]+/$", var.prefix))
    error_message = "prefix must look like kiro-prompt-logs/ (lowercase, ending in a slash)."
  }
}

variable "landing_retention_days" {
  description = "Days a log stays in the landing bucket after it is replicated. The retention that counts (D12) is the central bucket's."
  type        = number
  default     = 30
  validation {
    condition     = var.landing_retention_days >= 7
    error_message = "Keep at least 7 days, so a replication failure can still be repaired."
  }
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  p           = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket      = "kiro-prompt-landing-${local.account_id}"
  bucket_arn  = "arn:${local.p}:s3:::${local.bucket}"
  central_arn = "arn:${local.p}:s3:::${var.central_bucket}"
  role_name   = "kiro-mon-prompt-replication-${var.slug}"
  tags        = { Project = "kiro-monitoring", Account = var.slug, DataClass = "prompt-full-text" }

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
          ArnLike      = { "aws:SourceArn" = "arn:${local.p}:codewhisperer:${local.region}:${local.account_id}:*" }
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

  replication_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSourceConfig"
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = local.bucket_arn
      },
      {
        Sid      = "ReadSourceVersions"
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${local.bucket_arn}/${var.prefix}*"
      },
      {
        Sid      = "WriteCentral"
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateTags"]
        Resource = "${local.central_arn}/${var.prefix}*"
      },
    ]
  })
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket
  tags   = local.tags

  lifecycle {
    precondition {
      condition     = var.central_account_id != local.account_id
      error_message = "This account holds the central bucket: Kiro writes there directly, no landing bucket."
    }
  }
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

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "expire-landed-logs"
    status = "Enabled"
    filter {
      prefix = var.prefix
    }
    expiration {
      days = var.landing_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = local.bucket_policy
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_iam_role" "replication" {
  name                 = local.role_name
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
  name   = "replicate-prompt-logs-to-central"
  role   = aws_iam_role.replication.id
  policy = local.replication_policy
}

# Delete markers are not replicated: the landing lifecycle expiring a log here
# never removes the central copy.
resource "aws_s3_bucket_replication_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication.arn

  rule {
    id       = "to-central"
    status   = "Enabled"
    priority = 1
    filter {
      prefix = var.prefix
    }
    delete_marker_replication {
      status = "Disabled"
    }
    destination {
      bucket  = local.central_arn
      account = var.central_account_id
    }
  }

  depends_on = [aws_s3_bucket_versioning.this, aws_iam_role_policy.replication]
}

output "bucket_name" {
  value = local.bucket
}

output "s3_uri_for_kiro_console" {
  description = "Enter this in the Kiro console of THIS account, prompt logging."
  value       = "s3://${local.bucket}/${var.prefix}"
}

output "replication_role_arn" {
  description = "Give this to the central bucket (prompt-logs replication_source_role_arns)."
  value       = "arn:${local.p}:iam::${local.account_id}:role/${local.role_name}"
}

output "bucket_policy_json" {
  value = local.bucket_policy
}

output "replication_policy_json" {
  value = local.replication_policy
}
