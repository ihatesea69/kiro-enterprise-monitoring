# Read access from the dashboard account to the data lakes of the Kiro accounts
# (patch P11). The lakes themselves are built by infra/customer/data-lake (P10)
# in each Kiro account; this module only registers them and lets QuickSight read.
#
# What it creates in the dashboard account:
#   - one Athena data catalog per Kiro account, of type GLUE, pointing at that
#     account's Glue Data Catalog (same Region only);
#   - ONE inline policy on the QuickSight service role with the read grants for
#     all of them. It is a separate policy with its own name, so it never touches
#     kiro-<slug>-QuickSightAthenaAccess / -QuickSightS3Access, which other tools
#     rewrite as a whole.
#
# Nothing here writes to a Kiro account, and nothing grants more than reads.
# The Kiro-account side of each grant is the lake bucket policy and the Glue
# resource policy that P10 creates when it is given this module's role ARN
# (output consumer_role_arn).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

variable "slug" {
  description = "Customer slug of the dashboard deployment (the kiro-<slug> stack prefix)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.slug))
    error_message = "slug: lowercase letters, digits, hyphens, start with a letter, max 15."
  }
}

variable "accounts" {
  description = "Kiro accounts to read, keyed by a short label that becomes the Athena catalog name (for example kiro01)."
  type = map(object({
    account_id    = string
    glue_database = string
    lake_bucket   = string
    lake_prefix   = optional(string, "normalized")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, a in var.accounts : can(regex("^[a-z][a-z0-9_-]{0,31}$", k)) && k != "awsdatacatalog"])
    error_message = "Each key becomes an Athena catalog name: lowercase letters, digits, hyphen, underscore, start with a letter, max 32."
  }
  validation {
    condition     = alltrue([for k, a in var.accounts : can(regex("^[0-9]{12}$", a.account_id))])
    error_message = "account_id must be 12 digits."
  }
  validation {
    condition     = alltrue([for k, a in var.accounts : can(regex("^[a-z][a-z0-9_]{0,63}$", a.glue_database)) && can(regex("^[a-z0-9][a-z0-9.-]{2,62}$", a.lake_bucket)) && can(regex("^[a-z0-9_-]+$", a.lake_prefix))])
    error_message = "glue_database, lake_bucket or lake_prefix is not a valid name."
  }
  validation {
    condition     = length(distinct([for k, a in var.accounts : a.account_id])) == length(var.accounts)
    error_message = "Two keys point at the same account."
  }
}

variable "quicksight_role_name" {
  description = "The role QuickSight uses to reach Athena and S3. Looked up, so the real ARN (with its path) is used."
  type        = string
  default     = "aws-quicksight-service-role-v0"
}

variable "max_policy_chars" {
  description = "IAM allows 10240 characters of inline policy per role in total. Fail the plan before the API does."
  type        = number
  default     = 6000
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_iam_role" "quicksight" {
  name = var.quicksight_role_name
}

locals {
  p          = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  own        = data.aws_caller_identity.current.account_id
  enabled    = length(var.accounts) > 0
  policy_key = "kiro-${var.slug}-QuickSightCrossAccount"

  catalog_arns = [for k, a in var.accounts : "arn:${local.p}:athena:${local.region}:${local.own}:datacatalog/${k}"]

  glue_arns = flatten([for k, a in var.accounts : [
    "arn:${local.p}:glue:${local.region}:${a.account_id}:catalog",
    "arn:${local.p}:glue:${local.region}:${a.account_id}:database/${a.glue_database}",
    "arn:${local.p}:glue:${local.region}:${a.account_id}:table/${a.glue_database}/*",
  ]])

  object_arns   = [for k, a in var.accounts : "arn:${local.p}:s3:::${a.lake_bucket}/${a.lake_prefix}/*"]
  bucket_arns   = [for k, a in var.accounts : "arn:${local.p}:s3:::${a.lake_bucket}"]
  list_prefixes = distinct([for k, a in var.accounts : "${a.lake_prefix}/*"])

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaCatalogMetadataKiroAccounts"
        Effect = "Allow"
        Action = [
          "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
          "athena:ListDatabases", "athena:ListTableMetadata",
        ]
        Resource = local.catalog_arns
      },
      {
        Sid    = "GlueReadKiroAccounts"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
        ]
        Resource = local.glue_arns
      },
      {
        Sid      = "S3ReadKiroLakes"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = local.object_arns
      },
      {
        Sid       = "S3ListKiroLakes"
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource  = local.bucket_arns
        Condition = { StringLikeIfExists = { "s3:prefix" = local.list_prefixes } }
      },
    ]
  })
}

resource "aws_athena_data_catalog" "kiro" {
  for_each    = var.accounts
  name        = each.key
  type        = "GLUE"
  description = "Glue Data Catalog of Kiro account ${each.key} (read only)."
  parameters  = { "catalog-id" = each.value.account_id }

  lifecycle {
    precondition {
      condition     = each.value.account_id != local.own
      error_message = "${each.key} is this account. Its own catalog is already AwsDataCatalog."
    }
  }
}

resource "aws_iam_role_policy" "cross_account_read" {
  count  = local.enabled ? 1 : 0
  name   = local.policy_key
  role   = data.aws_iam_role.quicksight.name
  policy = local.policy

  lifecycle {
    precondition {
      condition     = length(local.policy) <= var.max_policy_chars
      error_message = "The cross-account policy is ${length(local.policy)} characters. IAM allows 10240 for all inline policies of the role together; split the accounts over a second role or raise max_policy_chars knowingly."
    }
  }
}

output "consumer_role_arn" {
  description = "Give this to infra/roots/member-account as consumer_role_arns, so each Kiro account lets it read."
  value       = data.aws_iam_role.quicksight.arn
}

output "catalog_names" {
  value = sort(keys(var.accounts))
}

output "policy_name" {
  value = local.enabled ? local.policy_key : null
}

output "policy_json" {
  value = local.policy
}
