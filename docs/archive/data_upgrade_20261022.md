# Nâng cấp dữ liệu và AI ngày 22/10/2026

Đã tải, chuẩn hóa và audit dữ liệu bổ sung; chạy learning curve, thử hiệu chỉnh interval, huấn luyện ba model nhiệt độ bằng nhãn trạm và đánh giá trên giai đoạn mới hơn. Model phục vụ toàn app được giữ nguyên vì kết quả chưa đủ để thay cho mọi ô/horizon. Không commit, push hoặc upload dữ liệu.

## Dữ liệu đã có thực tế

| Nguồn | Kết quả | Vai trò và giới hạn |
| --- | --- | --- |
| Open-Meteo modeled history | 5.758.241 hàng, 67 ô, 01/01/2017–21/10/2026 23:00; thêm 4.824 hàng | Giữ đúng nguồn đầu ra mô hình, không gọi là quan trắc trạm |
| NOAA NCEI ISD/Global Hourly | 36 CSV, 130.555.716 bytes; 335.392 reports, 335.139 nhiệt độ hợp lệ QC | 4 trạm, 2017–24/08/2025 UTC; 194.498 giờ-trạm canonical sau khử trùng |
| IEM METAR lịch sử | 14 CSV có dữ liệu, 5.272.298 bytes; 40.436 reports | VVTS/VVCT, 25/08/2025–22/10/2026; 40.432 nhiệt độ numeric provisional; nguồn ít QC |
| NOAA AWC METAR gần đây | 192 reports trong khoảng 48 giờ: VVTS 96, VVCT 96 | VVCS không có reports; manifest ghi partial; dữ liệu này trùng một phần IEM, không cộng thành mẫu độc lập |

NOAA ISD có Tân Sơn Nhất, Nhà Bè, Côn Sơn và Cần Thơ. Cần Thơ được giữ làm dữ liệu tham chiếu vùng, nhưng bị loại khỏi model/benchmark trong phạm vi dự án vì cách ô gần nhất 114,332 km. Nguồn IEM liệt kê VVCT trong LA__ASOS; tọa độ và tên trạm được kiểm chứng, không suy vùng địa lý từ tên network. VVCS không có dữ liệu ở các truy vấn IEM/AWC đã thử nên không mở rộng tải giả định.

Không có lượng mưa đúng chu kỳ 1 giờ đủ điều kiện trong các nguồn trạm đã tải. Không biến missing/trace thành 0; không chia lượng mưa 6/24 giờ thành lượng mưa giờ; p01i IEM không có cửa sổ tích lũy đáng tin để dùng làm nhãn. Không tuyên bố đã cải thiện dự báo mưa bằng quan trắc mới. Chưa có radar/trạm mưa địa phương đã được xác minh để tích hợp.

Các thư mục dữ liệu local (đã ignore khỏi Git):

- backend/data/history/ và raw_requests/: modeled history và 7 phản hồi tải mới.
- backend/data/observations/: raw ISD, derived reports/hourly/precipitation_windows, manifest và audit.
- backend/data/observations_metar_history/: IEM raw/derived, manifest, audit và coverage theo năm.
- backend/data/observations_metar/: raw AWC, recent_reports.csv và manifest.

Danh mục máy đọc được: backend/models/evaluation/data_upgrade_20261022/data_registry.json.

## Audit và bảo vệ dữ liệu

Đã snapshot SQLite bằng backup API trước cập nhật: build/data-upgrade-20261022/history-before.db (1.001.132.032 bytes) và weather-before.db (67.637.248 bytes). Không chỉ copy file chính khi WAL đang hoạt động.

Audit trước/sau trên toàn bộ 67 ô: quick_check OK, không timestamp trùng/lệch giờ, không gap nội bộ, không số không hữu hạn hoặc range flag trong các khoảng vật lý rộng đã công bố. Có 5.082 giá trị thiếu trên 462 hàng thuộc 00:00–06:00 ngày 01/01/2017; giữ thiếu, không impute 0. Đây là kiểm tra chất lượng cơ bản, không chứng minh mọi giá trị là đo đúng ngoài thực tế.

Bảy request lịch sử mới có raw response và SHA-256, đủ từng giờ của cửa sổ yêu cầu; tổng trọng số 79,2. So với snapshot, không sửa giá trị hàng cũ từ 17/10/2026; chỉ thêm ngày mới. Backfill hiện từ chối batch thiếu giờ trước khi lưu hoặc đánh dấu chunk hoàn tất. Parser dùng validation finite/timezone/array của ingest.

ISD giữ QC/sentinel/unit/timezone; cutoff lọc cả reports, hourly endpoints và cửa sổ mưa. Payload sai station hoặc toàn ngày lỗi được đánh dấu invalid, có --retry-invalid. Derived được xác minh liên kết raw/hash trước khi benchmark/train. Timestamps tương lai không được dùng tại issue; giờ-trạm là quan trắc gần nhất trước giờ kết thúc. ISD thiếu receipt latency nên đánh giá vẫn là hindcast.

QA độc lập: 151 raw/derived ISD hashes, 22 raw + 4 derived IEM hashes và 3 raw + 1 CSV AWC hashes khớp. Các lỗi tải thiếu, cutoff sai, nguồn parse lỗi và bỏ qua checksum đã được sửa kèm regression.

## Kết quả AI

### 1. Learning curve

18 model, 10 ô đại diện, horizon 1/3/6 giờ; cùng split và hàng holdout, sampling 1/4, 300 vòng tối đa, hai threads. Thời gian 85,311 giây; peak 427,781 MiB. Không tuning theo test; model và climatology có ngưỡng mưa tune riêng trên val_es.

| Số năm train | MAE test 3h (°C) | F1 mưa | Brier |
| --- | ---: | ---: | ---: |
| 1 | 0,616393 | 0,515951 | 0,117011 |
| 3 | 0,596279 | 0,527533 | 0,112775 |
| 6 | 0,586915 | 0,532177 | 0,112112 |

Thêm năm cũ giúp trong mẫu này nhưng lợi ích giảm dần; F1 6h không tăng đều. Dự án đã có gần 10 năm dữ liệu nên chưa có căn cứ tải hàng loạt năm cũ hơn. Không coi thí nghiệm 10 ô là kết quả production toàn thành phố. Chi tiết docs/learning_curve_20261022.md.

### 2. Nhãn nhiệt độ trạm thật

Đã lưu ba LightGBM regressors mới ở backend/models/station_temperature_candidate_20261022/. Chỉ dùng 79 đặc trưng lưới hiện có, nhãn QC thật tại Nhà Bè/Tân Sơn Nhất/Côn Sơn. Fit target đến 24/12/2023; early stopping trên năm 2024; test năm 2025 đến cuối dữ liệu ISD, có purge bảy ngày. Không dùng nhiệt độ trạm tương lai làm feature.

| Horizon | Nhãn test chung | MAE (°C) | RMSE (°C) |
| --- | ---: | ---: | ---: |
| 1h | 9.300 | 0,785678 | 1,113194 |
| 3h | 9.318 | 0,812224 | 1,147937 |
| 6h | 9.307 | 0,878184 | 1,236263 |

Train 35,515 giây, peak 448,672 MiB. Save/reload parity đạt; checksum/schema được lưu. Thắng hai persistence theo MAE/RMSE ở 8/9 cặp trạm–horizon; TSN 1h vẫn thua station persistence (0,841033 so với 0,761157 MAE). Thêm kiểm tra climatology chỉ fit trên nhãn train, không dùng val/test. Chi tiết docs/station_temperature_20261022.md và station_temperature_external.json.

### 3. Kiểm tra giai đoạn mới hơn

Dùng nguyên ba booster đã đóng băng; đánh giá Tân Sơn Nhất với IEM từ 02/09/2025 đến 21/10/2026, sau holdout cũ và khoảng cách bảy ngày. Không retrain hoặc chọn cấu hình theo kỳ mới. Nguồn IEM provisional, không ngang chất lượng ISD.

| Horizon | Số nhãn | Candidate MAE | Station persistence MAE | Station climatology MAE |
| --- | ---: | ---: | ---: | ---: |
| 1h | 9.946 | 0,825991 | 0,729540 | 1,260626 |
| 3h | 9.944 | 0,873044 | 1,779968 | 1,260863 |
| 6h | 9.941 | 0,950767 | 2,994769 | 1,261060 |

Ứng viên tốt hơn các baseline tại 3/6h trong mẫu này, nhưng 1h vẫn thua persistence. Các bên dùng cùng số hàng/hash, climatology chỉ học từ nhãn đến 24/12/2023. Đây chưa phải so sánh với AI production hiện hành trên cùng nhãn, cũng chưa chứng minh skill vận hành vì thiếu issue-vintage và độ trễ nhận quan trắc. Không tự động promote hoặc áp model ba trạm cho 67 ô.

### 4. Interval 90%

Đã chạy một cấu hình hiệu chỉnh khóa trước, calibration 10/2025–03/2026 và evaluation 04–10/2026, trên 67 ô. Kết quả mới: 87,08% / 86,37% / 86,03% tại 1/3/6h; không đạt 90%, 6h còn giảm. Gate từ chối; không ghi đè interval phục vụ. 804 parity checks đạt, 30 booster không đổi. Thời gian 431,83 giây; đây là tái sử dụng hồi cứu test cũ, không phải kỳ test mới độc lập. Chi tiết docs/interval_upgrade_20261022.md.

## Dữ liệu live và kiểm thử

Ingest ID58, 21:44:34–21:44:57 (+07) ngày 22/10: 67/67 chuỗi thành công, thêm 1.407 hàng live, sửa 529 hàng overlap, 8 HTTP requests; dữ liệu tới 21:00, không gap. Bốn Flutter live tests chạy lại đều đạt; health healthy, bundle 48 giờ/7 ngày. Đây là kết quả tại thời điểm kiểm tra, không cam kết freshness sau đó. Preview API8026 vẫn lifespan off, không có scheduler của process này.

- Backend full cuối: 650 passed, 15 skipped fixture training, 2 subtests; 61,36 giây.
- Coverage runtime 89,39%, gate 80%; log/XML build/data-upgrade-20261022/backend-tests.* và backend-coverage.xml.
- Ruff và git diff --check đạt. Backend có 599 warnings, gồm SQLite ResourceWarning; chưa xử lý toàn bộ cảnh báo lịch sử.
- Review độc lập data và methodology đạt trong phạm vi thay đổi. Không chạy lại full Flutter/golden vì lượt này không sửa Flutter; 4 live tests là kết quả mới, khác với 733/16 tests của lượt trước.

## Tái lập

Chạy từ backend/ bằng Python thật đã cài dependencies:

~~~text
python scripts/audit_history_quality.py --out models/evaluation/data_upgrade_20261022/history_after.json
python scripts/backfill_history.py --status
python scripts/backfill_history.py --max-hours 0.2 --max-items 8
python scripts/fetch_station_observations.py --offline
python scripts/fetch_metar_history.py --offline
python scripts/fetch_recent_metar.py --hours 48
python scripts/benchmark_station_history.py --out models/evaluation/data_upgrade_20261022/station_alignment.json
python scripts/evaluate_station_temperature_external.py
~~~

Các lệnh không có --offline có thể tải mạng; manifest giữ nguồn/hash. Lệnh train_station_temperature.py từ chối ghi đè thư mục candidate đã có. Không chạy lại train chỉ để có thêm output giống nhau. Các script học/interval có giới hạn tài nguyên và report mô tả đúng tập đã chạy.

## Phần còn giới hạn

Chưa có nhãn mưa giờ/radar đáng tin để nâng cấp mưa bằng quan trắc, chưa huấn luyện lại global 67 ô trên station labels, chưa đưa candidate mới vào app. Chưa đánh giá operational theo receipt/issue-vintage, nhiều seed hoặc uncertainty của model trạm. Chưa chạy GitHub runner/Docker runtime/thiết bị thật/signing. Các kết quả tốt chỉ áp dụng đúng nguồn, giai đoạn và trạm nêu trên; không quy đổi MAE/F1/coverage thành phần trăm độ chính xác chung.
