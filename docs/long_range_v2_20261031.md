# Mô hình dự báo dài hạn v2 (1–168 giờ), ngày 31/10/2026

## Tóm tắt

- v2 tốt hơn v1 trên tập kiểm định (validation) ở cả 6 mục tiêu, rõ nhất ở
  1–24 giờ. Trên tập test (chạy đúng một lần), v2 tốt hơn v1 ở nhiệt độ, độ
  ẩm, gió, mây, nhưng **lượng mưa (RMSE) kém v1 một chút** (0,9394 so với
  0,9349 mm/giờ); xác suất mưa gần như ngang v1 (Brier 0,1261 so với 0,1265).
  Tính theo MAE, lượng mưa của v2 kém v1 trên cả validation (0,531 so với
  0,516) và test (0,356 so với 0,337); v2 chỉ thắng lượng mưa theo RMSE trên
  validation.
- Ở 1/3/6 giờ, chính sách phục vụ trộn v2 với mô hình ngắn hạn V3. Với nhiệt
  độ, độ ẩm và gió, bản trộn tốt hơn cả v2 và V3 khi đứng riêng. Không phải
  mọi chỗ: xác suất mưa ở 3 giờ dùng 100% V3 (ngang V3), còn lượng mưa ở 6 giờ
  dùng v2 trong khi V3 đứng riêng nhỉnh hơn một chút trên test.
- Từ ngày thứ 4 trở đi, kỹ năng chỉ nhỉnh hơn khí hậu một chút. Với gió và
  xác suất mưa ở ngày 4–7, nên xem dự báo là xu hướng, không phải dự báo
  chính xác.
- Đã nối vào ứng dụng ngày 31/10/2026: `main.py`, `routers/monitor.py`,
  `weather_endpoints.py`, `weather_map.py`, `weather_series.py` dùng
  `import long_range_model_v2 as long_range_model` (giao diện giữ nguyên).
  Muốn quay về v1 chỉ cần đổi lại dòng import.
- Ở mốc 24→25 giờ, đường dự báo có bước nhảy nhỏ do chuyển từ booster ngắn hạn
  sang booster dài hạn (rõ nhất với mây). Đây là hạn chế đã biết.

## Dữ liệu và cách chia

- Nguồn: `backend/data/history/cells_history.db`, 67 ô lưới, mở chế độ chỉ đọc.
  Từ 2021 trở đi không có giờ thiếu, không có giá trị rỗng, không trùng lặp.
- Nhãn là đầu ra mô hình Open-Meteo, không phải số đo trạm.
- Chia giống v1: train 2021-01-01..2024-06-30, validation 2024-07-08..2024-12-24,
  test 2025-01-01..2026-10-16. Thời điểm phát và thời điểm phát + 168 giờ đều
  nằm trong cùng một tập.
- Mọi lựa chọn (kiểu mục tiêu, trọng số trộn, early stopping) chỉ dùng
  validation. Test được chấm đúng một lần bằng artifact đã lưu
  (`--phase test`), script từ chối chấm lần thứ hai.

## Mô hình

- Đầu vào: chỉ 48 giờ gần nhất của ô (nhiệt độ, độ ẩm, mưa, gió, mây, áp suất),
  gồm giá trị hiện tại, độ trễ 1/2/3/6/12/24 giờ, xu hướng 3 và 24 giờ, trung
  bình 6 và 24 giờ, độ lệch chuẩn 24 giờ, số giờ mưa trong 24 giờ.
- Khí hậu tháng × giờ của từng ô, chỉ tính từ giai đoạn train, nội suy giữa các
  tháng. Hàng train dùng khí hậu bỏ ra năm của thời điểm cần dự báo, để đặc
  trưng không chứa chính nhãn.
- Mỗi mục tiêu có hai booster LightGBM dạng văn bản: một cho 1–168 giờ, một
  cho 1–24 giờ. Booster học phần dư so với một giá trị nền được chọn trên
  validation: thô (như v1), độ lệch so với khí hậu, hoặc khí hậu cộng độ lệch
  hiện tại nhân hệ số tắt dần ρ(h).
- Chính sách (`serving_policy.json`), chọn trên validation:
  1. Ở 1–24 giờ: trọng số giữa booster ngắn và dài cho từng giờ.
  2. Ở 1/3/6 giờ: trọng số với V3, chỉ giữ khi tốt hơn ít nhất 1%. Mây không
     có trong V3. Gió ở 6 giờ và lượng mưa ở 6 giờ không đạt ngưỡng 1% nên
     dùng v2.
- Dữ liệu huấn luyện: 2,72 triệu hàng (1–168 giờ) và 4,08 triệu hàng (1–24 giờ),
  so với 45 nghìn hàng của v1.

## Kết quả validation (cùng hàng cho mọi mô hình)

Mỗi giờ dự báo có 20.167 hàng (67 ô × 301 lần phát, mỗi 13 giờ một lần), so
với 67 hàng của v1. Số liệu là MAE (nhiệt độ °C, độ ẩm %, gió km/h, mây %),
RMSE (mưa mm/giờ), Brier (xác suất mưa). "v2" là bản phục vụ (đã trộn).

| Mục tiêu | Mô hình | 1h | 3h | 6h | 12h | 24h | 48h | 72h | 120h | 168h | Tổng |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Nhiệt độ | v2 | 0,341 | 0,513 | 0,647 | 0,699 | 0,702 | 0,768 | 0,810 | 0,866 | 0,877 | 0,812 |
| | v1 | 0,699 | 0,716 | 0,752 | 0,770 | 0,787 | 0,817 | 0,851 | 0,898 | 0,925 | 0,857 |
| | V3 | 0,342 | 0,519 | 0,664 | | | | | | | |
| | Bền vững | 0,594 | 1,503 | 2,603 | 3,344 | 0,798 | 0,911 | 1,008 | 1,089 | 1,141 | 2,489 |
| | Khí hậu | 0,890 | 0,899 | 0,907 | 0,907 | 0,903 | 0,883 | 0,883 | 0,916 | 0,931 | 0,904 |
| Độ ẩm | v2 | 1,73 | 2,71 | 3,37 | 3,59 | 3,64 | 4,01 | 4,25 | 4,53 | 4,47 | 4,20 |
| | v1 | 3,53 | 3,79 | 3,94 | 3,87 | 4,00 | 4,23 | 4,47 | 4,73 | 4,66 | 4,42 |
| | V3 | 1,74 | 2,74 | 3,40 | | | | | | | |
| | Khí hậu | 4,66 | 4,83 | 4,80 | 4,74 | 4,73 | 4,62 | 4,70 | 4,88 | 4,79 | 4,76 |
| Lượng mưa | v2 | 1,066 | 1,275 | 1,212 | 1,084 | 1,233 | 1,193 | 1,305 | 1,300 | 1,084 | 1,224 |
| | v1 | 1,163 | 1,313 | 1,227 | 1,084 | 1,251 | 1,200 | 1,323 | 1,302 | 1,091 | 1,230 |
| | V3 | 1,069 | 1,276 | 1,221 | | | | | | | |
| | Khí hậu | 1,185 | 1,328 | 1,237 | 1,104 | 1,240 | 1,200 | 1,310 | 1,303 | 1,093 | 1,234 |
| Gió | v2 | 1,52 | 2,15 | 2,36 | 2,49 | 2,60 | 2,94 | 3,09 | 3,20 | 3,18 | 2,99 |
| | v1 | 2,50 | 2,65 | 2,63 | 2,76 | 2,84 | 3,04 | 3,21 | 3,34 | 3,27 | 3,13 |
| | V3 | 1,53 | 2,18 | 2,38 | | | | | | | |
| | Khí hậu | 3,17 | 3,17 | 3,10 | 3,16 | 3,18 | 3,16 | 3,17 | 3,18 | 3,12 | 3,16 |
| Mây | v2 | 7,53 | 9,50 | 10,87 | 12,27 | 11,68 | 12,83 | 12,03 | 11,81 | 13,38 | 12,41 |
| | v1 | 11,23 | 10,69 | 11,66 | 12,47 | 11,81 | 12,80 | 11,92 | 11,79 | 13,29 | 12,46 |
| | Bền vững | 7,79 | 11,67 | 13,72 | 17,19 | 16,12 | 18,98 | 17,44 | 16,99 | 18,46 | 17,82 |
| Xác suất mưa | v2 | 0,100 | 0,135 | 0,153 | 0,148 | 0,148 | 0,152 | 0,165 | 0,166 | 0,150 | 0,157 |
| | v1 | 0,148 | 0,164 | 0,166 | 0,152 | 0,152 | 0,154 | 0,166 | 0,169 | 0,151 | 0,159 |
| | V3 | 0,101 | 0,135 | 0,155 | | | | | | | |
| | Khí hậu | 0,156 | 0,173 | 0,173 | 0,158 | 0,157 | 0,154 | 0,167 | 0,168 | 0,152 | 0,161 |

Nhận xét:
- Mây từ 48 giờ trở đi: v2 kém v1 một chút (ví dụ 12,83 so với 12,80 ở 48h).
- Khí hậu ở bảng này được tính theo tháng × giờ của train, giống v1.

## Tầm dự báo hữu ích (validation)

"Giờ cuối thắng" là giờ cuối cùng mà v2 thắng cả bền vững lẫn khí hậu. Vì có
những giờ ở giữa không thắng, bảng ghi thêm giờ đầu tiên thua và số giờ thắng.

| Mục tiêu | Giờ cuối thắng | Giờ đầu tiên thua | Số giờ thắng /168 |
|---|---|---|---|
| Nhiệt độ | 168 | không có | 168 |
| Độ ẩm | 168 | không có | 168 |
| Lượng mưa | 168 | 37 | 149 |
| Gió | 164 | 100 | 124 |
| Mây | 168 | không có | 168 |
| Xác suất mưa | 168 | 130 | 165 |

## Kết quả test (chấm một lần)

Mỗi giờ dự báo có 45.292 hàng (67 ô × 676 lần phát, mỗi 23 giờ một lần).

| Mục tiêu | Mô hình | 1h | 3h | 6h | 24h | 72h | 168h | Tổng |
|---|---|---|---|---|---|---|---|---|
| Nhiệt độ | v2 | 0,335 | 0,553 | 0,663 | 0,762 | 0,874 | 0,937 | 0,890 |
| | v1 | 0,788 | 0,793 | 0,817 | 0,885 | 0,941 | 0,981 | 0,949 |
| | Khí hậu | 0,997 | 0,985 | 0,990 | 0,998 | 0,986 | 1,012 | 0,999 |
| Độ ẩm | v2 | 2,03 | 3,40 | 4,27 | 4,66 | 5,48 | 5,96 | 5,57 |
| | v1 | 4,64 | 4,60 | 4,98 | 5,19 | 5,56 | 6,00 | 5,73 |
| Lượng mưa | v2 | 0,803 | 1,033 | 0,845 | 0,872 | 1,056 | 0,932 | 0,939 |
| | v1 | 0,875 | 1,045 | 0,840 | 0,879 | 1,050 | 0,928 | **0,935** |
| Gió | v2 | 1,58 | 2,31 | 2,64 | 2,79 | 3,21 | 3,36 | 3,15 |
| | v1 | 2,60 | 2,73 | 2,86 | 2,95 | 3,25 | 3,38 | 3,22 |
| | Khí hậu | 3,30 | 3,33 | 3,35 | 3,30 | 3,32 | 3,37 | 3,32 |
| Mây | v2 | 11,57 | 17,39 | 18,01 | 21,01 | 22,93 | 22,01 | 21,50 |
| | v1 | 19,56 | 21,13 | 20,39 | 21,18 | 23,04 | 22,78 | 22,04 |
| | Bền vững | **11,30** | 18,19 | 20,34 | 24,56 | 27,68 | 27,21 | 26,69 |
| Xác suất mưa | v2 | 0,083 | 0,109 | 0,112 | 0,125 | 0,122 | 0,123 | 0,126 |
| | v1 | 0,124 | 0,119 | 0,115 | 0,126 | **0,121** | **0,122** | 0,127 |
| | Khí hậu | 0,130 | 0,123 | 0,121 | 0,130 | 0,123 | **0,122** | 0,128 |

- Tầm hữu ích trên test: nhiệt độ và độ ẩm thắng cả 168/168 giờ; gió 158 giờ
  (thua đầu tiên ở 126h); mưa 131 giờ (thua đầu tiên ở 34h); mây 167 giờ
  (thua bền vững ở 1h); xác suất mưa chỉ 97 giờ (thua đầu tiên ở 60h).
- Tỷ lệ Brier của v2 so với khí hậu theo ngày: ngày 1 là 0,935, ngày 4 là 1,000,
  ngày 7 là 1,007, tức là không còn kỹ năng từ ngày 4.
- So với V3 trên test ở 1/3/6 giờ, nhiệt độ (MAE): bản trộn 0,335/0,553/0,663,
  V3 0,337/0,563/0,683. Chỉ tính phần test từ 01/10/2025 (V3 chưa dùng giai
  đoạn này để chọn mô hình): 0,330/0,554/0,685 so với 0,332/0,568/0,704.
- Ô TSN (om-10.7909-106.6313), test: nhiệt độ MAE 0,976 (v1 1,032); gió 2,72
  (v1 **2,65**, v2 kém hơn ở ô này).

## Tài nguyên

- Huấn luyện và validation (`--phase final`): 2.148 giây, RSS đỉnh 4.852 MiB,
  4 luồng. Chấm test (`--phase test`): 445 giây, RSS đỉnh 5.377 MiB.
- Kiểm tra khớp phục vụ: 24 lần phát validation, nạp lại artifact và chạy
  `forecast_arrays` (gọi V3 thật), sai lệch tối đa 8,5e-6 (theo `metadata.json`).
- Phục vụ: khoảng 0,19 giây mỗi ô khi đã nạp (gồm cả gọi V3), lần đầu khoảng
  0,9 giây.

## Điều kiện phục vụ

- Cần 48 giờ liên tục của ô (`MIN_HISTORY_HOURS = 48`, giống v1).
- Ở 1/3/6 giờ, v2 gọi `ai_model.predict_for_location`, nên cần thêm các cột
  đầu vào của V3 (điểm sương, nhiệt độ cảm nhận, mã thời tiết, áp suất bề mặt,
  gió giật, hướng gió) và thư mục `models/v3`. Nếu V3 lỗi, v2 tự dùng giá trị
  của chính nó và ghi lý do vào `policy_fallbacks`.
- Không dùng dữ liệu tổng hợp toàn vùng, vì router chỉ truyền lịch sử của một ô.
- Từ chối các lần phát trước hoặc bằng `trained_through` (2024-12-24 23:00 +07),
  vì nhãn validation đã được dùng để chọn mô hình.

## Rủi ro và giới hạn

- Validation vừa dùng cho early stopping vừa dùng để chọn chính sách, nên số
  liệu validation hơi lạc quan. Test mới là số liệu khách quan.
- V3 đã dùng 2023-10..2025-09 cho early stopping và chọn mô hình, nên phần V3
  trong validation và trong test trước 10/2025 hơi có lợi. Bảng V3 "sạch" ở
  trên giúp kiểm tra điều này.
- Early stopping dừng sớm (60–350 vòng), cho thấy có khác biệt giữa giai đoạn
  train và validation. Thêm dữ liệu 2017–2020 có thể giúp, nhưng chưa thử để
  giữ cách chia giống v1.
- Xác suất mưa chưa hiệu chỉnh. Brier không phải phần trăm độ chính xác.
- Không có kiểm tra giữ lại theo không gian; chỉ phục vụ 67 ô đã huấn luyện.

## Tệp

- `backend/long_range_model_v2.py`: mô-đun phục vụ.
- `backend/scripts/train_long_range_v2.py`: huấn luyện, có ba pha dev, final, test.
- `backend/models/long_range_v2/`: 12 booster `.txt`, `metadata.json`,
  `evaluation.json`, `serving_policy.json`, `climatology.json`.
- `backend/tests/test_long_range_model_v2.py`: 7 kiểm thử với dữ liệu tổng hợp.
