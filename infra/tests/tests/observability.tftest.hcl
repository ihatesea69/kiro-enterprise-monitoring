# Observability-account modules and all roots, against mocked providers.
# 444455556666 = observability account (mocked caller here), 111122223333 = customer.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::444455556666:role/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-southeast-1:444455556666:function:mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-southeast-1:444455556666:kiro-mon-alerts" }
  }
  mock_resource "aws_quicksight_data_source" {
    defaults = { arn = "arn:aws:quicksight:ap-southeast-1:444455556666:datasource/mock" }
  }
  mock_resource "aws_quicksight_data_set" {
    defaults = { arn = "arn:aws:quicksight:ap-southeast-1:444455556666:dataset/mock" }
  }
}

mock_provider "archive" {}

# Roots and the experiment declare aliased providers. Each alias needs its own
# mock, otherwise Terraform configures the real provider and calls STS.
mock_provider "aws" {
  alias = "kiro"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::444455556666:role/mock" }
  }
}

mock_provider "aws" {
  alias = "idc"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

mock_provider "aws" {
  alias = "bucket"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

run "trail_bucket_policies_follow_cloudtrail_docs" {
  command = apply
  module {
    source = "../observability/trail-bucket"
  }
  variables {
    slug                = "acme"
    customer_account_id = "111122223333"
    trail_region        = "us-east-1"
    glue_database_name  = "kiro_acme"
  }
  assert {
    condition     = output.bucket_name == "kiro-mon-trail-acme-444455556666"
    error_message = "Bucket name must carry slug and observability account."
  }
  assert {
    condition     = alltrue([for s in jsondecode(output.bucket_policy_json).Statement : s.Effect == "Deny" if s.Principal == "*"])
    error_message = "Principal * is allowed only in Deny statements (task 6.1 done check)."
  }
  assert {
    condition     = [for s in jsondecode(output.bucket_policy_json).Statement : s.Resource if s.Sid == "AWSCloudTrailWrite"][0] == "arn:aws:s3:::kiro-mon-trail-acme-444455556666/AWSLogs/111122223333/*"
    error_message = "CloudTrail may write only under the customer's AWSLogs prefix."
  }
  assert {
    condition     = alltrue([for s in jsondecode(output.bucket_policy_json).Statement : s.Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:us-east-1:111122223333:trail/kiro-mon-audit" if can(s.Principal.Service)])
    error_message = "Every CloudTrail statement must pin aws:SourceArn to the customer trail."
  }
  assert {
    condition     = [for r in aws_s3_bucket_server_side_encryption_configuration.this.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm] == ["AES256"]
    error_message = "Trail bucket uses SSE-S3, no KMS key."
  }
  assert {
    condition     = !strcontains(output.bucket_policy_json, "kms:")
    error_message = "Bucket policy grants no KMS action."
  }
  assert {
    condition     = length(aws_glue_catalog_table.cloudtrail[0].storage_descriptor[0].columns) == 29 && length(aws_glue_catalog_table.cloudtrail[0].partition_keys) == 2
    error_message = "Table must have the 29 documented columns and region/timestamp partitions."
  }
  assert {
    condition     = aws_glue_catalog_table.cloudtrail[0].parameters["storage.location.template"] == "s3://kiro-mon-trail-acme-444455556666/AWSLogs/111122223333/CloudTrail/$${region}/$${timestamp}"
    error_message = "Projection template must match the CloudTrail key layout."
  }
  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[0].expiration[0].days == 395
    error_message = "Default retention is 13 months (D5)."
  }
}

run "trail_bucket_without_database_has_no_table" {
  command = apply
  module {
    source = "../observability/trail-bucket"
  }
  variables {
    slug                = "acme"
    customer_account_id = "111122223333"
    trail_region        = "us-east-1"
  }
  assert {
    condition     = length(aws_glue_catalog_table.cloudtrail) == 0
    error_message = "No table without a database."
  }
}

# ------------------------------------------------------------ prompt-metadata, observability side (7.5)

run "promptmeta_bucket_accepts_one_writer_role" {
  command = apply
  module {
    source = "../observability/prompt-metadata"
  }
  variables {
    slug                = "acme"
    customer_account_id = "111122223333"
    writer_role_arn     = "arn:aws:iam::111122223333:role/kiro-mon-promptmeta-acme"
    glue_database_name  = "kiro_acme"
  }
  assert {
    condition     = [for s in jsondecode(output.policy_json).Statement : s.Resource if s.Sid == "CustomerMetadataWriter"][0] == "arn:aws:s3:::kiro-mon-promptmeta-acme-444455556666/promptmeta/account_id=111122223333/*"
    error_message = "Writer limited to its account partition."
  }
  assert {
    condition     = length(aws_glue_catalog_table.promptmeta[0].storage_descriptor[0].columns) == 13
    error_message = "Table columns must equal the 13 allow-listed fields."
  }
}

run "promptmeta_bucket_rejects_other_writer" {
  command = plan
  module {
    source = "../observability/prompt-metadata"
  }
  variables {
    slug                = "acme"
    customer_account_id = "111122223333"
    writer_role_arn     = "arn:aws:iam::111122223333:role/AdminRole"
  }
  expect_failures = [aws_s3_bucket.this]
}

# ------------------------------------------------------------ audit dashboard (8.2)

run "audit_dashboard_adds_note_when_ids_differ" {
  command = apply
  module {
    source = "../observability/audit"
  }
  variables {
    slug             = "acme"
    display_name     = "ACME"
    athena_workgroup = "kiro_acme"
    owner_arn        = "arn:aws:quicksight:ap-southeast-1:444455556666:user/default/admin"
    viewer_arns      = ["arn:aws:quicksight:ap-southeast-1:444455556666:group/default/kiro-viewers"]
  }
  assert {
    condition     = length(aws_quicksight_dashboard.this.definition[0].sheets[0].text_boxes) == 1
    error_message = "OQ-2 note must be shown when request IDs do not match."
  }
  assert {
    condition     = one([for t in aws_quicksight_data_set.this.physical_table_map : t.custom_sql[0].sql_query]) == "SELECT * FROM kiro_acme.kiro_request_audit"
    error_message = "Dataset reads only the audit view."
  }
  assert {
    condition     = aws_quicksight_data_set.this.import_mode == "DIRECT_QUERY"
    error_message = "Audit dataset is Direct Query (D10): no SPICE copy, no daily full refresh."
  }
  assert {
    condition     = length(aws_quicksight_dashboard.this.permissions) == 2
    error_message = "Owner plus one viewer group."
  }
}

run "audit_dashboard_no_note_when_ids_match" {
  command = apply
  module {
    source = "../observability/audit"
  }
  variables {
    slug              = "acme"
    display_name      = "ACME"
    athena_workgroup  = "kiro_acme"
    owner_arn         = "arn:aws:quicksight:ap-southeast-1:444455556666:user/default/admin"
    request_ids_match = true
  }
  assert {
    condition     = length(aws_quicksight_dashboard.this.definition[0].sheets[0].text_boxes) == 0
    error_message = "No note when IDs match."
  }
}

# ------------------------------------------------------------ freshness (9.3)

run "freshness_lists_only_configured_buckets" {
  command = apply
  module {
    source = "../observability/freshness"
  }
  variables {
    config = {
      dc_bucket          = "cid-data-collection"
      collector_function = "CID-DC-kiro-user-activity-Lambda"
      cur_bucket         = "cid-444455556666-data-exports"
      customers = [{
        slug                  = "acme"
        kiro_account          = "111122223333"
        report_bucket         = "acme-kiro-report"
        sample_results_bucket = "kiro-acme-data-athena-results"
        trail                 = { bucket = "kiro-mon-trail-acme-444455556666", region = "us-east-1" }
      }]
    }
  }
  assert {
    condition     = aws_scheduler_schedule.daily.schedule_expression == "cron(0 5 * * ? *)" && aws_scheduler_schedule.daily.schedule_expression_timezone == "UTC"
    error_message = "Runs at 05:00 UTC."
  }
  assert {
    condition     = jsondecode(aws_lambda_function.freshness.environment[0].variables.CONFIG).customers[0].slug == "acme"
    error_message = "CONFIG is passed to the Lambda."
  }
  assert {
    condition     = aws_lambda_function.freshness.environment[0].variables.DRY_RUN == "0"
    error_message = "Dry run is off by default."
  }
}

run "freshness_rejects_bad_account" {
  command = plan
  module {
    source = "../observability/freshness"
  }
  variables {
    config = {
      dc_bucket = "x", collector_function = "y", cur_bucket = "z"
      customers = [{ slug = "acme", kiro_account = "1234", report_bucket = "r" }]
    }
  }
  expect_failures = [var.config]
}

# ------------------------------------------------------------ roots

run "observability_root_defaults_create_nothing" {
  command = plan
  module {
    source = "../roots/observability-customer"
  }
  variables {
    observability_account_id = "444455556666"
    slug                     = "acme"
    customer_account_id      = "111122223333"
    kiro_region              = "us-east-1"
  }
  assert {
    condition     = length(module.trail_bucket) == 0 && length(module.prompt_metadata) == 0 && length(module.audit) == 0
    error_message = "Every layer is off until its task turns it on."
  }
}

# Task 10.4: a second customer needs no code change, and every name carries its slug.
run "second_customer_needs_no_code_change" {
  command = apply
  module {
    source = "../roots/observability-customer"
  }
  variables {
    observability_account_id = "444455556666"
    slug                     = "demo2"
    customer_account_id      = "222233334444"
    kiro_region              = "eu-central-1"
    enable_trail_bucket      = true
    enable_prompt_metadata   = true
    glue_database_name       = "kiro_demo2"
  }
  assert {
    condition     = output.trail_bucket_name == "kiro-mon-trail-demo2-444455556666" && output.promptmeta_bucket_name == "kiro-mon-promptmeta-demo2-444455556666"
    error_message = "Bucket names must carry the second customer's slug."
  }
  assert {
    condition     = module.trail_bucket[0].trail_arn_expected == "arn:aws:cloudtrail:eu-central-1:222233334444:trail/kiro-mon-audit"
    error_message = "Trail ARN must use the second customer's account and Region."
  }
  assert {
    condition     = !strcontains(module.trail_bucket[0].bucket_policy_json, "111122223333") && !strcontains(module.prompt_metadata[0].policy_json, "111122223333")
    error_message = "The first customer's account must not appear in the second customer's policies."
  }
}

run "customer_root_defaults_create_nothing" {
  command = plan
  module {
    source = "../roots/customer"
  }
  variables {
    slug                       = "acme"
    observability_account_id   = "444455556666"
    kiro_account_id            = "111122223333"
    kiro_region                = "us-east-1"
    identity_center_account_id = "111122223333"
    identity_center_region     = "us-east-1"
  }
  assert {
    condition     = length(module.trail) == 0 && length(module.prompt_logs) == 0 && length(module.idc_read_role) == 0 && length(module.report_bucket_policy) == 0
    error_message = "Every customer-side layer is off by default."
  }
}

run "experiment_root_composes_temporary_resources" {
  command = apply
  module {
    source = "../experiments/oq"
  }
  variables {
    account_id  = "444455556666"
    kiro_region = "us-east-1"
  }
  assert {
    condition     = output.trail_bucket == "kiro-mon-trail-oq-444455556666"
    error_message = "Temporary trail bucket name."
  }
  assert {
    condition     = module.trail_bucket.trail_arn_expected == "arn:aws:cloudtrail:us-east-1:444455556666:trail/kiro-mon-oq"
    error_message = "Bucket policy must expect the experiment trail."
  }
  assert {
    condition     = strcontains(output.measure_command, "--trail-bucket kiro-mon-trail-oq-444455556666")
    error_message = "The printed measure command must point at the trail bucket."
  }
}
