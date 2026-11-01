# Tiếp nối ngày 22/10/2026

Đã khôi phục yêu cầu Claude gần nhất: hoàn tất bốn nhóm AI, Docker/ops, CI và refactor/trợ năng Flutter. Các thay đổi cũ được giữ nguyên; không commit, push hoặc reset.

## Thay đổi hoàn tất

- AI so sánh candidate/incumbent trên cùng hàng validation, loại khoảng incumbent từng fit/tune và chừa gap 7 ngày. Có kiểm tra hash hàng, baseline công bằng, Brier và giá trị hữu hạn; test chỉ dùng báo cáo.
- Archive lưu ngưỡng mưa tại lúc phát hành, theo phiên bản model. Bản ghi cũ thiếu ngưỡng không bị chấm bằng ngưỡng mới; được loại khỏi F1 và đếm riêng. Migration thêm cột nullable, giữ nguyên dự báo cũ.
- Extension giữ metrics mưa/Brier của base. Interval chỉ được chọn khi đạt gate; không có cấu hình đạt thì báo lỗi trước khi ghi artifact. Reviewer đã đóng cả ba findings bằng 10 regression riêng.
- Webhook không ghi URL chứa token, kể cả INFO của HTTPX. Rate limiter giữ hard cap 10.000 bucket và trạng thái throttle của client đang có; khi đầy, client mới có thể phải chờ bucket được kiểm tra refill. Có 24 tests ops đạt.
- CI chạy Ruff, pytest, coverage runtime backend và LCOV Flutter với ngưỡng 80%; golden Windows chặn build. Test hợp đồng Flutter–FastAPI dùng HTTP thật và SQLite tổng hợp tạm, tắt ingest.
- Home/Map/Locations/Settings chính còn 384/398/393/313 dòng. Hoàn tất tách widget, vùng chạm, nhãn và semantic actions, phản ứng khi đổi đơn vị, chữ lớn và tương phản. Giữ ảnh golden hiện có.
- Test stat SQLite được đặt timestamp nền xác định để tránh trùng clock tick trên Windows; regression riêng xác nhận revision dữ liệu thời tiết vẫn tăng khi timestamp file không đổi.

## Kết quả kiểm chứng cuối

| Kiểm tra | Kết quả | Bằng chứng |
| --- | --- | --- |
| Backend đầy đủ, bỏ fixture training | 569 passed, 15 skipped; 75,22 giây | build/continue-20261022-backend-verified.log và .xml |
| Coverage runtime backend | 88,73%; gate 80% | build/continue-20261022-backend-verified-coverage.xml |
| Flutter không-golden | 733 passed, 7 skipped; 3 phút 40 giây | build/continue-20261022-flutter-verified.log |
| Flutter coverage | 13.288/15.838 = 83,90%; gate 80% | coverage/lcov.info |
| Golden Windows | 16 passed, không cập nhật reference | build/continue-20261022-golden.log |
| Flutter analyzer | No issues found | build/continue-20261022-analyze-final.log |
| HTTP contract | 3/3 passed, chạy lại sau migration cuối | tool/run_backend_contract.py; build/backend-contract-api.log |
| Ruff / coverage checker | Ruff đạt; 3 unit tests đạt | Lệnh CI tương ứng đã chạy local |
| Trợ năng / refactor focused | 12/12 passed | Agent chạy hai file accessibility_test.dart, screen_refactor_test.dart |
| Review ML cuối | Đóng ba findings; 10 regression passed | Review độc lập trên code và CSV/artifact đã sửa |

7 Flutter tests bị skip gồm 4 live-backend tests và 3 contract tests; 3 contract tests đã chạy riêng thành công. Không chạy 4 live tests trong lượt này. Lượt coverage chạy song song trước bị lỗi Dart VM getSourceReport 112; chạy lại tuần tự thành công, CI đã dùng concurrency=1. Lượt backend 20:37 trùng lúc worker sửa mã không phải kết quả cuối.

Backend dùng Python 3.14.8 local và báo 589 warnings, trong đó có ResourceWarning về kết nối SQLite. Không coi đây là output sạch warning; CI Python 3.12 chưa được chạy trên GitHub. Coverage backend chỉ đo mã runtime, không gồm script chuẩn bị dữ liệu/huấn luyện offline.

## Model và artifact

Audit build/ml-selection-audit-20261022-7d96.json chấm 427.326 hàng, 67 ô, cửa sổ 01/01–23/09/2025, chính sách rain_calibration_only. Hai model dùng cùng hash hàng và baseline.

| Chỉ số validation | Ứng viên | Model hiện hành |
| --- | ---: | ---: |
| MAE nhiệt độ | 0.52543 | 0.53319 |
| F1 mưa | 0.62421 | 0.61508 |
| Brier mưa | 0.09854 | 0.10086 |

Đã sao lưu toàn bộ candidate: D:/wether_app/build/backup/candidate-before-final-audit-20261022 (46 file, 145.306.920 bytes). Sau đó đồng bộ 5 trường Brier cho 204 cell–horizon gồm alias (201 unique) từ per_cell_metrics.csv, chỉ lấy model=full/split=test và dùng rounding Python. Reviewer đối chiếu 0 sai lệch. selection_v3.json khớp từng byte với audit mới. Không sửa booster, không retrain và chưa promote; models/v3 đang phục vụ được giữ nguyên.

Coverage interval trong report candidate là 88,47% / 88,09% / 89,29% tại 1/3/6 giờ, dưới mục tiêu 90%. Interval report chưa được đánh giá lại đầy đủ sau sửa serving fallback; giữ candidate riêng. Backtest 5 fold trên 22/67 ô đã hoàn tất ở phiên trước, không phải lượt chạy mới hay đánh giá đủ 67 ô. Dữ liệu là đầu ra mô hình, không phải quan trắc trạm; coverage interval không phải phần trăm độ chính xác.

## Giới hạn

Bản web build thành công trong 57,5 giây, log `build/continue-20261022-web-build.log`. Preview tại http://127.0.0.1:8113, API http://127.0.0.1:8026 (lifespan off, INGEST_ENABLED=0). Đã xác nhận root, main.dart.js, /live và /health đều HTTP 200. Lúc 21:13 (+07), health degraded: dữ liệu mới nhất 00:00 ngày 22/10/2026, fresh 0/68; preview dùng dữ liệu lưu cũ. Không dùng kết quả này làm bằng chứng freshness hoặc kiểm tra hình ảnh trình duyệt.

SHA-256 của cả 30 booster candidate khớp bản sao lưu. `git diff --check` đạt; chỉ có cảnh báo chuyển LF/CRLF.

Chưa chạy GitHub runner, Docker runtime, điện thoại thật, Workmanager/TalkBack/VoiceOver, FPS/pin hoặc iOS signing/App Groups. Không tự chấm app trên 9. Không ingest dữ liệu live trong lượt này.
