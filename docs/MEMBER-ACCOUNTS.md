# Customer-side data plane for each Kiro account (patch P10)

Each Kiro account of an organization gets its own copy of the pipeline. Nothing is shared between accounts, and each account pays for what runs in it. The dashboard account only reads.

| In the Kiro account | Region | Why |
|---|---|---|
| Report bucket, backup bucket, replication | Region of the Kiro profile | Kiro writes the report there |
| Normalizer Lambda + daily rule, lake bucket, Glue database and two raw tables | Region of the dashboard account | Athena reads another account's Glue catalog only in the same Region |

Code: `infra/customer/data-lake` (module) and `infra/roots/member-account` (root, one state per account). Tests: `infra/tests/tests/data-lake.tftest.hcl`, `tools/tests/test_data_lake_columns.py`, `tools/tests/test_verify_backup.py`.

Out of scope here, later patches: the identity map (management account only), the Data Exports CUR, and the cross-account catalog, views and dataset in the dashboard account.

## What it creates per account

- `kiro-user-report-<acct>`: versioning, SSE-S3, Block Public Access, TLS-only, `prevent_destroy`, an explicit deny on `s3:DeleteBucket`. Kiro may write only `kiro/*`, only from this account's `codewhisperer` ARN.
- `kiro-mon-backup-<acct>`: replica of `kiro/` through S3 replication. Delete markers are not replicated. The bucket policy denies deleting objects, versions or the bucket for everyone.
- `kiro-mon-lake-<acct>-<region>`: the normalized facts and models. Old versions expire after 30 days; the data itself is rebuilt from the report.
- Lambda `kiro-mon-normalizer-<slug>` (arm64, 256 MB, no VPC), rule `cron(15 3 * * ? *)`, log group with 30 days. Its role reads only this account's `user_report/` prefix and writes only `normalized/`.
- Glue database `kiro_<slug>` with `report_facts_raw` (18 columns, ending in `usage_limit`) and `report_models_raw` (10 columns). Both project the rolling window `NOW-3MONTHS,NOW`, which is about 92 S3 prefixes per read. A fixed old start date or an end in the future is refused by a variable validation.
- Optional: lake bucket policy and Glue resource policy that let the dashboard account's QuickSight role read (set `consumer_role_arns`). Read actions only.

Cost per account, from the measured pilot of the old design: about $0.4 a month (S3 LIST of the projected window about $0.35; Lambda, logs, Glue and EventBridge are below the free tier).

## Before the first apply (checks, nothing changes)

1. The target account is the one you mean: `aws sts get-caller-identity` through the assumed role, and the root refuses any other account (`allowed_account_ids`).
2. `aws lakeformation get-data-lake-settings` in the account: if Lake Formation governs the catalog, the cross-account read needs extra grants (open question U3).
3. The account has no Glue resource policy you would overwrite: `aws glue get-resource-policy`. If it has one, set `manage_glue_resource_policy = false`.
4. `terraform plan` shows only creates and no destroy. Stop on anything else.

## Pilot account (new account, nothing exists yet)

```
cd infra/roots/member-account
terraform init -backend-config="path=../../../customers/<slug>/state-<account-slug>/terraform.tfstate"
terraform plan  -var-file=../../../customers/<slug>/<account-slug>.tfvars -out=plan.tfplan
# review, then, after the user confirms this run:
terraform apply plan.tfplan
```

Then, in the Kiro console of that account (done by the user): create the profile with the organization's Identity Center, turn on the user activity report with the output `report_s3_uri_for_kiro_console` (it ends in `/kiro/`).

Measure, do not assume:

- an object appears under `kiro/AWSLogs/<acct>/KiroLogs/` within a minute (open question U4: a member account's Kiro writes into its own bucket);
- the next 02:00 UTC report is replicated: `python tools/verify_backup.py --source kiro-user-report-<acct> --backup kiro-mon-backup-<acct> --profile <p>` exits 0;
- after 03:15 UTC the normalizer log shows `files_failed: 0`, and the row count in `normalized/facts/` equals the row count of the CSV (count both with a second tool).

## Account that already has a report bucket (the management account)

The bucket exists and holds the only copy of the history, so Terraform must adopt it, never create or replace it.

1. Back it up first and prove it:
   ```
   aws s3 sync s3://kiro-user-report-<acct>/kiro/ s3://kiro-mon-backup-<acct>/kiro/ --profile <p> --region <report-region>
   python tools/verify_backup.py --source kiro-user-report-<acct> --backup kiro-mon-backup-<acct> --profile <p>
   ```
   The backup bucket is created by the first, targeted apply: `terraform apply -target=module.data_lake.aws_s3_bucket.backup ...` plus the resources the sync needs. Do not continue until `verify_backup.py` prints `OK`.
2. Import the existing bucket and its settings into the state, one by one (names below are for account `<acct>`):
   ```
   terraform import module.data_lake.aws_s3_bucket.report kiro-user-report-<acct>
   terraform import module.data_lake.aws_s3_bucket_versioning.report kiro-user-report-<acct>
   terraform import module.data_lake.aws_s3_bucket_server_side_encryption_configuration.report kiro-user-report-<acct>
   terraform import module.data_lake.aws_s3_bucket_public_access_block.report kiro-user-report-<acct>
   terraform import module.data_lake.aws_s3_bucket_ownership_controls.report kiro-user-report-<acct>
   terraform import module.data_lake.aws_s3_bucket_policy.report kiro-user-report-<acct>
   ```
3. `terraform plan` must show for the report bucket only: the lifecycle rule and the replication rule created, the tag set updated, and the bucket policy changed. Read the policy diff: the statements `KiroMonReportRead` and `KiroMonReportList` that let the dashboard account read the bucket disappear because the normalizer now runs in this account. Nothing may be destroyed. Apply only after the user confirms this run.
4. Keep the old pipeline stacks in the dashboard account until the new lake has a full set of days and the counts match. Then give the user the `delete-stack` commands; the buckets of those stacks are `Retain` and stay.

## Rebuilding the lake from the report

The normalized lake can always be rebuilt from the report. Invoke the normalizer once with `REPROCESS_ALL=true` in its environment (then remove it): every report file is read again and the same part keys are rewritten in place.

## Protection against deleting by mistake

- `prevent_destroy` on the report and backup buckets: `terraform destroy` stops with an error.
- The report bucket denies `s3:DeleteBucket`; the backup bucket denies deleting objects, versions and the bucket. To remove either, first remove the deny statement in a separate, confirmed change.
- CloudFormation stacks of the old pipeline can be protected with `aws cloudformation update-termination-protection --enable-termination-protection` (one command per stack; not done by this patch).
