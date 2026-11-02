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

## Tests

`tests/test_crossaccount_patches.py` has 13 tests for P1-P3. Each patch is tested with its new input both set and empty. `tests/test_no_kms_patch.py` has 7 tests for P4.

| Run | Ran | Pass | Error | Skipped |
|---|---|---|---|---|
| Upstream, before patching | 145 | 134 | 10 | 1 |
| After P1-P3 | 158 | 147 | 10 | 1 |
| After P1-P4 | 165 | 154 | 10 | 1 |
| After P1-P5 | 170 | 159 | 10 | 1 |
| After P1-P6 | 181 | 170 | 10 | 1 |

- The 10 errors are the same in both runs, all in `test_versioning.TestTagMerge`. That test starts `bash` through Python `subprocess`, which on this Windows machine resolves to the WSL launcher in System32 instead of Git Bash and fails with a WSL RPC error. They do not touch any patched code path.
- Against the five upstream files restored byte-exact, 9 of the 13 new tests fail. The 4 that pass on upstream guard upstream behaviour that must survive (one `Conditions` block, the same-account `FAIL`, no `ExternalId` when the variable is empty or unset).
- P4: against the three upstream files restored byte-exact, all 7 P4 tests fail.
- P6: `tests/test_projection_range_patch.py` has 11 tests, 3 of them run the `deploy.sh` guard block under Git Bash. Against the tree before P6, 10 fail; the one that passes checks that `report_tables_ddl()` keeps the upstream default for three-argument callers.
- The 10 `TestTagMerge` errors have a found cause: `subprocess.run(["bash", ...])` on Windows searches System32 before `PATH`, so it starts the WSL launcher even when Git Bash is first on `PATH`. The P6 guard tests call the path `shutil.which("bash")` returns.
- P5: `tests/test_permissions_boundary_patch.py` has 5 tests. Against the tree before P5 (`git archive HEAD`), all 5 fail. `cfn-lint` on all three templates after P5: 0 findings.
- `cfn-lint` 1.52.0 on all three templates: 0 findings before and after, including after P4.
- `bash -n` on `deploy.sh`, `preflight.sh` and `teardown.sh`: 0 errors after patching.
- `preflight.sh` run under Git Bash with a stub `aws` CLI: cross-account prints `[WARN] report bucket belongs to account ...` and makes 0 list calls on the bucket; same-account still prints `[FAIL] user_report not found` after 1 list call.

## Remaining account-pinned paths

`grep AWSLogs` over `cfn/`, `scripts/` and `athena/` (tests excluded):

- `cfn/01-data-layer.yaml`: `RAW_PREFIX` (patched) and two parameter descriptions.
- `scripts/deploy.sh`: `probe_prefix` (patched) and a comment.
- `scripts/preflight.sh` lines 169 and 213: still use the caller account, but only on the same-account branch that P2 leaves unchanged.

## Upgrading the sample

Export the new upstream commit the same way, re-apply P1-P4 by searching for the `PATCH P<n>` markers, re-run the test suite, and update the tables above.
