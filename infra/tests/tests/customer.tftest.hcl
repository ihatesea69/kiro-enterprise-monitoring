# Customer-side modules, planned and "applied" against a mock AWS provider.
# Accounts: 111122223333 = customer (mocked caller), 444455556666 = observability.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:111122223333:function:mock" }
  }
}

mock_provider "archive" {}

variables {
  existing_two = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "KiroLogsWrite", Effect = "Allow", Principal = { Service = "q.amazonaws.com" }, Action = "s3:PutObject", Resource = "arn:aws:s3:::rpt/kiro/*" },
      { Sid = "OtherTeam", Effect = "Allow", Principal = { AWS = "arn:aws:iam::111122223333:role/backup" }, Action = "s3:GetObject", Resource = "arn:aws:s3:::rpt/*" },
      { Sid = "KiroMonReportRead", Effect = "Allow", Principal = { AWS = "arn:aws:iam::444455556666:role/old" }, Action = "s3:GetObject", Resource = "arn:aws:s3:::rpt/kiro/*" },
    ]
  })
}

# ------------------------------------------------------------ report-bucket-policy (4.8)

run "report_policy_keeps_old_statements_and_replaces_ours" {
  command = apply
  module {
    source = "../customer/report-bucket-policy"
  }
  variables {
    bucket               = "rpt"
    existing_policy_json = var.existing_two
    reader_role_arns     = ["arn:aws:iam::444455556666:role/CID-DC-kiro", "arn:aws:iam::444455556666:role/kiro-acme-data-Normalizer"]
  }
  assert {
    condition     = output.kept_sids == ["KiroLogsWrite", "OtherTeam"]
    error_message = "Existing statements other than ours must be kept, the stale KiroMon one dropped."
  }
  assert {
    condition     = length(jsondecode(output.policy_json).Statement) == 4
    error_message = "Expected 2 kept + 2 managed statements."
  }
  assert {
    condition = [for s in jsondecode(output.policy_json).Statement : s.Principal.AWS if try(s.Sid, "") == "KiroMonReportRead"][0] == [
      "arn:aws:iam::444455556666:role/CID-DC-kiro", "arn:aws:iam::444455556666:role/kiro-acme-data-Normalizer",
    ]
    error_message = "KiroMonReportRead must name exactly the new reader roles."
  }
  assert {
    condition     = [for s in jsondecode(output.policy_json).Statement : s.Condition.StringLike["s3:prefix"] if try(s.Sid, "") == "KiroMonReportList"][0] == "kiro/*"
    error_message = "ListBucket must be limited to the kiro/ prefix."
  }
}

run "report_policy_accepts_single_statement_object" {
  command = apply
  module {
    source = "../customer/report-bucket-policy"
  }
  variables {
    bucket               = "rpt"
    existing_policy_json = jsonencode({ Version = "2012-10-17", Statement = { Sid = "KiroLogsWrite", Effect = "Allow", Principal = { Service = ["q.amazonaws.com"] }, Action = "s3:PutObject", Resource = "arn:aws:s3:::rpt/kiro/*" } })
    reader_role_arns     = ["arn:aws:iam::444455556666:role/CID-DC-kiro"]
  }
  assert {
    condition     = output.kept_sids == ["KiroLogsWrite"]
    error_message = "A single statement object must be kept."
  }
}

run "report_policy_refuses_to_drop_kiro_write" {
  command = plan
  module {
    source = "../customer/report-bucket-policy"
  }
  variables {
    bucket           = "rpt"
    reader_role_arns = ["arn:aws:iam::444455556666:role/CID-DC-kiro"]
  }
  expect_failures = [aws_s3_bucket_policy.this]
}

run "report_policy_rejects_non_role_principal" {
  command = plan
  module {
    source = "../customer/report-bucket-policy"
  }
  variables {
    bucket               = "rpt"
    existing_policy_json = var.existing_two
    reader_role_arns     = ["arn:aws:iam::444455556666:root"]
  }
  expect_failures = [var.reader_role_arns]
}

# ------------------------------------------------------------ idc-read-role (5.6, 5.8)

run "idc_role_before_sample_pins_principal_pattern" {
  command = apply
  module {
    source = "../customer/idc-read-role"
  }
  variables {
    slug                     = "acme"
    identity_store_id        = "d-xxxxxxxxxx"
    observability_account_id = "444455556666"
    external_id              = "kiro-mon-acme-ab12cd34"
  }
  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Principal.AWS == "arn:aws:iam::444455556666:root"
    error_message = "Before narrowing, the principal is the observability account."
  }
  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Condition.ArnLike["aws:PrincipalArn"] == "arn:aws:iam::444455556666:role/kiro-acme-identity-map*"
    error_message = "Before narrowing, aws:PrincipalArn must pin the identity-map role name."
  }
  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Condition.StringEquals["sts:ExternalId"] == "kiro-mon-acme-ab12cd34"
    error_message = "ExternalId is always required."
  }
  assert {
    condition     = jsondecode(output.permissions_json).Statement[0].Resource[0] == "arn:aws:identitystore::111122223333:identitystore/d-xxxxxxxxxx"
    error_message = "ListUsers must be scoped to the one Identity Store."
  }
  assert {
    condition     = jsondecode(output.permissions_json).Statement[0].Action == "identitystore:ListUsers"
    error_message = "Only ListUsers is granted."
  }
}

run "idc_role_narrowed_to_exact_role" {
  command = apply
  module {
    source = "../customer/idc-read-role"
  }
  variables {
    slug                     = "acme"
    identity_store_id        = "d-xxxxxxxxxx"
    observability_account_id = "444455556666"
    external_id              = "kiro-mon-acme-ab12cd34"
    identity_map_role_arn    = "arn:aws:iam::444455556666:role/kiro-acme-identity-map-IdentityMapLambdaRole-ABC"
  }
  assert {
    condition     = jsondecode(output.trust_policy_json).Statement[0].Principal.AWS == "arn:aws:iam::444455556666:role/kiro-acme-identity-map-IdentityMapLambdaRole-ABC"
    error_message = "After narrowing, the principal is the exact role."
  }
  assert {
    condition     = !can(jsondecode(output.trust_policy_json).Statement[0].Condition.ArnLike)
    error_message = "After narrowing, no ArnLike pattern remains."
  }
}

run "idc_role_rejects_instance_id" {
  command = plan
  module {
    source = "../customer/idc-read-role"
  }
  variables {
    slug                     = "acme"
    identity_store_id        = format("ssoins-%s", "7223abcdef012345")
    observability_account_id = "444455556666"
    external_id              = "kiro-mon-acme-ab12cd34"
  }
  expect_failures = [var.identity_store_id]
}

run "idc_role_rejects_role_from_other_account" {
  command = plan
  module {
    source = "../customer/idc-read-role"
  }
  variables {
    slug                     = "acme"
    identity_store_id        = "d-xxxxxxxxxx"
    observability_account_id = "444455556666"
    external_id              = "kiro-mon-acme-ab12cd34"
    identity_map_role_arn    = "arn:aws:iam::222233334444:role/kiro-acme-identity-map-x"
  }
  expect_failures = [aws_iam_role.this]
}

# ------------------------------------------------------------ trail (6.3)

run "trail_records_kiro_data_events_only" {
  command = apply
  module {
    source = "../customer/trail"
  }
  variables {
    bucket_name              = "kiro-mon-trail-acme-444455556666"
    observability_account_id = "444455556666"
  }
  assert {
    condition     = length(aws_cloudtrail.this.event_selector) == 0
    error_message = "No basic event selector: management events would be recorded."
  }
  assert {
    condition     = aws_cloudtrail.this.kms_key_id == null
    error_message = "No KMS key: log files use the bucket's SSE-S3 default."
  }
  assert {
    condition     = length(aws_cloudtrail.this.advanced_event_selector) == 1
    error_message = "Exactly one advanced selector."
  }
  assert {
    condition = toset([for f in aws_cloudtrail.this.advanced_event_selector[0].field_selector : "${f.field}=${join(",", f.equals)}"]) == toset([
      "eventCategory=Data", "resources.type=AWS::CodeWhisperer::Profile",
    ])
    error_message = "Selector must be Data events of AWS::CodeWhisperer::Profile only."
  }
  assert {
    condition     = !aws_cloudtrail.this.is_multi_region_trail && !aws_cloudtrail.this.include_global_service_events && aws_cloudtrail.this.enable_log_file_validation
    error_message = "Single-Region, no global events, log validation on."
  }
}

run "trail_adds_event_name_filter_when_given" {
  command = apply
  module {
    source = "../customer/trail"
  }
  variables {
    bucket_name              = "kiro-mon-trail-acme-444455556666"
    observability_account_id = "444455556666"
    event_names              = ["GenerateAssistantResponse"]
  }
  assert {
    condition     = length(aws_cloudtrail.this.advanced_event_selector[0].field_selector) == 3
    error_message = "eventName filter must be added as a third field selector."
  }
}

run "trail_rejects_bucket_outside_observability_account" {
  command = plan
  module {
    source = "../customer/trail"
  }
  variables {
    bucket_name              = "kiro-mon-trail-acme-111122223333"
    observability_account_id = "444455556666"
  }
  expect_failures = [aws_cloudtrail.this]
}

# ------------------------------------------------------------ prompt-logs (7.1)

run "prompt_logs_never_name_the_observability_account" {
  command = apply
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                     = "acme"
    observability_account_id = "444455556666"
    retention_days           = 90
    auditor_principal_arns   = ["arn:aws:iam::111122223333:role/SecurityAudit"]
  }
  assert {
    condition     = !strcontains(output.policies_json, "444455556666")
    error_message = "Policies must not mention the observability account."
  }
  assert {
    condition     = output.s3_uri_for_kiro_console == "s3://acme-kiro-prompt-logs-111122223333/kiro-prompt-logs/"
    error_message = "Console URI must be bucket + prefix."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Condition.ArnLike["aws:SourceArn"] if s.Sid == "KiroLogsWrite"][0] == "arn:aws:codewhisperer:us-east-1:111122223333:*"
    error_message = "KiroLogsWrite must use the documented aws:SourceArn condition."
  }
  assert {
    condition     = length(aws_iam_role.auditor) == 1 && aws_iam_role.auditor[0].name == "kiro-prompt-auditor"
    error_message = "Auditor role must exist when principals are given."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "Block Public Access must be on."
  }
  assert {
    condition     = [for r in aws_s3_bucket_server_side_encryption_configuration.this.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm] == ["AES256"]
    error_message = "Prompt bucket uses SSE-S3, no KMS key."
  }
  assert {
    condition     = aws_athena_workgroup.this[0].configuration[0].result_configuration[0].encryption_configuration[0].encryption_option == "SSE_S3"
    error_message = "Athena results use SSE-S3."
  }
  assert {
    condition     = !strcontains(output.policies_json, "kms:")
    error_message = "No policy grants a KMS action."
  }
  assert {
    condition     = strcontains(aws_glue_catalog_table.prompt_logs[0].storage_descriptor[0].columns[0].type, "timestamp:string,modelid:string>")
    error_message = "The chat request struct must carry modelid (design 3.5)."
  }
  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.expiration[0].days if r.id == "expire-prompt-logs"] == [90]
    error_message = "Prompt logs must expire after retention_days."
  }
  assert {
    condition     = !aws_s3_bucket.this.force_destroy
    error_message = "The prompt bucket must not be force-destroyed (Requirement 10.6)."
  }
}

run "prompt_logs_guard_fires_when_policy_names_observability_account" {
  command = plan
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                     = "acme"
    observability_account_id = "111122223333"
    retention_days           = 90
  }
  expect_failures = [aws_s3_bucket_policy.this]
}

run "prompt_logs_no_auditor_by_default" {
  command = apply
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                     = "acme"
    observability_account_id = "444455556666"
    retention_days           = 90
  }
  assert {
    condition     = length(aws_iam_role.auditor) == 0
    error_message = "No auditor role without principals."
  }
}

# ------------------------------------------------------------ prompt-metadata, customer side (7.5)

run "promptmeta_lambda_writes_only_its_own_prefix" {
  command = apply
  module {
    source = "../customer/prompt-metadata"
  }
  variables {
    slug                     = "acme"
    prompt_bucket_name       = "acme-kiro-prompt-logs-111122223333"
    destination_bucket       = "kiro-mon-promptmeta-acme-444455556666"
    observability_account_id = "444455556666"
  }
  assert {
    condition     = [for s in jsondecode(output.policy_json).Statement : s.Resource if s.Sid == "WriteMetadataOnly"][0] == "arn:aws:s3:::kiro-mon-promptmeta-acme-444455556666/promptmeta/account_id=111122223333/*"
    error_message = "The Lambda may write only under its own account partition."
  }
  assert {
    condition     = !strcontains(output.policy_json, "kms:")
    error_message = "SSE-S3 prompt bucket: the Lambda needs no KMS action."
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables.SOURCE_ACCOUNT_ID == "111122223333"
    error_message = "SOURCE_ACCOUNT_ID must be the customer account."
  }
}

run "promptmeta_rejects_destination_outside_observability_account" {
  command = plan
  module {
    source = "../customer/prompt-metadata"
  }
  variables {
    slug                     = "acme"
    prompt_bucket_name       = "acme-kiro-prompt-logs-111122223333"
    destination_bucket       = "someone-elses-bucket"
    observability_account_id = "444455556666"
  }
  expect_failures = [aws_lambda_function.this]
}

# ------------------------------------------------------------ cur-export (4.1, 4.3)

run "cur_export_is_cid_layout_with_kiro_filter" {
  command = apply
  module {
    source = "../customer/cur-export"
  }
  variables {
    observability_account_id = "444455556666"
  }
  assert {
    condition     = endswith(output.query, "FROM COST_AND_USAGE_REPORT WHERE line_item_product_code = 'Kiro'")
    error_message = "Query must end with the Kiro filter."
  }
  assert {
    condition     = aws_bcmdataexports_export.kiro.export[0].name == "cid-cur2"
    error_message = "Export name must match CID's, so CID reads it unchanged."
  }
  assert {
    condition     = aws_bcmdataexports_export.kiro.export[0].data_query[0].table_configurations.COST_AND_USAGE_REPORT.INCLUDE_RESOURCES == "TRUE"
    error_message = "Resource IDs are required for CID's license counts."
  }
  assert {
    condition     = output.destination == "s3://cid-444455556666-data-exports/cur2/111122223333/cid-cur2/data/"
    error_message = "Destination must follow CID's cur2/<source account>/cid-cur2/data/ layout."
  }
}

# ------------------------------------------------------------ central prompt bucket + landing (2026-11-05)
# 111122223333 = management account (central bucket, mocked caller),
# 222233334444 = another Kiro account, 444455556666 = observability.

run "prompt_logs_central_takes_replicas_and_one_reader" {
  command = apply
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                         = "acme"
    observability_account_id     = "444455556666"
    retention_days               = 180
    replication_source_role_arns = ["arn:aws:iam::222233334444:role/kiro-mon-prompt-replication-kiro01"]
    reader_role_arns             = ["arn:aws:iam::444455556666:role/service-role/aws-quicksight-service-role-v0"]
  }
  assert {
    condition     = length(aws_s3_bucket_versioning.this) == 1
    error_message = "A replication destination needs versioning."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Principal.AWS if s.Sid == "LandingReplicationWrite"][0] == ["arn:aws:iam::222233334444:root"]
    error_message = "Replication principal is the source account root (always exists)."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Condition.ArnEquals["aws:PrincipalArn"] if s.Sid == "LandingReplicationWrite"][0] == ["arn:aws:iam::222233334444:role/kiro-mon-prompt-replication-kiro01"]
    error_message = "Replication is narrowed to the exact landing role."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Action if s.Sid == "LandingReplicationWrite"][0] == ["s3:ReplicateObject", "s3:ReplicateTags"]
    error_message = "No ReplicateDelete: deletes in a landing bucket never reach the central copy."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Principal.AWS if s.Sid == "CentralReadPromptLogs"][0] == ["arn:aws:iam::444455556666:role/service-role/aws-quicksight-service-role-v0"]
    error_message = "D11: the only observability principal is the named reader role."
  }
  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.this.policy).Statement : s.Action if s.Sid == "CentralReadPromptLogs"][0] == "s3:GetObject"
    error_message = "The reader may only read."
  }
  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.noncurrent_version_expiration[0].noncurrent_days if r.id == "expire-prompt-logs"] == [1]
    error_message = "Noncurrent versions must not outlive the retention."
  }
}

run "prompt_logs_refuses_reader_outside_observability_account" {
  command = plan
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                     = "acme"
    observability_account_id = "444455556666"
    retention_days           = 180
    reader_role_arns         = ["arn:aws:iam::222233334444:role/someone"]
  }
  expect_failures = [aws_s3_bucket_policy.this]
}

run "prompt_logs_refuses_wildcard_reader" {
  command = plan
  module {
    source = "../customer/prompt-logs"
  }
  variables {
    slug                     = "acme"
    observability_account_id = "444455556666"
    retention_days           = 180
    reader_role_arns         = ["arn:aws:iam::444455556666:role/*"]
  }
  expect_failures = [var.reader_role_arns]
}

run "prompt_landing_replicates_to_central_without_deletes" {
  command = apply
  module {
    source = "../customer/prompt-landing"
  }
  variables {
    slug               = "kiro01"
    central_bucket     = "acme-kiro-prompt-logs-333344445555"
    central_account_id = "333344445555"
  }
  assert {
    condition     = output.s3_uri_for_kiro_console == "s3://kiro-prompt-landing-111122223333/kiro-prompt-logs/"
    error_message = "Console URI must be the landing bucket of this account."
  }
  assert {
    condition     = [for r in aws_s3_bucket_replication_configuration.this.rule : r.delete_marker_replication[0].status] == ["Disabled"]
    error_message = "Delete markers must not be replicated."
  }
  assert {
    condition     = [for r in aws_s3_bucket_replication_configuration.this.rule : r.destination[0].account] == ["333344445555"]
    error_message = "Destination account must be the central account."
  }
  assert {
    condition     = [for s in jsondecode(output.replication_policy_json).Statement : s.Resource if s.Sid == "WriteCentral"][0] == "arn:aws:s3:::acme-kiro-prompt-logs-333344445555/kiro-prompt-logs/*"
    error_message = "The role writes only the prompt prefix of the central bucket."
  }
  assert {
    condition     = !strcontains(output.replication_policy_json, "s3:Delete") && !strcontains(output.replication_policy_json, "ReplicateDelete")
    error_message = "The replication role must not delete."
  }
  assert {
    condition     = [for s in jsondecode(output.bucket_policy_json).Statement : s.Condition.StringEquals["aws:SourceAccount"] if s.Sid == "KiroLogsWrite"][0] == "111122223333"
    error_message = "Only this account's Kiro writes the landing bucket."
  }
  assert {
    condition     = [for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.expiration[0].days] == [30]
    error_message = "Landing copies expire after landing_retention_days."
  }
  assert {
    condition     = output.replication_role_arn == "arn:aws:iam::111122223333:role/kiro-mon-prompt-replication-kiro01"
    error_message = "Role ARN handed to the central bucket must be deterministic."
  }
}

run "prompt_landing_refuses_the_central_account" {
  command = plan
  module {
    source = "../customer/prompt-landing"
  }
  variables {
    slug               = "acme"
    central_bucket     = "acme-kiro-prompt-logs-111122223333"
    central_account_id = "111122223333"
  }
  expect_failures = [aws_s3_bucket.this]
}
