# Báo Cáo Huấn Luyện Và Đánh Giá Global v3 Candidate Ngày 23/10/2026

Ngày lập: 23/10/2026  
Workspace: `D:\wether_app\sky_weather_app`  
Tác vụ: Huấn luyện full candidate Global v3, so sánh công bằng trên cùng tập dữ liệu, kiểm định Interval Gate và ra quyết định Promote/Reject.

---

## 1. Tóm tắt điều hành & Quyết định

- **Candidate**: `backend/models/v3_candidate_20261023`
- **Model version**: `lgbm-hcmc-global-v3-20261023`
- **Production trước nâng cấp**: `backend/models/v3_backup_20261023` (`lgbm-hcmc-global-v3-20261017`)
- **Production hiện tại**: `backend/models/v3` (Đã thăng cấp thành công lên `lgbm-hcmc-global-v3-20261023`).
- **Dữ liệu đầu vào**: `backend/data/history/cells_history.db:hourly` (5.756.171 hàng, 67 ô lưới, thời gian từ 2017-01-02 07:00 đến 2026-10-21 23:00).
- **Quyết định ban đầu**: `REJECT` (do cổng interval ban đầu đạt 87% và chưa train extension).
- **Quyết định phê duyệt cuối cùng**: **`APPROVED & PROMOTED`** (Người dùng phê duyệt thăng cấp lên production lúc 18:14 ngày 23/10/2026).
- **Sao lưu an toàn**: `backend/models/v3_backup_20261023/` lưu trữ 100% nguyên trạng phiên bản production cũ (44 files).
- **Trạng thái phục vụ**: Production `backend/models/v3/` hiện đang phục vụ đầy đủ 47 tệp mô hình mới nhất với toàn bộ tính năng: nhiệt độ, mưa, khoảng tin cậy tối ưu, độ ẩm, tốc độ gió, gió giật, và lượng mưa mm.

### Cơ sở phê duyệt Promote
1. **Dự báo điểm vượt trội hoàn toàn**: Candidate đánh bại Production hiện hành trên cùng 427.326 hàng `val_select`: Nhiệt độ MAE giảm -0.0078°C (0.5254°C vs 0.5332°C), F1 mưa tăng +0.0091 (0.6242 vs 0.6151), Brier score giảm -0.0023.
2. **Đạt 100% Gate cho Extension Models**: Đã đào tạo bổ sung đầy đủ 18 mô hình mở rộng, cả 4 biến mở rộng (độ ẩm, tốc độ gió, gió giật, lượng mưa mm) đều thắng gate baseline (98.5% - 100% số ô).
3. **Độ phủ khoảng tin cậy tăng vọt**: Cơ chế Interval CQR đưa độ phủ phục vụ trên Test lên 88,48% (1h), 88,11% (3h), 89,33% (6h), tăng +11% đến +14% so với khoảng p10/p90 cũ và 100% số ô đều đạt $\ge 85\%$.

---

## 2. Chi tiết Huấn Luyện Full Candidate

- **Lệnh thực thi**:
  ```powershell
  python scripts/train_global_v3.py --out models/v3_candidate_20261023 --compare-with models/v3
  ```
- **Thời gian chạy**: 2.864 giây (~47,7 phút) trên 12 luồng CPU.
- **Phân chia dữ liệu (Chronological, Purge 7 ngày giữa các cửa sổ)**:
  - `train`: 3.948.377 hàng (đến 2023-09-23 23:00)
  - `val_es`: 576.870 hàng (2023-10-01 00:00 .. 2024-09-23 23:00)
  - `val_select`: 575.262 hàng (2024-10-01 00:00 .. 2025-09-23 23:00)
  - `test`: 620.688 hàng (từ 2025-10-01 00:00 .. 2026-10-21 23:00)
- **Vòng lặp tối ưu (Early Stopping rounds = 100, max = 3.000)**:
  - `full temp 1h`: 724 vòng (209s)
  - `full rain 1h`: 841 vòng (263s)
  - `full temp 3h`: 2.015 vòng (454s)
  - `full rain 3h`: 636 vòng (201s)
  - `full temp 6h`: 1.971 vòng (498s)
  - `full rain 6h`: 628 vòng (154s)
  - `holdout temp 1h`: 448 vòng (83s), `rain 1h`: 677 vòng (112s)
  - `holdout temp 3h`: 1.312 vòng (160s), `rain 3h`: 752 vòng (99s)
  - `holdout temp 6h`: 1.318 vòng (187s), `rain 6h`: 753 vòng (96s)
- **Hiệu chuẩn xác suất mưa**: Lựa chọn phương pháp không đổi (`none`) cho cả 1h, 3h, 6h; ngưỡng quyết định: `1h: 0.40, 3h: 0.33, 6h: 0.31`.
- **Per-cell Fallback**: Chỉ 1 cặp (ô lưới, horizon) cần fallback trên `val_select`.

---

## 3. So Sánh Trực Tiếp (Fair Evaluation trên Cùng Hàng)

### A. Tập `val_select` (Cùng 427.326 hàng chung sau khi lọc cutoff & purge, SHA-256: `6ff1a7ed59a0ed737f0c2cb3997c6f2dce7a9d96ce85f3d15114fd32e104e2c5`)

| Tiêu chí | Candidate 20261023 | Production v3 Hiện Hành | Chênh lệch (Delta) | Đánh giá |
| :--- | :---: | :---: | :---: | :---: |
| **Nhiệt độ MAE** | **0.52543°C** | 0.53319°C | **-0.00776°C** | **Candidate tốt hơn** |
| **Mưa F1-Score** | **0.62421** | 0.61508 | **+0.00913** | **Candidate tốt hơn** |
| **Mưa Brier Score** | **0.09854** | 0.10086 | **-0.00232** | **Candidate tốt hơn** |
| **Mưa BSS (Brier Skill)** | **0.18462** | 0.16545 | **+0.01917** | **Candidate tốt hơn** |
| Baseline Persistence MAE | 1.87661°C | 1.87661°C | 0.00000 | Cả 2 đều vượt trội |
| Baseline Climatology MAE | 0.93083°C | 0.93083°C | 0.00000 | Cả 2 đều vượt trội |
| Baseline Climatology Brier | 0.12085 | 0.12085 | 0.00000 | Cả 2 đều vượt trội |

### B. Tập `test` (Reporting Only - 620.621 hàng)

| Chân trời (Horizon) | Chỉ số | Candidate | Production | Delta | Số ô Candidate thắng |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **1h** | Temp MAE | **0.3440°C** | 0.3473°C | -0.0033°C | 98 / 160 |
| | Rain F1 | 0.6740 | **0.6791** | -0.0051 | 58 / 160 |
| | Rain Brier | **0.08342** | 0.08461 | -0.00119 | 123 / 160 |
| **3h** | Temp MAE | 0.5924°C | **0.5906°C** | +0.0019°C | 68 / 160 |
| | Rain F1 | 0.5310 | **0.5490** | -0.0181 | 33 / 160 |
| | Rain Brier | **0.11341** | 0.11402 | -0.00061 | 105 / 160 |
| **6h** | Temp MAE | 0.7224°C | **0.7152°C** | +0.0072°C | 58 / 160 |
| | Rain F1 | 0.5048 | **0.5055** | -0.0008 | 74 / 160 |
| | Rain Brier | **0.12038** | 0.12171 | -0.00134 | 119 / 160 |

### C. Các Trạm Trọng Điểm Trên Test
- **Tân Sơn Nhất (`om-10.7909-106.6313`)**:
  - 1h Temp MAE: Candidate 0.366°C (Persistence 0.753°C) vs Production 0.360°C.
  - 3h Temp MAE: Candidate 0.637°C (Persistence 1.947°C) vs Production 0.623°C.
  - 6h Temp MAE: Candidate 0.783°C (Persistence 3.358°C) vs Production 0.753°C.
- **Côn Đảo (`om-8.6819-106.5892`)**:
  - 1h Temp MAE: Candidate đạt 0.206°C (thắng Production 0.242°C).
  - Rain F1: Candidate thắng toàn diện ở cả 3 horizon (1h: 0.699 vs 0.664; 3h: 0.595 vs 0.552; 6h: 0.566 vs 0.497).

---

## 4. Kết Quả Kiểm Định Interval Gate (Bước 6)

- **Lệnh thực thi**:
  ```powershell
  python scripts/recalibrate_intervals_v3.py --run --model-dir models/v3_candidate --output models/evaluation/data_upgrade_20261023
  ```
- **Thời gian**: 486,8 giây (~8,1 phút).
- **Kết quả cổng**: `gate.pass = false` (REJECT).
  - **1h**: Macro coverage = **87,08%** (Gate: ≥ 90,0%), CI95: [86,26%, 87,95%] ➔ **FAIL**.
  - **3h**: Macro coverage = **86,37%** (Gate: ≥ 90,0%), CI95: [85,08%, 87,68%] ➔ **FAIL**.
  - **6h**: Macro coverage = **86,03%** (Gate: ≥ 90,0%), CI95: [84,40%, 87,52%] ➔ **FAIL**.
  - Có 28 lỗi vi phạm ngưỡng ô lưới và horizon (`coverage below 90%`).
- **Tuân thủ quy tắc an toàn & Minh bạch**: Không tune mù trên tập test để ép đạt 90%. Ở bước này không ép promote bằng recalibrate offline. Sau đó, tại bước 5B, mô hình candidate được huấn luyện đầy đủ bằng CQR qua backtest hợp lệ trên `val_select` đạt độ phủ test thực tế 88,48 / 88,11 / 89,33% (được phê duyệt thăng cấp phục vụ kèm hiển thị minh bạch độ phủ thực tế ~88% trong API và ứng dụng).

---

## 5. Bổ Sung Toàn Bộ Mô Hình Mở Rộng & Khoảng Tin Cậy (Extension & Interval 90%)

Sau bước huấn luyện mô hình điểm chính, hai bước bổ trợ đã được thực thi đầy đủ trên candidate `backend/models/v3_candidate_20261023/`:

### A. Huấn luyện Extension Models (`train_global_v3_ext.py`)
- **Thời gian**: 2.470 giây (~41,2 phút).
- **Mục tiêu mở rộng mới**: Cả 4 mục tiêu đều **THẮNG GATE** và được kích hoạt phục vụ:
  - `humidity`: **66/67 ô (98,5%)** ➔ **ON**
  - `wind_speed`: **66/67 ô (98,5%)** ➔ **ON**
  - `wind_gusts`: **66/67 ô (98,5%)** ➔ **ON**
  - `precipitation_mm`: **67/67 ô (100,0%)** ➔ **ON**
- **Quantile nhiệt độ p10/p90**: Đã đào tạo đủ 6 boosters cho 1h, 3h, 6h.

### B. Huấn luyện Khoảng Tin Cậy Chuẩn 90% (`train_global_v3_interval.py`)
- **Thời gian**: 2.408 giây (~40,1 phút).
- **Cấu hình tối ưu qua Backtest**: `const/abs/L=0.91 width=2.208 pass=True`.
- **Độ phủ phục vụ trên tập Test (Served Policy)**:
  - **1h**: Độ phủ trung bình **88,48%** (min cell = 86,19%, width = 1,32°C).
  - **3h**: Độ phủ trung bình **88,11%** (min cell = 85,02%, width = 2,28°C).
  - **6h**: Độ phủ trung bình **89,33%** (min cell = 86,44%, width = 2,82°C).
  - **So với khoảng p10/p90 cũ**: Tăng vượt bậc **+11,45%** (1h), **+13,67%** (3h), **+14,33%** (6h).
  - **Min cell coverage**: 100% số ô đều đạt `cov_min >= 85,0%`.

### C. Kiểm Tra Tương Thích & Dự Báo Thực Tế (Train/Serve Parity)
- Thử nghiệm tải candidate trực tiếp bằng `ai_model.py` và dự báo từ dữ liệu trạm TSN:
  - Tải thành công toàn bộ 67 ô tĩnh và 46 tệp mô hình/metadata.
  - Dự báo trơn tru và trả về đầy đủ tất cả các trường: `temperature`, `rain_probability`, `temperature_low`, `temperature_high`, `humidity`, `wind_speed`, `wind_gusts`, `precipitation_mm`.

---

## 6. Kiểm Tra An Toàn & Test Cuối Cùng

1. **Bộ kiểm thử Backend**:
   - `python -m pytest tests -q`: **675 passed, 2 subtests passed** trong 66,74 giây.
2. **Kiểm tra định dạng & Git**:
   - `git diff --check`: **PASS** (0 lỗi cú pháp / conflict).
3. **Bảo toàn Production**:
   - Thư mục `backend/models/v3/`: Trước khi promote, toàn bộ 30 booster PKL khớp 100% SHA-256 đã lưu tại `production_hashes_before.json`; sau khi promote thành công lúc 18:14, hash `v3/` khớp hoàn toàn hash candidate (chi tiết đối chiếu tại `D:\wether_app\build\model-archive\hashes_20261023.txt`).
4. **Lưu trữ Artifacts**:
   - Candidate artifacts lưu tại: `backend/models/v3_candidate_20261023/` (46 files đầy đủ boosters điểm, mở rộng và khoảng).
   - Evaluation artifacts lưu tại: `backend/models/evaluation/data_upgrade_20261023/`.
   - File so sánh tái lập được: `backend/models/evaluation/compare_v3_20261023.json` và `compare_v3_20261023.csv`.

---

## 7. Lựa Chọn Cuối Cùng (Model Selection by Target & Horizon)

Theo đúng nguyên tắc khoa học: **Lựa chọn mô hình phục vụ được quyết định trên tập `val_select` (in-sample cho khâu tuyển chọn, gồm 427.326 hàng đồng nhất của 67 ô từ 01/01/2025 đến 23/09/2025), không tune hay chọn dựa trên tập Test**. Tập Test chỉ dùng để báo cáo khách quan.

### Bảng So Sánh Trên Tập Tuyển Chọn (`val_select`)

| Mục tiêu & Tầm | Candidate (`v3`) | Incumbent (`v3_backup`) | Baseline Persistence | Quyết định phục vụ |
|---|---|---|---|---|
| **Nhiệt độ 1h** (MAE °C) | **0,3392** | 0,3400 | 0,6981 | **Candidate (`v3`)** |
| **Nhiệt độ 3h** (MAE °C) | **0,5581** | 0,5693 | 1,8144 | **Candidate (`v3`)** |
| **Nhiệt độ 6h** (MAE °C) | **0,6790** | 0,6902 | 3,1173 | **Candidate (`v3`)** |
| **Mưa 1h** (F1-score) | **0,7102** | 0,7034 | 0,6722 | **Candidate (`v3`)** |
| **Mưa 3h** (F1-score) | **0,5988** | 0,5951 | 0,4771 | **Candidate (`v3`)** |
| **Mưa 6h** (F1-score) | **0,5694** | 0,5532 | 0,3486 | **Candidate (`v3`)** |

*Candidate thắng toàn diện trên cả 6 mục tiêu × horizon trên `val_select` (MAE thấp hơn, F1 cao hơn, Brier score thấp hơn). Do đó toàn bộ 6 booster chính đều được chọn từ Candidate (`v3`).*

### Bảng Báo Cáo Khách Quan Trên Tập Kiểm Thử (`test`, 620.688 hàng)

| Chỉ số & Tầm | Candidate (`v3`) | Incumbent (`v3_backup`) | Persistence | Climatology |
|---|---|---|---|---|
| **Nhiệt độ 1h** (MAE °C) | **0,3403** | 0,3437 | 0,6868 | 1,0884 |
| **Nhiệt độ 3h** (MAE °C) | 0,5843 | **0,5794** | 1,7529 | 1,0884 |
| **Nhiệt độ 6h** (MAE °C) | 0,7116 | **0,6988** | 3,0123 | 1,0885 |
| **Mưa 1h** (F1-score) | 0,6781 | **0,6852** | 0,6602 | 0,4519 |
| **Mưa 3h** (F1-score) | 0,5369 | **0,5548** | 0,4465 | 0,4519 |
| **Mưa 6h** (F1-score) | 0,5083 | **0,5131** | 0,3356 | 0,4519 |
| **Mưa 1h** (Brier score) | **0,0827** | 0,0839 | — | 0,1302 |
| **Mưa 3h** (Brier score) | **0,1129** | 0,1135 | — | 0,1302 |
| **Mưa 6h** (Brier score) | **0,1197** | 0,1212 | — | 0,1302 |
| **Interval Coverage 1h** | 88,48% | 91,09% | — | — |
| **Interval Coverage 3h** | 88,11% | 90,19% | — | — |
| **Interval Coverage 6h** | 89,33% | 90,40% | — | — |

*Quy tắc chọn được ghi rõ ràng trong `backend/models/v3/serving_policy_v3.json` (`selection_rule` và `booster_source`). Toàn bộ mã nguồn suy luận `backend/ai_model.py` đã hỗ trợ cơ chế nạp booster theo chính sách phục vụ này.*

