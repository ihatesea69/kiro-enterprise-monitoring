# Read access to the Kiro accounts' data lakes (patch P11), against mocked providers.
# 444455556666 = dashboard account (mocked caller), 111122223333 and 222233334444 = Kiro accounts.

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
  mock_data "aws_iam_role" {
    defaults = {
      name = "aws-quicksight-service-role-v0"
      arn  = "arn:aws:iam::444455556666:role/service-role/aws-quicksight-service-role-v0"
    }
  }
}

variables {
  one = {
    kiro01 = {
      account_id    = "111122223333"
      glue_database = "kiro_kiro01"
      lake_bucket   = "kiro-mon-lake-111122223333-ap-southeast-1"
    }
  }
  two = {
    kiro01 = {
      account_id    = "111122223333"
      glue_database = "kiro_kiro01"
      lake_bucket   = "kiro-mon-lake-111122223333-ap-southeast-1"
    }
    kiro02 = {
      account_id    = "222233334444"
      glue_database = "kiro_kiro02"
      lake_bucket   = "kiro-mon-lake-222233334444-ap-southeast-1"
    }
  }
}

run "nothing_is_created_without_accounts" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug = "acme"
  }

  assert {
    condition     = length(aws_athena_data_catalog.kiro) == 0 && length(aws_iam_role_policy.cross_account_read) == 0 && output.policy_name == null
    error_message = "No account means no catalog and no policy."
  }
}

run "one_catalog_per_account_pointing_at_that_account" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug     = "acme"
    accounts = var.two
  }

  assert {
    condition     = aws_athena_data_catalog.kiro["kiro01"].type == "GLUE" && aws_athena_data_catalog.kiro["kiro01"].parameters["catalog-id"] == "111122223333" && aws_athena_data_catalog.kiro["kiro02"].parameters["catalog-id"] == "222233334444"
    error_message = "Each catalog is a GLUE catalog with the Kiro account's id."
  }

  assert {
    condition     = join(",", output.catalog_names) == "kiro01,kiro02"
    error_message = "Catalog names come from the keys."
  }
}

run "grants_are_read_only_and_scoped" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug     = "acme"
    accounts = var.two
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policy_json).Statement :
      s.Effect == "Allow" && alltrue([
        for a in flatten([s.Action]) :
        contains(["athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata", "athena:ListDatabases", "athena:ListTableMetadata",
          "glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
        "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"], a)
      ])
    ])
    error_message = "Only the read actions listed here may appear."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.policy_json).Statement :
      !contains(flatten([s.Resource]), "*") && !anytrue([for r in flatten([s.Resource]) : endswith(r, ":*") && !endswith(r, "/*")])
    ])
    error_message = "No wildcard resource."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.policy_json).Statement :
      s.Sid == "S3ReadKiroLakes" && length(s.Resource) == 2
      && contains(s.Resource, "arn:aws:s3:::kiro-mon-lake-111122223333-ap-southeast-1/normalized/*")
      && contains(s.Resource, "arn:aws:s3:::kiro-mon-lake-222233334444-ap-southeast-1/normalized/*")
    ])
    error_message = "S3 read is limited to the normalized/ prefix of each lake."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.policy_json).Statement :
      s.Sid == "GlueReadKiroAccounts" && contains(s.Resource, "arn:aws:glue:ap-southeast-1:111122223333:table/kiro_kiro01/*") && contains(s.Resource, "arn:aws:glue:ap-southeast-1:222233334444:database/kiro_kiro02")
    ])
    error_message = "Glue read is limited to each account's own database."
  }
}

run "policy_has_its_own_name_and_never_touches_existing_ones" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug     = "acme"
    accounts = var.one
  }

  assert {
    condition     = aws_iam_role_policy.cross_account_read[0].name == "kiro-acme-QuickSightCrossAccount" && output.policy_name != "kiro-acme-QuickSightAthenaAccess" && output.policy_name != "kiro-acme-QuickSightS3Access"
    error_message = "A separate policy name, so other tools that rewrite the existing two never drop these grants."
  }

  assert {
    condition     = output.consumer_role_arn == "arn:aws:iam::444455556666:role/service-role/aws-quicksight-service-role-v0"
    error_message = "The role ARN comes from the lookup and keeps its service-role path."
  }
}

run "own_account_is_refused" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug = "acme"
    accounts = {
      self = { account_id = "444455556666", glue_database = "kiro_acme", lake_bucket = "some-bucket" }
    }
  }
  expect_failures = [aws_athena_data_catalog.kiro]
}

run "bad_names_are_refused" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug = "acme"
    accounts = {
      AwsDataCatalog = { account_id = "111122223333", glue_database = "kiro_a", lake_bucket = "some-bucket" }
    }
  }
  expect_failures = [var.accounts]
}

run "two_keys_for_one_account_are_refused" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug = "acme"
    accounts = {
      a = { account_id = "111122223333", glue_database = "kiro_a", lake_bucket = "bucket-a" }
      b = { account_id = "111122223333", glue_database = "kiro_b", lake_bucket = "bucket-b" }
    }
  }
  expect_failures = [var.accounts]
}

run "oversized_policy_fails_the_plan" {
  command = plan
  module {
    source = "../observability/cross-account-catalog"
  }
  variables {
    slug             = "acme"
    accounts         = var.two
    max_policy_chars = 500
  }
  expect_failures = [aws_iam_role_policy.cross_account_read]
}

# ------------------------------------------------------------ root wiring

run "root_creates_nothing_without_lakes" {
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
    condition     = length(module.cross_account_catalog) == 0 && output.kiro_lakes_consumer_role_arn == null
    error_message = "The default root must not create the cross-account layer."
  }
}

run "root_wires_the_lakes_through" {
  command = plan
  module {
    source = "../roots/observability-customer"
  }
  variables {
    observability_account_id = "444455556666"
    slug                     = "acme"
    customer_account_id      = "111122223333"
    kiro_region              = "us-east-1"
    kiro_lakes               = var.one
  }

  assert {
    condition     = length(module.cross_account_catalog) == 1 && join(",", module.cross_account_catalog[0].catalog_names) == "kiro01"
    error_message = "One lake gives one catalog."
  }
}
