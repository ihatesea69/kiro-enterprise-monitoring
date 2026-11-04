# Vendored sample and local patches

## Upstream

| | |
|---|---|
| Repository | [aws-samples/sample-kiro-user-analytics-quicksight-dashboard](https://github.com/aws-samples/sample-kiro-user-analytics-quicksight-dashboard) |
| Commit | `1f5f5b8d1ffe84776c4d8005eb0cdaf31e3882f5` (2026-10-09) |
| License | MIT-0 (`LICENSE` in the vendored folder) |
| Import method | `git -c core.autocrlf=false archive` of that commit, so files keep LF endings |
| Import check | all 50 files hashed with `git hash-object --no-filters`: 50/50 equal to the upstream blobs |
| Unmodified import | commit `d73fc39` on this repo, so `git diff d73fc39 -- vendor/` shows every local change |

`.gitattributes` sets `vendor/** -text` so a Windows checkout does not convert these files to CRLF. `deploy.sh` and `preflight.sh` do not run under bash with CRLF.

## SHA256 of the patched files, before patching

| File | SHA256 (upstream) |
|---|---|
| `cfn/01-data-layer.yaml` | `5991b1453c72236cafba203d9893fbdc19d554289769d914b0dba0246698dde2` |
| `cfn/03-identity-mapping.yaml` | `9a926993fc5a038a980a725171f065dd78ef2f4107a5dd5bd2a535c419651de7` |
| `scripts/deploy.sh` | `ad857299fd009dfce1ca3fcdc1c52c2fae327cce58b98522206fbd2676e24b43` |
| `scripts/preflight.sh` | `804e60cc696ad0d292aa635d4680201409dfdd0dc7846d1e3659b98253fbc1b2` |
| `scripts/identity_map_lambda.py` | `34a58a1795ddb00e82bc1d9c0dc9cb6311a30d494ed3c24f6c1dc9b3708476f8` |
| `scripts/teardown.sh` | `fc3092a889f1e51180e4c8746a861bdfea84b685e23f9658dba6ddf2c381dfa3` |
| `scripts/build_views.py` (P6, P8) | `82d83bfe68609189c3f5e70dfad867150850ebbe515b7d90a669821319c250a9` |
| `scripts/normalize_report_lambda.py` (P8) | `21aae6c65f0f91b09846ce1ce4f682dfd4f82a4511195d4a3934852773463865` |
| `scripts/create_dashboard.py` (P8) | `8b7d0a7a5c9481b1e18afb05de7b8ab1e327d0c7f1ee176de51fbf46a47ff27c` |
| `cfn/02-quicksight.yaml` (P8) | `60e72dca0124fc8e14c4651a86e5927cbfe992d96d882dff6ebf0213fa621029` |

## Patches

P1-P3 keep upstream behaviour when their new input is empty. P4 changes upstream behaviour unconditionally (decision D9 in `design.md`). Every inserted block is marked `PATCH P<n> (kiro-enterprise-monitoring)`.

### P1. Report written by another account

- `cfn/01-data-layer.yaml`: new parameter `SourceAccountId` (default `""`, pattern `^$|^[0-9]{12}$`), new condition `HasSourceAccount` added to the existing `Conditions` block, and `RAW_PREFIX` uses `SourceAccountId` when set, else `AWS::AccountId`.
- `scripts/deploy.sh`: reads `KIRO_SOURCE_ACCOUNT_ID` (default `""`), passes `SourceAccountId=${KIRO_SOURCE_ACCOUNT_ID}` in both data-stack `--parameter-overrides` blocks, and `probe_prefix` uses `${KIRO_SOURCE_ACCOUNT_ID:-$ACCOUNT_ID}`. Header comment documents the variable.

### P2. Preflight when the report bucket is in another account

- `scripts/preflight.sh`: reads `KIRO_SOURCE_ACCOUNT_ID`. When it is set and differs from the caller account, step 5 prints a `WARN` and does not list the bucket. The person deploying has no list permission on the customer bucket by design; the normalizer invoke result after deploy is the real check. Otherwise step 5 is unchanged, including its `FAIL`.

### P3. ExternalId for the Identity Center role

- `scripts/identity_map_lambda.py`: `_idc_client` adds `ExternalId` to `sts.assume_role` only when `IDC_EXTERNAL_ID` is non-blank. Docstring documents the variable.
- `cfn/03-identity-mapping.yaml`: new parameter `IdcExternalId` (default `""`) wired to the Lambda environment as `IDC_EXTERNAL_ID`.
- `scripts/deploy.sh`: reads `IDC_EXTERNAL_ID` (default `""`) and passes `IdcExternalId=${IDC_EXTERNAL_ID}` to the identity-map stack.

### P4. No KMS key for the identity map

Added 2026-10-29. The operator chose SSE-S3 for every bucket this project creates (D9), to drop the per-customer key fee.

- `cfn/03-identity-mapping.yaml`: `IdentityMapKey` (`AWS::KMS::Key`, `DeletionPolicy: Retain`) and `IdentityMapKeyAlias` removed. `IdentityMapBucket` uses `SSEAlgorithm: AES256` without `BucketKeyEnabled`. The Lambda role's `KmsForIdentityMap` policy and the `IdentityMapKeyArn` output removed. Access logging, versioning, the TLS-only bucket policy and Block Public Access are unchanged.
- `scripts/deploy.sh`: no longer reads `IdentityMapKeyArn`, and no longer passes `--kms-key-arn` to `grant_quicksight_s3.py`. QuickSight still gets `read` on the identity-map bucket.
- `scripts/teardown.sh`: the "identity-map KMS key is retained" note removed.
- Not changed: `SourceKmsKeyArn` and `KMS_KEY_ARN`, the optional pass-through for a key the customer owns on the report bucket. This project requires that bucket to be SSE-S3, so the value stays empty.
- Not changed: upstream `README.md` and `SECURITY.md` still describe the dedicated CMK. For this repo, this section replaces those statements.
- Trade-off: anyone with `s3:GetObject` on the identity-map bucket can read names and emails. There is no second `kms:Decrypt` check and no CloudTrail record of key use per read.

Diff size against `d73fc39`, tests excluded: 6 files, 63 insertions, 68 deletions. P4 alone: 3 files, 16 insertions, 59 deletions.

### P5. Optional permissions boundary on the roles the sample creates

Added 2026-11-02. The first real deploy into the observability account failed on `NormalizerLambdaRole`: an identity policy in that account denies `iam:CreateRole` unless the request sets one specific permissions boundary.

- `cfn/01-data-layer.yaml` and `cfn/03-identity-mapping.yaml`: new parameter `PermissionsBoundaryArn`, default empty, pattern `^$|^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+`. `NormalizerLambdaRole` and `IdentityMapLambdaRole` get `PermissionsBoundary: !If [HasPermissionsBoundary, !Ref PermissionsBoundaryArn, !Ref AWS::NoValue]`. These are the only `AWS::IAM::Role` resources in the three templates.
- `scripts/deploy.sh`: new env var `PERMISSIONS_BOUNDARY_ARN`, default empty, passed to both data-layer deploys and the identity-map deploy. Not passed to the QuickSight stack, which creates no role.
- Empty value keeps upstream behaviour: `AWS::NoValue` drops the property.

### P6. Projection range of the report tables (S3 LIST cost)

Added 2026-11-02. Upstream projected `export_date` of `report_facts_raw` and `report_models_raw` over `2020-01-01,NOW+1YEARS`. Athena lists one S3 prefix per projected day on every query without an `export_date` filter, empty prefix or not, and the views have no such filter. That is about 2,860 LIST per table read on each of the 8 daily SPICE refreshes and the identity-map query, growing by 365 a year. A sibling project paid for the same pattern (a 2024-2030 range refreshed every 15 minutes).

- `scripts/build_views.py`: `report_tables_ddl()` takes `projection_start` and `projection_end` (defaults are the upstream values, so callers and tests that pass three arguments are unchanged). Both are validated against `yyyy-MM-dd` or `NOW[+-]<n><DAYS|WEEKS|MONTHS|YEARS>`. New CLI flags `--projection-start` and `--projection-end`.
- `scripts/deploy.sh`: `PROJECTION_START` is **required**, with no default; the script stops before any AWS call if it is unset or malformed. `PROJECTION_END` defaults to `NOW`. Both are passed to the two `build_views.py` calls.
- Use the day the Kiro report was enabled as the start (Kiro does not backfill earlier days). After 13 months (D5) switch to `NOW-13MONTHS` to cap the range at about 396 days.

### P7. Scoped Athena inline policy for QuickSight

Added 2026-11-02. Upstream relies on the account-wide managed policy `AWSQuicksightAthenaAccess` on the shared QuickSight service role. Another project's Terraform in the same account owns an `aws_iam_role_policy_attachment` for that policy and detached it on destroy (CloudTrail, 2026-11-02 06:30:49 UTC), so every SPICE refresh here failed with `athena:StartQueryExecution` denied.

- New `scripts/grant_quicksight_athena.py`: writes inline policy `<STACK_PREFIX>-QuickSightAthenaAccess`. Athena query actions only on this deployment's workgroup, catalog metadata on `AwsDataCatalog`, three list actions on `*`, Glue read only on this deployment's database and its tables, `lakeformation:GetDataAccess`. No write action. Idempotent: prints `[OK] ... already matches` and exits 0 when the live policy equals the rendered one.
- `scripts/deploy.sh` step 4c runs it with `--apply` before the QuickSight stack. Step 4b (the managed-policy check) is unchanged, so the managed policy is still attached when missing.
- `scripts/teardown.sh` deletes only `<STACK_PREFIX>-QuickSightAthenaAccess`; it never detaches the shared managed policy.
- Measured on the first customer: with only this inline policy (managed policy detached), a SPICE ingestion COMPLETED. IAM policy simulator on the live document: 6/6 decisions as expected (own workgroup and database allowed; workgroup `primary`, another database, and `glue:DeleteTable` denied).

### P8. Remaining monthly credits per user (credit headroom)

Added 2026-11-03. Kiro allocates plan credits per calendar month and resets them on the 1st. The report carries each user's limit in `Usage_Limit`, which upstream's normalizer dropped. On the first customer's first full day each user used 45-50% of a 10,000 limit, so the dashboard has to flag users before they hit the cap. P8 is additive: no existing view output, dataset column, visual or schedule changes, and the tests pin that by sha256 against the pre-P8 output.

- `scripts/normalize_report_lambda.py`: new `_FACT_TRAILING_COLUMNS = ["usage_limit"]`, matched by header like every other column and written AFTER the bookkeeping columns, so it is the last field of a facts part. Parts written before P8 have one field fewer, and OpenCSVSerDe reads a missing trailing field as NULL, the same way pre-`part_id` parts read `part_id`/`processed_ts`. `_BOOKKEEPING` and the models parts are unchanged.
- `scripts/build_views.py`: `report_facts_raw` gains a trailing `usage_limit string`. The `report_facts` and `report_models` views are byte-identical: both select explicit columns.
- New `athena/0b_credit_headroom.sql`, view `credit_headroom`, one row per user per calendar month: `month`, `user_id`, `user_label`, `idc_username`, `idc_email`, `user_tier`, `usage_limit`, `credits_used_mtd`, `remaining_credits` (limit minus used, floored at 0), `pct_used` (above 1 in overage), `overage_enabled`, `overage_cap`, `overage_credits_used`, `as_of_date`, `days_elapsed`, `days_in_month`, `projected_month_end_credits` (used x days in month / days elapsed), `status`, `is_latest_month`.
  - Credits, overage and tier come from `base_user_activity`, so they are deduped through `report_facts`; all client rows of the month are summed. `usage_limit` comes from `report_facts_raw`: the latest non-empty value in the month, ordered like the `report_facts` dedup (`export_ts`, `processed_ts`, `part_id`).
  - `days_elapsed` runs from the 1st to the latest `activity_date` in the data, not the wall clock, capped at the month's last day. A finished month projects to its actual total.
  - Status, from two constants in the view's `params` CTE (`watch_pct = 0.75`, `at_risk_pct = 0.90`): `UNKNOWN_LIMIT` when the limit is NULL or <= 0 (not scored; remaining and pct are NULL, never 100%), `EXHAUSTED` when used >= limit, `AT_RISK` when pct >= 0.90 or the projection reaches the limit, `WATCH` when pct >= 0.75, else `OK`.
- `cfn/02-quicksight.yaml`: `CreditHeadroomDataSet` (SPICE, `<prefix>-credit-headroom`) and `CreditHeadroomRefreshSchedule`, daily `FULL_REFRESH` at 04:55 UTC, after the existing 04:00-04:50 schedules.
- `scripts/create_dashboard.py`: dataset identifier `headroom`. On Economics, below the existing tiles: KPI "Users at risk of running out of credits" (distinct users with `AT_RISK` or `EXHAUSTED`) and table "Credit headroom by user (latest month)", sorted by `pct_used` descending. Both are pinned to `is_latest_month = 'Yes'` and follow the Tier picker; the date-range picker does not apply to them. No conditional formatting: the sample uses none.
- `scripts/deploy.sh`: `credit-headroom` added to `QS_ALL_DATASETS` and `QS_LABEL_DATASETS`. `scripts/teardown.sh` is unchanged: the dataset and its schedule belong to the QuickSight stack, which teardown deletes.
- Cost: one more daily SPICE refresh. The view reads the raw facts table about four times (twice through `base_user_activity`, once through `user_dim`, once directly), each listing the days P6 projects.
- Limits: the first month after the report is enabled misses usage from before the enable date, so remaining credits read high in that month. The projection is linear from the 1st, so one heavy early day already flags `AT_RISK`. A user whose only rows in a month were normalized before P8 reads `UNKNOWN_LIMIT` until a newer export or the backfill below.

Applying P8 to an existing deployment:

1. `python tools/package_sample.py` at the merged commit, then `scripts/deploy.sh` with the same variables as the first deploy. The normalizer zip is keyed by content hash, so the function gets the new code; deploy.sh then invokes it, recreates the report tables with the new column, builds every view including `credit_headroom`, creates the dataset and schedule, and updates the dashboard.
2. Files normalized before P8 are skipped by the (key, ETag) check, so their parts keep no `usage_limit`. The view fills a month from any newer export, so the next scheduled run (03:15 UTC) fills it for every user active that day. To fill every user now: add `REPROCESS_ALL=true` to the normalizer's environment (keep `RAW_BUCKET`, `RAW_PREFIX`, `OUT_BUCKET`, `OUT_PREFIX`), invoke it once, then remove the variable. The same part keys are rewritten in place, so nothing is deleted or orphaned.
3. Refresh SPICE for `<prefix>-credit-headroom`, or wait for the 04:55 UTC schedule.

### P12. Membership checks that read a list

Added 2026-11-04. Three checks asked "is this ARN in the list the AWS CLI returned" and answered "no" for things that were there. They are two different defects.

- **Crash (`deploy.sh`, the managed policy check).** The check was `aws ... | tr '\t' '\n' | grep -Fixq "${ATHENA_POLICY_ARN}"`. GNU grep 3.0 in Git for Windows aborts (exit 134) on `-F` together with `-i`, with or without a pipe. Every deploy printed "AWSQuicksightAthenaAccess is NOT attached" and attached it again. The second attach changed nothing, so the effect was a wrong message and one useless IAM call. Seen on the first customer on 2026-11-04. `-Fx`, `-Fxq` and `-i` alone are fine.
- **SIGPIPE (`deploy.sh`, `preflight.sh` twice).** Under `set -o pipefail`, `list | grep -q` ends the grep at the first match, the writer gets SIGPIPE and the pipeline fails, so a list longer than the pipe buffer reads as "not found". Measured with a fake list of 2,000 ARNs and the wanted one first: the old form failed 30 of 30 runs, a list of 20 entries never. `preflight.sh` used it for the QuickSight user and group lookup, so an account with many users could read "Principal not found".
- **Change.** `deploy.sh` gets a function `has_line_ci` that lower-cases both sides (no `-i`), matches a whole line with `-Fx`, and hands grep a string instead of a pipe. `preflight.sh` gets `has_line`, the same without the lower-casing, because it never matched case-insensitively. Answers are otherwise as before: whole line only, and a failed `aws` call still means "no".
- **Left alone on purpose.** `deploy.sh` `printf '%s' "${STACK_PREFIX}" | grep -Eq ...` and `run-checks.sh` `... | head -1 | grep -q 'version 3'` pipe one short string that is fully written before grep exits; they cannot hit the SIGPIPE case and were measured not to.
- **P8 test.** `test_deploy_sh_change_is_only_those_lines` puts the original 3 lines back at the P12 spot before it hashes `deploy.sh`, so it still proves that nothing outside the P8 and P12 blocks changed. An unrelated edit to `deploy.sh` still fails it.

## Tests

`tests/test_crossaccount_patches.py` has 13 tests for P1-P3. Each patch is tested with its new input both set and empty. `tests/test_no_kms_patch.py` has 7 tests for P4.

| Run | Ran | Pass | Error | Skipped |
|---|---|---|---|---|
| Upstream, before patching | 145 | 134 | 10 | 1 |
| After P1-P3 | 158 | 147 | 10 | 1 |
| After P1-P4 | 165 | 154 | 10 | 1 |
| After P1-P5 | 170 | 159 | 10 | 1 |
| After P1-P6 | 181 | 170 | 10 | 1 |
| After P1-P7 | 189 | 178 | 10 | 1 |
| After P1-P8, pytest, the 9 `TestTagMerge` tests deselected | 218 | 214 | 0 | 4 |
| After P1-P8 and P12, same selection, Git Bash first on `PATH` | 236 | 235 | 0 | 1 |

- The 10 errors are the same in both runs, all in `test_versioning.TestTagMerge`. That test starts `bash` through Python `subprocess`, which on this Windows machine resolves to the WSL launcher in System32 instead of Git Bash and fails with a WSL RPC error. They do not touch any patched code path.
- Against the five upstream files restored byte-exact, 9 of the 13 new tests fail. The 4 that pass on upstream guard upstream behaviour that must survive (one `Conditions` block, the same-account `FAIL`, no `ExternalId` when the variable is empty or unset).
- P4: against the three upstream files restored byte-exact, all 7 P4 tests fail.
- P6: `tests/test_projection_range_patch.py` has 11 tests, 3 of them run the `deploy.sh` guard block under Git Bash. Against the tree before P6, 10 fail; the one that passes checks that `report_tables_ddl()` keeps the upstream default for three-argument callers.
- The 10 `TestTagMerge` errors have a found cause: `subprocess.run(["bash", ...])` on Windows searches System32 before `PATH`, so it starts the WSL launcher even when Git Bash is first on `PATH`. The P6 guard tests call the path `shutil.which("bash")` returns.
- P5: `tests/test_permissions_boundary_patch.py` has 5 tests. Against the tree before P5 (`git archive HEAD`), all 5 fail. `cfn-lint` on all three templates after P5: 0 findings.
- P8: `tests/test_credit_headroom_patch.py` has 38 tests. They run the view's scoring SQL (`params`, `scored`, `rated`) unchanged in sqlite3 on 13 fixture cases, run the normalizer handler against a fake S3 (skip without `REPROCESS_ALL`, same-key rewrite with it), and pin the pre-P8 bytes of the dedup views, the dashboard definition minus the P8 additions, the QuickSight template minus the two P8 resources, and `deploy.sh` minus the P8 lines. Ten single-defect mutations each fail at least one test: the normalizer dropping the column, the column moved before the bookkeeping columns, `report_facts` gaining the column, the WATCH threshold changed, the projection ignored, an unknown limit shown as headroom, an existing schedule moved, the dataset dropped from `QS_LABEL_DATASETS`, an existing Economics tile resized, the KPI counting WATCH. The 4 skips in the P8 row are the boto3-stub test and the 3 P6 guard tests, skipped because only the WSL bash was on `PATH` in that session.
- `cfn-lint` 1.52.0 on all three templates: 0 findings before and after, including after P4. After P8, `cfn/02-quicksight.yaml`: 0 findings (a planted bad `RefreshType` in a scratch copy is reported, so the run is live).
- P12: `tests/test_grep_pipefail_patch.py` has 18 tests. The behaviour tests cut the real blocks out of `deploy.sh` and `preflight.sh` and run them under bash with `set -euo pipefail` and a fake `aws`: policy present, present in another case, only a longer line that contains it, absent, empty list, failed `aws` call, and a 5,000-entry list with the match first. Against the scripts from `main`, 17 of the 18 fail (the old block also prints "NOT attached" for a list that holds the policy, together with grep's `Aborted`); the one that passes guards the two short-string checks that must stay as they are. Four single-line breaks of the fix: three are caught (`-Fixq` back, the lower-casing of one side dropped, the pipe back); a fourth, dropping a `|| true`, changed nothing, so that `|| true` was removed from the patch.
- `bash -n` on `deploy.sh`, `preflight.sh` and `teardown.sh`: 0 errors after patching.
- `preflight.sh` run under Git Bash with a stub `aws` CLI: cross-account prints `[WARN] report bucket belongs to account ...` and makes 0 list calls on the bucket; same-account still prints `[FAIL] user_report not found` after 1 list call.

## Remaining account-pinned paths

`grep AWSLogs` over `cfn/`, `scripts/` and `athena/` (tests excluded):

- `cfn/01-data-layer.yaml`: `RAW_PREFIX` (patched) and two parameter descriptions.
- `scripts/deploy.sh`: `probe_prefix` (patched) and a comment.
- `scripts/preflight.sh` lines 169 and 213: still use the caller account, but only on the same-account branch that P2 leaves unchanged.

## Upgrading the sample

Export the new upstream commit the same way, re-apply P1-P8 by searching for the `PATCH P<n>` markers, re-run the test suite, and update the tables above.
