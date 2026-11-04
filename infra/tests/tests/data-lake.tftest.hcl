# Customer-side data plane (patch P10), planned against mock AWS providers.
# Account 111122223333 = the Kiro account (mocked caller),
# 444455556666 = the dashboard account that may only read.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-southeast-1:111122223333:function:mock" }
  }
}

mock_provider "aws" {
  alias = "report"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

mock_provider "archive" {}

variables {
  consumer = ["arn:aws:iam::444455556666:role/aws-quicksight-service-role-v0"]
}

# ------------------------------------------------------------ report bucket

run "report_policy_lets_only_this_accounts_kiro_write_under_the_prefix" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug = "kiro01"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.report_policy_json).Statement :
      s.Sid == "KiroUserReportWrite"
      && s.Principal.Service == "q.amazonaws.com"
      && s.Action == "s3:PutObject"
      && s.Resource == "arn:aws:s3:::kiro-user-report-111122223333/kiro/*"
      && s.Condition.StringEquals["aws:SourceAccount"] == "111122223333"
      && s.Condition.ArnLike["aws:SourceArn"] == "arn:aws:codewhisperer:us-east-1:111122223333:*"
    ])
    error_message = "Kiro write must be limited to this account, the codewhisperer ARN of the report Region and the kiro/ prefix."
  }

  assert {
    condition     = !strcontains(output.report_policy_json, "444455556666")
    error_message = "The report bucket must not name the dashboard account."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.report_policy_json).Statement :
      s.Sid == "DenyReportBucketDelete" && s.Effect == "Deny" && s.Action == "s3:DeleteBucket"
    ])
    error_message = "Deleting the report bucket must be denied."
  }
}

# ------------------------------------------------------------ lake bucket and consumers

run "lake_has_no_cross_account_access_by_default" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug = "kiro01"
  }

  assert {
    condition     = length(jsondecode(output.lake_policy_json).Statement) == 1 && jsondecode(output.lake_policy_json).Statement[0].Sid == "DenyInsecureTransport"
    error_message = "With no consumer role the lake policy must hold only the TLS guard."
  }

  assert {
    condition     = length(aws_glue_resource_policy.consumers) == 0
    error_message = "No Glue resource policy without a consumer role."
  }
}

run "consumers_get_read_only_and_nothing_else" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug               = "kiro01"
    consumer_role_arns = var.consumer
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.lake_policy_json).Statement :
      s.Effect == "Deny" || alltrue([for a in flatten([s.Action]) : contains(["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"], a)])
    ])
    error_message = "Consumers may only read the lake."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.glue_policy_json).Statement :
      alltrue([for a in flatten([s.Action]) : startswith(a, "glue:Get") || a == "glue:BatchGetPartition"])
    ])
    error_message = "Consumers may only read the Glue catalog."
  }

  assert {
    condition     = length(aws_glue_resource_policy.consumers) == 1
    error_message = "One Glue resource policy when a consumer role is set."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.lake_policy_json).Statement :
      s.Sid == "ConsumerListNormalized" && s.Condition.StringLike["s3:prefix"] == "normalized/*"
    ])
    error_message = "Listing must be limited to the normalized/ prefix."
  }
}

run "glue_resource_policy_can_be_left_alone" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug                        = "kiro01"
    consumer_role_arns          = var.consumer
    manage_glue_resource_policy = false
  }

  assert {
    condition     = length(aws_glue_resource_policy.consumers) == 0
    error_message = "manage_glue_resource_policy = false must not touch the account's Glue policy."
  }
}

run "consumer_must_be_a_role" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug               = "kiro01"
    consumer_role_arns = ["arn:aws:iam::444455556666:root"]
  }
  expect_failures = [var.consumer_role_arns]
}

# ------------------------------------------------------------ normalizer

run "normalizer_role_is_scoped_to_its_prefixes" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug = "kiro01"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.normalizer_policy_json).Statement :
      s.Resource != "*" && !contains(flatten([s.Action]), "s3:*") && !contains(flatten([s.Action]), "s3:DeleteObject")
    ])
    error_message = "No wildcard resource and no delete in the normalizer role."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.normalizer_policy_json).Statement :
      s.Sid == "ReadRawReport" && s.Action == "s3:GetObject"
      && s.Resource == "arn:aws:s3:::kiro-user-report-111122223333/kiro/AWSLogs/111122223333/KiroLogs/user_report/*"
    ])
    error_message = "The normalizer reads only this account's user_report prefix."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(output.normalizer_policy_json).Statement :
      contains(flatten([s.Action]), "s3:PutObject") && !startswith(s.Resource, "arn:aws:s3:::kiro-mon-lake-111122223333-ap-southeast-1/normalized/")
    ])
    error_message = "The normalizer writes only under normalized/ of the lake."
  }

  assert {
    condition     = aws_lambda_function.normalizer.environment[0].variables["OUT_BUCKET"] == "kiro-mon-lake-111122223333-ap-southeast-1" && aws_lambda_function.normalizer.environment[0].variables["OUT_PREFIX"] == "normalized"
    error_message = "Lambda must write to the lake bucket under normalized."
  }

  assert {
    condition     = aws_cloudwatch_event_rule.daily.schedule_expression == "cron(15 3 * * ? *)"
    error_message = "The normalizer runs at 03:15 UTC, after Kiro writes at 02:00."
  }
}

run "boundary_goes_on_both_roles" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug                     = "kiro01"
    permissions_boundary_arn = "arn:aws:iam::111122223333:policy/boundary"
  }

  assert {
    condition     = aws_iam_role.normalizer.permissions_boundary == "arn:aws:iam::111122223333:policy/boundary" && aws_iam_role.replication[0].permissions_boundary == "arn:aws:iam::111122223333:policy/boundary"
    error_message = "The boundary must apply to the normalizer and the replication role."
  }
}

# ------------------------------------------------------------ Glue and the S3 LIST cost

run "projection_window_is_rolling_and_short" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug = "kiro01"
  }

  assert {
    condition     = aws_glue_catalog_table.facts_raw.parameters["projection.export_date.range"] == "NOW-3MONTHS,NOW" && aws_glue_catalog_table.models_raw.parameters["projection.export_date.range"] == "NOW-3MONTHS,NOW"
    error_message = "Both raw tables project the rolling 3-month window."
  }

  assert {
    condition     = aws_glue_catalog_table.facts_raw.parameters["storage.location.template"] == "s3://kiro-mon-lake-111122223333-ap-southeast-1/normalized/facts/export_date=$${export_date}/"
    error_message = "Facts template must point at the lake."
  }

  assert {
    condition     = length(output.facts_columns) == 18 && output.facts_columns[17] == "usage_limit" && length(output.models_columns) == 10
    error_message = "Facts has 18 columns ending in usage_limit; models has 10."
  }
}

run "projection_rejects_a_future_end_date" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug             = "kiro01"
    projection_range = "2020-01-01,NOW+1YEARS"
  }
  expect_failures = [var.projection_range]
}

# ------------------------------------------------------------ backup

run "backup_is_replicated_and_cannot_be_emptied" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug = "kiro01"
  }

  assert {
    condition     = aws_s3_bucket_replication_configuration.report[0].rule[0].delete_marker_replication[0].status == "Disabled"
    error_message = "Delete markers must not replicate, or a delete in the source would hide the backup copy."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.backup_policy_json).Statement :
      s.Sid == "DenyBackupDeletion" && contains(s.Action, "s3:DeleteObjectVersion") && s.Principal == "*"
    ])
    error_message = "Nobody may delete objects or versions from the backup."
  }

  assert {
    condition     = aws_s3_bucket_versioning.report.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_versioning.backup[0].versioning_configuration[0].status == "Enabled"
    error_message = "Replication needs versioning on both buckets."
  }

  assert {
    condition     = output.backup_bucket == "kiro-mon-backup-111122223333"
    error_message = "Backup bucket name."
  }
}

run "backup_can_be_switched_off" {
  command = plan
  module {
    source = "../customer/data-lake"
  }
  providers = {
    aws        = aws
    aws.report = aws.report
  }
  variables {
    slug          = "kiro01"
    enable_backup = false
  }

  assert {
    condition     = length(aws_s3_bucket.backup) == 0 && length(aws_s3_bucket_replication_configuration.report) == 0 && output.backup_bucket == null
    error_message = "enable_backup = false creates no backup resources."
  }
}
