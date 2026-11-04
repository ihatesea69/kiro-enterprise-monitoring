# Requirements: Theo dõi Kiro của khách hàng, xem tập trung ở account trung tâm

## Giới thiệu

Bên vận hành cần theo dõi việc khách hàng dùng Kiro và xem toàn bộ trên dashboard ở account trung tâm, không phải đăng nhập vào account của khách. Cần theo dõi bốn mặt: chi phí, license, mức độ sử dụng và từng request. Giải pháp ghép 3 dashboard có sẵn của AWS (CUDOS, CID Kiro, sample QuickSight) với 2 nguồn log (CloudTrail data events, prompt logging).

Spec gồm 3 file:
- `requirements.md` (file này): giải pháp phải đạt được những gì, viết thành tiêu chí kiểm được.
- `design.md`: cách làm, kèm bằng chứng đã đọc hoặc đã đo, và các quyết định D1-D8.
- `tasks.md`: các bước triển khai theo thứ tự phụ thuộc. Mỗi bước có người làm và cách kiểm.

Trạng thái: bản nháp ngày 2026-10-29. Chưa tạo resource nào trên AWS.

Tiêu chí viết theo EARS: `WHEN <sự kiện> THE SYSTEM SHALL <hành vi>`, `IF <điều kiện xấu> THEN THE SYSTEM SHALL <phản ứng>`, `WHERE <tính năng tuỳ chọn được bật> THE SYSTEM SHALL <hành vi>`, và `THE SYSTEM SHALL <hành vi>` cho yêu cầu luôn đúng.

## Thuật ngữ

| Thuật ngữ | Nghĩa |
|---|---|
| Account trung tâm | Account nhận dữ liệu và đặt dashboard, trên sơ đồ gọi là Observability Management Account. Giả định QuickSight Enterprise ở `ap-southeast-1` (quyết định D6) |
| Account payer của khách | Management account trong Organization của khách. CUR tạo ở đây thì có chi phí của mọi account |
| Account Kiro của khách | Account có user subscribe Kiro, nơi Kiro profile được tạo. Kiro chỉ ghi report và prompt log vào bucket ở account này |
| Account Identity Center của khách | Account chứa Identity Center instance của khách. Có thể trùng với account payer |
| Region Kiro profile | `us-east-1` hoặc `eu-central-1` (không tính GovCloud) |
| Report | Kiro User Activity Report: CSV mỗi ngày, mỗi user một dòng cho mỗi loại client |
| Prompt log | Log toàn văn prompt và câu trả lời mà Kiro ghi vào S3 khi admin bật prompt logging |
| CUR | Cost and Usage Report 2.0, tạo bằng AWS Data Exports |
| Collector CID | Lambda của module Kiro trong CID Data Collection Stack. Mỗi ngày Lambda này kéo report từ bucket của khách về |
| Normalizer | Lambda của sample QuickSight. Lambda này đọc report theo tên cột rồi ghi bản đã chuẩn hoá vào bucket kết quả |
| Lớp 1 đến 5 | 1: CUDOS (chi phí). 2: CID Kiro (license). 3: sample QuickSight (mức dùng). 4: CloudTrail data events (request). 5: prompt logging (nội dung) |
| THE SYSTEM | Toàn bộ giải pháp: phần chạy ở account trung tâm cùng phần cấu hình ở account khách |
| Agent | Kiro agent chạy trên máy của người vận hành, thực hiện các task trong `tasks.md` |
| Toàn văn | Các field `prompt`, `assistantResponse`, `followupPrompts`, `leftContext`, `rightContext`, `completions`, `fileName`, `supplementaryWebLinksEvent`, `codeReferenceEvents` của prompt log |

## Ngoài phạm vi

- Coding metrics collector: phải cài plugin trên máy từng developer, nên không quản lý tập trung được.
- Bản xuất OpenTelemetry của Kiro, sample Streamlit, dashboard có sẵn trong Kiro console.
- Phân tích nội dung prompt bằng model (ví dụ Amazon Bedrock) để đánh giá hiệu quả hoặc phát hiện việc riêng. Làm ở giai đoạn sau, khi đã có prompt log thật (design.md mục 3.5, giai đoạn 3).
- Đánh giá pháp lý thay cho khách. Bên vận hành chỉ cung cấp danh mục dữ liệu kỹ thuật để bộ phận pháp lý của khách tự đánh giá.
- Theo dõi Kiro của chính bên vận hành. Có thể tái dùng spec này sau, khi đó account khách và account trung tâm là một.

---

## Requirement 1: Danh mục dữ liệu và sự đồng ý của khách

**User story:** Là người phụ trách dự án ở bên vận hành, tôi muốn khách biết chính xác dữ liệu nào sẽ sang bên vận hành trước khi bật bất cứ thứ gì, để không chuyển dữ liệu khách chưa đồng ý.

**Acceptance criteria**
1. WHEN bên vận hành bắt đầu onboarding một khách THE SYSTEM SHALL có file `customers/<khách>/data-inventory.md` liệt kê theo từng lớp: tên field, account nguồn, account đích, mục đích sử dụng, thời gian giữ.
2. THE SYSTEM SHALL ghi rõ trong danh mục rằng CUR không lọc chứa toàn bộ chi phí AWS của khách, không chỉ chi phí Kiro.
3. THE SYSTEM SHALL ghi rõ trong danh mục rằng lớp 4 chứa IP nguồn và user agent của từng user.
4. IF khách chưa đồng ý bằng văn bản cho một lớp THEN THE SYSTEM SHALL không tạo resource nào chuyển dữ liệu của lớp đó sang account trung tâm.
5. WHEN khách rút lại sự đồng ý cho một lớp THE SYSTEM SHALL có sẵn lệnh gỡ lớp đó ở cả hai account trong `docs/TEARDOWN.md`.

## Requirement 2: Khảo sát và đo tiền đề trước khi xây

**User story:** Là kỹ sư bên vận hành, tôi muốn đo cấu hình thật của khách và kiểm các giả định trong tài liệu trước khi viết code, để không xây trên giả định sai.

**Acceptance criteria**
1. WHEN có profile CLI của khách THE SYSTEM SHALL chạy một script khảo sát chỉ gọi API đọc, rồi ghi kết quả vào `customers/<khách>/SURVEY.md`.
2. IF account đang đăng nhập khác account mong đợi THEN THE SYSTEM SHALL dừng script khảo sát trước lời gọi API đầu tiên vào dịch vụ, và không ghi file kết quả.
3. THE SYSTEM SHALL đo và ghi lại: region và account của Kiro profile; trạng thái report và prompt logging cùng bucket đích; kiểu mã hoá và prefix của bucket report; ngày của report sớm nhất trong bucket; CUR đang có ở account nào và bắt đầu từ tháng nào; account, region và Identity Store ID của Identity Center; các trail hiện có cùng data event selector của chúng.
4. THE SYSTEM SHALL ghi vào file khảo sát chỉ số đếm, ID và cấu hình. Không ghi nội dung report, nội dung log hay giá trị credential.
5. WHEN chưa có câu trả lời cho câu hỏi mở OQ-1 (Kiro có sinh data event không) THE SYSTEM SHALL không bắt đầu task nào của lớp 4.
6. WHEN thử nghiệm lớp 4 và 5 THE SYSTEM SHALL chỉ đo số đếm, định dạng ID và độ dài nội dung. Giá trị của bất kỳ field toàn văn nào không được in ra chat, ra log hay ra file.
7. WHEN có kết quả khảo sát hoặc thử nghiệm THE SYSTEM SHALL cập nhật mục "Câu hỏi mở" trong `design.md`: ghi câu trả lời và nguồn đo.

## Requirement 3: Thu thập CUR của khách

**User story:** Là người phụ trách FinOps của dự án, tôi muốn có CUR của khách ở account trung tâm, để xem chi phí Kiro, kể cả các tháng trước khi bắt đầu dự án.

**Acceptance criteria**
1. WHEN khách đồng ý lớp 1 THE SYSTEM SHALL nhận CUR từ account payer của khách vào bucket Data Exports ở account trung tâm, theo đường dẫn `<export-name>/<account payer>/...`.
2. WHERE quyết định D2 chọn lọc chỉ Kiro THE SYSTEM SHALL chỉ nhận các dòng có `line_item_product_code = 'Kiro'`, với điều kiện câu hỏi mở OQ-7 đã chứng minh CUDOS và CID chạy đúng trên CUR đã lọc.
3. WHEN khách muốn xem các tháng trước THE SYSTEM SHALL có sẵn mẫu Support case xin backfill (tối đa 14 tháng) để account payer của khách tự gửi.
4. IF sau 72 giờ kể từ khi tạo export vẫn chưa có file CUR đầu tiên THEN THE SYSTEM SHALL báo lỗi giao CUR kèm tên export và account payer.
5. THE SYSTEM SHALL lưu trong `customers/<khách>/SURVEY.md` tháng sớm nhất có trong CUR, sau lần giao đầu và sau khi backfill xong.

## Requirement 4: Dashboard chi phí (CUDOS, lớp 1)

**User story:** Là người phụ trách FinOps của dự án, tôi muốn xem chi phí Kiro của khách theo tháng và theo account, để theo dõi xu hướng chi tiêu.

**Acceptance criteria**
1. WHEN CUR của khách đã có ở account trung tâm THE SYSTEM SHALL hiện mục Kiro trong tab AI/ML của CUDOS (bản 5.8.0 trở lên).
2. THE SYSTEM SHALL cho chi phí Kiro mỗi tháng trên CUDOS lệch không quá 1% so với Cost Explorer ở account payer của khách cho cùng tháng (đo theo Requirement 16).
3. IF account trung tâm đã có CUDOS từ trước THEN THE SYSTEM SHALL dùng lại bản đó, không deploy bản thứ hai.

## Requirement 5: Bucket report ở account Kiro của khách

**User story:** Là kỹ sư bên vận hành, tôi muốn report của khách nằm ở đúng chỗ và đúng định dạng mà cả CID lẫn sample đọc được, để một bucket phục vụ được cả lớp 2 và lớp 3.

**Acceptance criteria**
1. THE SYSTEM SHALL dùng bucket report nằm ở account Kiro của khách, cùng region với Kiro profile.
2. THE SYSTEM SHALL cấu hình S3 location của report trong Kiro console dạng `s3://<bucket>/kiro/`, để report nằm dưới `kiro/AWSLogs/<account>/KiroLogs/user_report/`.
3. THE SYSTEM SHALL dùng mã hoá SSE-S3 cho các object dưới `kiro/` của bucket report.
4. THE SYSTEM SHALL chỉ cấp cho các role của bên vận hành quyền `s3:GetObject` trên `kiro/*` và quyền `s3:ListBucket` có điều kiện `s3:prefix` là `kiro/*`. Không cấp quyền ghi hay xoá.
5. THE SYSTEM SHALL dùng một bucket report khác với bucket prompt log.
6. IF khách đã bật report ở prefix khác `kiro/` THEN THE SYSTEM SHALL ghi lại prefix cũ và ngày của report cuối cùng ở prefix đó vào `customers/<khách>/SURVEY.md`, trước khi đổi S3 location.

## Requirement 6: Dashboard license (CID Kiro, lớp 2)

**User story:** Là trưởng nhóm kỹ thuật phía khách (qua bên vận hành), tôi muốn biết license nào trả tiền mà không dùng và ai nên nâng hay hạ gói, để quyết định thu hồi hoặc đổi license.

**Acceptance criteria**
1. WHEN có report mới trong bucket của khách THE SYSTEM SHALL chép report vào bucket Data Collection ở account trung tâm trong lần chạy collector kế tiếp (03:00 UTC).
2. WHEN collector chạy lần đầu với một khách THE SYSTEM SHALL chép mọi report đã có trong bucket của khách.
3. THE SYSTEM SHALL phân vùng dữ liệu report theo `account_id`, `region` và ngày, để nhiều khách nằm chung một bảng mà không trùng file.
4. THE SYSTEM SHALL hiện dashboard CID Kiro với 5 tab: Executive Summary, User Engagement, Credit & Overage Tracking, Model & Client Breakdown, About.
5. IF collector trả `errors` khác rỗng, hoặc trả `total_files_copied = 0` trong lần chạy đầu với một bucket mới THEN THE SYSTEM SHALL báo lỗi theo Requirement 15.
6. WHEN module Kiro của CID được deploy lại THE SYSTEM SHALL gắn lại bucket policy ở account khách theo output `BucketPolicyExample` mới, vì role mới có unique ID khác role cũ.

## Requirement 7: Dashboard mức dùng (sample QuickSight, lớp 3)

**User story:** Là trưởng nhóm kỹ thuật phía khách (qua bên vận hành), tôi muốn thấy ai đang dùng, ai đang giảm dùng và model nào được chọn, để đẩy adoption trong team.

**Acceptance criteria**
1. THE SYSTEM SHALL deploy mỗi khách một bản sample riêng ở account trung tâm (với điều kiện quyết định D3 chọn đặt ở account trung tâm), tên theo `STACK_PREFIX=kiro-<khách>`.
2. THE SYSTEM SHALL đọc report của khách từ đường dẫn `kiro/AWSLogs/<account Kiro của khách>/KiroLogs/user_report/`, không dùng đường dẫn mang account trung tâm.
3. WHEN không truyền account nguồn THE SYSTEM SHALL giữ nguyên hành vi gốc của sample, tức đọc đường dẫn mang account đang deploy.
4. THE SYSTEM SHALL ghim bản sample vào commit `1f5f5b8d1ffe84776c4d8005eb0cdaf31e3882f5`, và chạy unit test có sẵn của repo trước và sau khi vá, với số test pass không giảm.
5. THE SYSTEM SHALL hiện 4 sheet của sample: Activity & Trends, Economics, People, User detail.
6. WHEN so trên cùng khoảng ngày THE SYSTEM SHALL cho số user distinct ở sample bằng số user distinct ở CID Kiro (Requirement 16).

## Requirement 8: Đổi user ID ra danh tính

**User story:** Là người xem dashboard, tôi muốn thấy tên hoặc email thay cho GUID, để biết user là ai.

**Acceptance criteria**
1. WHERE identity mapping được bật THE SYSTEM SHALL đổi user ID ra username, tên hiển thị và email qua `identitystore:ListUsers` trên Identity Center của khách.
2. THE SYSTEM SHALL đọc Identity Center của khách bằng một role chỉ đọc nằm ở account Identity Center của khách. Role này chỉ tin đúng role Lambda identity map của bản deploy cho khách đó, và bắt buộc ExternalId.
3. IF không đổi được một user ID THEN THE SYSTEM SHALL hiện GUID cho user đó, không bỏ dòng.
4. THE SYSTEM SHALL không bật đồng thời `IDENTITY_MAPPING` và `HASH_EMAILS`.
5. WHERE identity mapping được bật THE SYSTEM SHALL ghi vào danh mục dữ liệu (Requirement 1) rằng tên và email của user khách sẽ nằm trong SPICE ở account trung tâm.

## Requirement 9: Audit từng request (CloudTrail data events, lớp 4)

**User story:** Là người làm audit, tôi muốn biết mỗi request Kiro là của ai, lúc nào, thành công hay lỗi gì, để điều tra sự cố mà không phải đọc nội dung chat.

Requirement này chỉ áp dụng khi câu hỏi mở OQ-1 có câu trả lời là có.

**Acceptance criteria**
1. THE SYSTEM SHALL tạo ở account Kiro của khách một trail chỉ lấy data event loại `AWS::CodeWhisperer::Profile`, đặt ở region của Kiro profile, không lấy management event.
2. WHERE OQ-1 đã chỉ ra danh sách `eventName` cần thiết THE SYSTEM SHALL lọc trail theo đúng danh sách đó để giảm số event bị tính phí.
3. THE SYSTEM SHALL gửi log của trail vào một bucket riêng cho khách đó ở account trung tâm, với bucket policy giới hạn bằng `aws:SourceArn` đúng ARN của trail.
4. THE SYSTEM SHALL mã hoá bucket CloudTrail ở account trung tâm bằng SSE-S3, không dùng KMS key (D9). Quyền đọc log chỉ cấp qua IAM policy cho role QuickSight, role Athena của dự án và role audit của bên vận hành; bucket policy không cấp quyền đọc cho principal nào.
5. THE SYSTEM SHALL có bảng Athena đọc log CloudTrail của khách, dùng partition projection theo ngày, không cần crawler.
6. IF `get-trail-status` có `LatestDeliveryError` khác rỗng THEN THE SYSTEM SHALL báo lỗi theo Requirement 15.

## Requirement 10: Lưu prompt log ở từng account có Kiro profile (lớp 5)

**User story:** Là người vận hành, tôi muốn lưu toàn văn prompt và câu trả lời của mọi account có Kiro profile, để sau này phân tích được user dùng Kiro có hiệu quả không và có dùng cho việc riêng không.

Sửa ngày 2026-11-04 theo D11: bên vận hành được đọc toàn văn. Bản trước giữ toàn văn chỉ ở khách.

**Acceptance criteria**
1. THE SYSTEM SHALL đặt cho mỗi account có Kiro profile một bucket prompt log riêng, ở chính account đó, cùng region với Kiro profile, tách khỏi bucket report, mã hoá SSE-S3 (D9), chặn public access, chỉ cho phép kết nối TLS.
2. THE SYSTEM SHALL chỉ cho Kiro quyền `s3:PutObject` dưới prefix đã nhập trong Kiro console, với điều kiện `aws:SourceAccount` và `aws:SourceArn` là chính account đó.
3. THE SYSTEM SHALL có bảng Athena và một role audit thuộc account khách, để người của khách tự tra prompt log theo `requestId`.
4. THE SYSTEM SHALL áp lifecycle xoá prompt log theo thời gian giữ đã chốt ở D12.
5. THE SYSTEM SHALL chỉ cấp quyền đọc prompt log cho account trung tâm qua danh sách ARN role cụ thể (D11), không cấp cho cả account. Khi danh sách rỗng, không principal nào của account trung tâm đọc được.
6. THE SYSTEM SHALL không xoá bucket prompt log khi bucket còn object (`force_destroy = false`).

## Requirement 11: Metadata prompt (tuỳ chọn, lớp 5)

Không áp dụng từ 2026-11-04 (D11). Bên vận hành đã được đọc toàn văn, nên một bản chỉ có metadata không còn cần. Code `infra/customer/prompt-metadata` và `infra/observability/prompt-metadata` giữ lại, không deploy.

**User story:** Là người làm audit ở bên vận hành, tôi muốn biết request nào thuộc phiên chat nào và dài bao nhiêu, mà không đọc được nội dung, để nối lớp 4 với lớp 5.

Requirement này chỉ áp dụng khi quyết định D4 chọn chuyển metadata về bên vận hành.

**Acceptance criteria**
1. WHEN có file prompt log mới THE SYSTEM SHALL dùng một Lambda ở account khách để ghi sang account trung tâm một bản chỉ gồm các field trong danh sách cho phép ở design.md, mục "Metadata prompt".
2. THE SYSTEM SHALL không ghi sang bên vận hành bất kỳ field toàn văn nào, kể cả `fileName`.
3. THE SYSTEM SHALL có unit test chạy trên record mẫu trong tài liệu Kiro, kiểm rằng output chỉ chứa các field được phép và không chứa bất kỳ chuỗi nào của field toàn văn.
4. IF một record có cấu trúc lạ, không khớp schema đã biết THEN THE SYSTEM SHALL bỏ record đó, đếm số record bị bỏ vào metric, và không ghi nội dung record vào log của Lambda.
5. THE SYSTEM SHALL chỉ ghi số đếm và độ dài vào log của Lambda metadata, không ghi giá trị field.

## Requirement 12: Nối dữ liệu và dashboard audit

**User story:** Là người làm audit, tôi muốn một bảng request có tên user và ngữ cảnh phiên, để tra một sự cố trong vài phút.

**Acceptance criteria**
1. THE SYSTEM SHALL có view Athena `kiro_request_audit` cho mỗi khách, nối lớp 4 với danh tính user (lớp 3 hoặc lớp 2), và với prompt log (lớp 5) khi giai đoạn 2 của lớp 5 đã chạy.
2. WHERE OQ-2 chứng minh request ID của CloudTrail trùng `requestId` của prompt log THE SYSTEM SHALL nối lớp 4 với lớp 5 theo request ID.
3. IF request ID không trùng THEN THE SYSTEM SHALL chỉ nối theo user và ngày, đồng thời ghi rõ trên dashboard rằng hai nguồn không nối được theo từng request.
4. THE SYSTEM SHALL có dashboard QuickSight riêng `Kiro Request Audit - <khách>`, không thêm tab vào dashboard của CID hay sample.
5. THE SYSTEM SHALL để IP nguồn chỉ có trong Athena cho role audit, không nạp vào SPICE.

## Requirement 13: Cô lập giữa các khách

**User story:** Là người phụ trách dự án ở bên vận hành, tôi muốn dữ liệu của khách này không bao giờ lẫn sang khách khác, để bên vận hành phục vụ được nhiều khách trên cùng một account.

**Acceptance criteria**
1. THE SYSTEM SHALL dùng cho mỗi khách bucket CloudTrail, bucket metadata prompt, bản sample và dashboard audit riêng.
2. THE SYSTEM SHALL phân biệt khách trong các bảng dùng chung của CID (report, CUR) bằng `account_id`.
3. WHERE quyết định D1 cho khách xem dashboard THE SYSTEM SHALL bật row-level security theo `account_id`, hoặc tạo dashboard riêng cho từng khách, để user QuickSight của khách chỉ thấy dữ liệu của mình.
4. THE SYSTEM SHALL có bước kiểm tự động: với mỗi khách, số `account_id` distinct trong mỗi dataset của khách đó phải bằng số account của khách đó.

## Requirement 14: Bảo vệ dữ liệu

**User story:** Là người phụ trách bảo mật ở bên vận hành, tôi muốn mọi đường dữ liệu đều có quyền tối thiểu và được mã hoá, để một sai sót không làm lộ dữ liệu của khách.

**Acceptance criteria**
1. THE SYSTEM SHALL không dùng principal `*` trong bucket policy hay key policy, trừ các statement `Deny` (ví dụ chặn kết nối không TLS).
2. THE SYSTEM SHALL bật Block Public Access và chặn kết nối không TLS trên mọi bucket mới.
3. THE SYSTEM SHALL đặt tên resource AWS bằng dấu gạch ngang thường, không dùng em dash.
4. THE SYSTEM SHALL lấy credential qua profile CLI do người vận hành tự đăng nhập. Agent không nhận access key hay mật khẩu qua chat.
5. WHEN agent đọc log của lớp 4 hoặc 5 THE SYSTEM SHALL chỉ in số đếm, định dạng ID (độ dài, tiền tố) và độ dài nội dung.
6. THE SYSTEM SHALL chạy secret scan trên danh sách file đã stage trước mỗi commit, và không commit account ID của khách, Identity Store ID của khách hay tên khách vào git. Mọi file riêng của từng khách nằm trong `customers/<khách>/`, và thư mục này được gitignore trước lần `git init` đầu tiên.

## Requirement 15: Giám sát độ tươi và lỗi pipeline

**User story:** Là người vận hành, tôi muốn được báo khi một lớp ngừng nhận dữ liệu, vì CID có thể chép 0 file mà không báo lỗi.

**Acceptance criteria**
1. THE SYSTEM SHALL chạy một bước kiểm độ tươi mỗi ngày lúc 05:00 UTC, sau giờ refresh SPICE của sample (04:00 UTC).
2. IF ngày mới nhất của report trong bảng CID hoặc bảng của sample cũ hơn 2 ngày so với ngày hiện tại (UTC) THEN THE SYSTEM SHALL gửi cảnh báo, ghi rõ khách, lớp và ngày mới nhất.
3. IF metric `Errors` của Lambda collector CID lớn hơn 0, hoặc log của lần chạy gần nhất có lỗi truy cập bucket nguồn THEN THE SYSTEM SHALL gửi cảnh báo, ghi rõ bucket bị lỗi. Lần chạy theo lịch không lưu lại giá trị trả về của Lambda, nên không đọc được mảng `errors` sau khi chạy.
4. WHERE lớp 4 đang chạy, IF không có file CloudTrail mới của một khách trong 24 giờ THEN THE SYSTEM SHALL gửi cảnh báo.
5. THE SYSTEM SHALL gửi cảnh báo qua một SNS topic ở account trung tâm. Nội dung cảnh báo chỉ gồm tên khách, lớp, số đếm và ngày.

## Requirement 16: Kiểm chứng và đối chiếu số

**User story:** Là người phụ trách dự án, tôi muốn số trên các dashboard được kiểm bằng một phương pháp thứ hai độc lập, để có thể báo khách một cách tự tin.

**Acceptance criteria**
1. WHEN một lớp được deploy cho một khách THE SYSTEM SHALL ghi vào `customers/<khách>/BASELINE.md` các số đo: số dòng, số user distinct, ngày sớm nhất, ngày mới nhất, và cách đo từng số.
2. THE SYSTEM SHALL đối chiếu tổng phí Kiro mỗi tháng trong Athena (bảng CUR) với Cost Explorer ở account payer của khách. Lệch phải dưới 1%.
3. THE SYSTEM SHALL đối chiếu số user distinct trong report giữa CID và sample trên cùng khoảng ngày. Hai số phải bằng nhau.
4. WHERE lớp 4 đang chạy THE SYSTEM SHALL đo và ghi lại tỷ lệ request trong CloudTrail nối được ra danh tính user.
5. WHERE Requirement 11 được áp dụng THE SYSTEM SHALL đo và ghi lại tỷ lệ request trong CloudTrail nối được metadata prompt.
6. THE SYSTEM SHALL ghi rõ ở mỗi phép đối chiếu số liệu lấy từ công cụ nào. Số do chính pipeline tạo ra không được dùng làm bằng chứng cho chính nó.

## Requirement 17: Chi phí

**User story:** Là người phụ trách dự án, tôi muốn biết chi phí vận hành cho mỗi khách trước khi triển khai, để báo giá đúng.

**Acceptance criteria**
1. THE SYSTEM SHALL có bảng chi phí ước lượng cho mỗi khách, tách theo lớp và theo account chịu phí, kèm nguồn của từng đơn giá.
2. THE SYSTEM SHALL kiểm đơn giá CloudTrail data event bằng Price List API trước khi đưa vào báo giá.
3. THE SYSTEM SHALL chỉ cấp quyền QuickSight reader cho người có tên trong danh sách người xem đã chốt ở quyết định D1, không cấp cho toàn bộ user Kiro.
4. THE SYSTEM SHALL gắn tag `Project=kiro-monitoring` và `Customer=<khách>` cho mọi resource mới ở account trung tâm, để tách chi phí trong Cost Explorer.

## Requirement 18: Vận hành

**User story:** Là người vận hành, tôi muốn có quy trình thêm khách, cập nhật và gỡ được viết sẵn, để làm lại không phải nhớ.

**Acceptance criteria**
1. THE SYSTEM SHALL có `docs/RUNBOOK.md` gồm các quy trình: thêm khách mới, gắn lại bucket policy sau khi CID deploy lại, refresh SPICE tay, nâng cấp sample, cách đọc cảnh báo độ tươi.
2. THE SYSTEM SHALL có `docs/TEARDOWN.md` liệt kê theo từng lớp lệnh gỡ ở cả account trung tâm lẫn account khách, kèm thứ tự gỡ.
3. WHEN thêm khách thứ hai THE SYSTEM SHALL chỉ cần thêm cấu hình cho khách mới (tên bucket, account ID, biến Terraform), không phải sửa code.
4. THE SYSTEM SHALL lưu mọi hạ tầng tự viết (ngoài CID và sample) bằng Terraform trong `infra/`.

## Requirement 19: Ràng buộc thực thi trên máy của người vận hành

**User story:** Là người vận hành, tôi muốn agent làm đúng trong giới hạn policy của máy và không tự ý thay đổi account của khách, để không có thay đổi nào ngoài ý muốn.

**Acceptance criteria**
1. WHEN một bước cần `aws cloudformation deploy` (stack của CID, script deploy của sample) THE SYSTEM SHALL để người vận hành chạy bước đó trong CloudShell hoặc bằng nút Launch Stack, vì policy máy này chặn lệnh đó.
2. WHEN một bước cần xoá resource THE SYSTEM SHALL ghi sẵn lệnh xoá để người vận hành tự chạy, sau đó agent đo lại để xác nhận đã xoá.
3. WHEN agent sắp chạy một lệnh có thay đổi trên account của khách THE SYSTEM SHALL xin người vận hành xác nhận cho đúng lần chạy đó. Sự đồng ý ở đầu phiên không thay cho xác nhận này.
4. THE SYSTEM SHALL lưu file tạm và bản clone dùng một lần trong `$KIROCREW_SCRATCH`, còn file cần giữ thì lưu trong thư mục dự án.
