# Runbook vận hành

Các lệnh dưới đây giả định đang đứng ở thư mục gốc của repo. `<slug>` là tên khách trong `customers/<slug>/config.json`. Mỗi `terraform apply` là một task **[XÁC NHẬN]**: người vận hành đồng ý cho đúng lần chạy đó.

Đo ngày 2026-11-02: policy của Kiro Crew trên máy này không còn chặn `aws cloudformation deploy` (agent đã deploy stack của sample cho khách đầu tiên). Trước khi giao bước CloudFormation cho người vận hành, thử bằng một lệnh vô hại (template không tồn tại) để biết policy hiện tại.

## 1. Thêm khách mới

| Bước | Task | Ai | Việc |
|---|---|---|---|
| 1 | 0.3 | Agent | `cp -r customers/_template customers/<slug>`, điền `config.json` theo `docs/customer-config.md` |
| 2 | 1.2 | Agent, người vận hành, khách | Điền `customers/<slug>/data-inventory.md` từ `docs/data-inventory-template.md`, gửi khách, nhận đồng ý từng lớp |
| 3 | 1.3 | Người vận hành | `aws login` hoặc `aws sso login` cho từng profile ghi trong `config.json` |
| 4 | 2.2 | Agent | `python tools/survey_customer.py --customer <slug>` |
| 5 | 4.2-4.7 | Người vận hành | Stack CID (Data Exports, Data Collection với module Kiro), CUDOS. Chi tiết ở mục 6 và `design.md` mục 3.1-3.2 |
| 6 | 4.3 | Người vận hành | D2 = chỉ Kiro: root `infra/roots/payer`. D2 = toàn bộ: stack `CID-DataExports-Source` |
| 7 | 4.8-4.9 | Agent | Root `infra/roots/customer` với `report_bucket` và `report_existing_policy_file` |
| 8 | 5.6 | Agent | Cùng root, `enable_idc_read_role = true` (khi D8 = có) |
| 9 | 5.7 | Agent, người vận hành | `python tools/package_sample.py`, tải zip lên CloudShell, chạy `deploy.sh` theo docstring của script. Bắt buộc `PROJECTION_START` = ngày bật report Kiro (bản vá P6); thiếu thì script dừng |
| 10 | 5.8 | Agent | Thêm role normalizer vào `report_reader_role_arns`, đặt `identity_map_role_arn`, apply lại root customer |
| 11 | 6.x | Agent | Chỉ khi OQ-1 có event: root `infra/roots/observability-customer` với `enable_trail_bucket = true`, rồi root customer với `enable_trail = true` |
| 12 | 7.x | Agent | Root customer với `enable_prompt_logs = true`. D4 = có thì thêm `enable_prompt_metadata` ở cả hai root |
| 13 | 8.1-8.2 | Agent | `python tools/build_audit_views.py --slug <slug> --apply ...`, rồi `enable_audit_dashboard = true` |
| 14 | 9.3 | Agent | Thêm khách vào `config.customers` của root `infra/roots/shared`, apply |

Khởi tạo một root cho một khách:

```bash
cd infra/roots/observability-customer
terraform init -backend-config="path=../../../customers/<slug>/state-observability/terraform.tfstate"
terraform plan -var-file=../../../customers/<slug>/observability.tfvars -out=../../../customers/<slug>/obs.plan
# đọc plan, xin xác nhận, rồi:
terraform apply ../../../customers/<slug>/obs.plan
```

Root `customer` và `payer` làm giống vậy, với state `state-customer` và `state-payer`. Mỗi provider có `allowed_account_ids`, nên profile sai account làm plan dừng ngay.

## 2. Gắn lại bucket policy sau khi CID hoặc sample tạo lại role

Bucket policy lưu role theo unique ID. Khi role bị tạo lại (deploy lại CID, teardown rồi deploy lại sample), policy cũ không còn khớp. Dấu hiệu: collector trả `total_files_copied: 0` kèm lỗi `AccessDenied`, và cảnh báo freshness báo `issue=copy errors`.

1. Lấy ARN mới: output `LambdaRoleArn` của stack module Kiro, và role normalizer của stack `kiro-<slug>-data`.
2. Cập nhật `report_reader_role_arns` trong `customers/<slug>/customer.tfvars`.
3. `terraform plan` ở root customer: plan chỉ được đổi đúng `aws_s3_bucket_policy`. Xin xác nhận, apply.
4. Gọi collector bằng tay (`aws lambda invoke --function-name CID-DC-kiro-user-activity-Lambda out.json`) và kiểm `errors: []`.

## 3. Refresh SPICE bằng tay

```bash
# Dataset của sample: <STACK_PREFIX>-<tên dataset trong cfn/02-quicksight.yaml>
aws quicksight create-ingestion --aws-account-id <observability-account-id> --region ap-southeast-1 \
  --data-set-id kiro-<slug>-base-user-activity --ingestion-id manual-$(date +%Y%m%d%H%M%S)
# Dashboard audit: Direct Query (D10), không có SPICE để refresh. Mở dashboard là đọc dữ liệu mới.
# CID: trong CloudShell
cid-cmd refresh --dashboard-id kiro-user-activity
```

## 4. Nâng cấp sample lên commit mới

1. Export commit mới bằng `git -c core.autocrlf=false archive`, giải nén đè vào `vendor/sample-kiro-user-analytics-quicksight-dashboard/`, commit riêng một commit "vendor: unmodified".
2. Kiểm `git hash-object --no-filters` của từng file bằng blob upstream, như `vendor/PATCHES.md` ghi.
3. Vá lại P1-P4: tìm các khối `PATCH P<n>` trong commit trước, áp lại đúng các dòng đó.
4. Chạy test gốc trước và sau khi vá, `cfn-lint`, rồi cập nhật bảng trong `vendor/PATCHES.md`.
5. `python tools/package_sample.py` và deploy lại bằng `deploy.sh`.

## 5. Đọc cảnh báo freshness

Mỗi tin SNS có dạng `customer=<slug>, layer=<lớp>, issue=<vấn đề>, latest=<ngày>, lag_days=<số>`.

| layer | issue | Nguyên nhân hay gặp | Việc làm |
|---|---|---|---|
| report via CID | late, no data | Bucket policy trỏ role cũ, khách đổi S3 location, bucket chuyển sang SSE-KMS | Mục 2. Kiểm `get-bucket-encryption` và S3 location trong Kiro console |
| report via sample | late | Normalizer lỗi, policy chưa có role normalizer | Đọc log normalizer, mục 2 |
| collector | copy errors (access_denied > 0) | Bucket policy | Mục 2 |
| collector | no run logged in 24 h | Schedule của collector bị tắt, hoặc stack lỗi | Kiểm EventBridge rule của module Kiro |
| collector | lambda errors | Collector chết giữa chừng (timeout, bộ nhớ) | Đọc log `/aws/lambda/CID-DC-kiro-user-activity-Lambda` |
| cloudtrail | no log file in 24 h | Trail tắt, `LatestDeliveryError`, hoặc không ai dùng Kiro trong ngày | `aws cloudtrail get-trail-status --name kiro-mon-audit` ở account khách |
| prompt metadata | late | Lambda metadata lỗi, hoặc không ai chat | Log của `kiro-mon-promptmeta-<slug>` ở account khách, metric `SkippedRecords` |
| cur | no file 72 h after export creation | Bucket policy của data-exports, hoặc export cross-account không giao được | `aws bcm-data-exports get-export` ở account payer |

Không chép nội dung lỗi vào chat hay ticket nếu nó chứa tên bucket hoặc key của khách.

## 6. Xin backfill CUR (task 4.4)

Khách mở case từ **account payer** (Source Account). Mẫu lấy từ tài liệu CID, mục "Support ticket example":

```text
Service: Billing
Category: Other Billing Questions
Subject: Backfill Data

Hello Dear Billing Team,
Please can you backfill the data in DataExport named `cid-cur2` for last 12 months.
Thanks in advance,
```

Hoặc trong CloudShell của account payer:

```bash
aws support create-case \
    --subject "Backfill Data" \
    --service-code "billing" \
    --severity-code "normal" \
    --category-code "other-billing-questions" \
    --communication-body "Hello Dear Billing Team, Please can you backfill the data in DataExport named 'cid-cur2' for last 12 months. Thanks in advance"
```

- Tối đa 14 tháng. Không backfill được cho thời gian trước khi account được tạo hoặc trước khi account vào Organization hiện tại.
- Tên export `cid-cur2` dùng cho cả hai cách tạo: stack của CID và root `infra/roots/payer`.
- Ghi số case vào `customers/<slug>/BASELINE.md`.

## 7. Chạy thử OQ (task 3.2-3.7)

1. `cd infra/experiments/oq`, init với state `customers/<D7>/state-oq/terraform.tfstate`, plan với `account_id`, `kiro_region`, xin xác nhận, apply.
2. Kiro console > Settings > Logging: bật prompt logging, nhập output `prompt_logs_s3_uri`. Ghi giờ bật theo UTC.
3. Chat thử 3 câu ở IDE, 2 câu ở CLI, mỗi câu cách nhau ít nhất 5 phút. Ghi giờ vào `customers/<D7>/oq-chat-times.txt`, mỗi dòng `<ISO-8601 UTC> <ide|cli|error>`. Không ghi nội dung câu chat.
4. Sau 30 phút, chạy lệnh trong output `measure_command`. Lệnh chỉ in số đếm và hình dạng ID.
5. Gỡ theo `docs/TEARDOWN.md` mục 7.
