# Kế hoạch long-range v2.1: huấn luyện trên Google Colab

Ngày lập: 2026-10-31. Trạng thái: **code đã sẵn sàng, mô hình chưa được huấn luyện**. Chưa có số liệu đánh giá nào của v2.1.
Các con số trong tài liệu này là ước lượng tài nguyên hoặc kết quả smoke test, không phải kết quả mô hình.

## 1. Thay đổi so với v2 và lý do

v2.1 giữ nguyên bộ đặc trưng của v2 (dùng lại các hàm `long_range_model_v2`) và giữ nguyên giao thức ngoài:
train 2021-01-01..2024-06-30, validation 2024-07-08..2024-12-24, test 2025-01-01..2026-10-16, khoảng cách 168 giờ.
Thời điểm phát hành và thời điểm phát hành + 168h phải nằm trong cùng một tập. Không tệp nào của v2 bị sửa.

| # | Thay đổi | Vì sao |
|---|---|---|
| 0 | Chia validation làm hai vai trò, cách nhau 168h. **VAL_FIT** (2024-07-08..2024-10-06) dùng cho early stopping, chọn mode và chọn năm bắt đầu train. **VAL_CAL** (2024-10-14..2024-12-24) dùng cho taper, blend V3, hiệu chỉnh mưa, conformal và các cổng phục vụ. Dải giờ cố định B1=1–6, B2=7–24, B3=25–48, B4=49–72, B5=73–120, B6=121–168. `test_spec.json` được ghi trước khi chấm test và hash của nó nằm trong `metadata.json`. | v2 dùng một cửa sổ validation cho mọi lựa chọn nên kết quả bị lạc quan. Các bộ hiệu chỉnh cần dữ liệu mà boosters chưa early-stop trên đó. |
| 1 | Thêm baseline mạnh hơn: climatology nội suy, persistence, diurnal persistence y(t+h−24⌈h/24⌉), damped anomaly, diurnal-damped, cùng v1, v2 và V3. "Best baseline" là giá trị nhỏ nhất theo kiểu oracle trên test cho từng dải, nên nghiêng về phía có lợi cho baseline. CI 95 % dùng bootstrap khối 7 ngày, ghép cặp, B=1000, seed 42. Cờ `significant` bật khi cận trên CI < 0. | Persistence thô là đối thủ quá yếu. Chênh lệch 0,1261 so với 0,1265 không có ý nghĩa nếu thiếu CI. |
| 2 | Hiệu chỉnh xác suất mưa theo từng dải, chọn một trong none / Platt / isotonic bằng cross-fit 2 fold trên VAL_CAL (hai nửa liền nhau; bỏ các phát hành cách nửa kia < 168h để cửa sổ 168h không chồng nhãn, cùng cách chia cho chọn phương pháp khoảng). Tham số lưu dạng JSON (`calibration.json`), không dùng pickle. Chỉ phục vụ bản đã hiệu chỉnh khi Brier giảm ≥ 0,5 %. | ECE của v2 khoảng 0,03–0,037; ở 24–72h, p≈0,45 chỉ ứng với tần suất mưa thực tế ≈0,30. |
| 3 | Khoảng p10/p90 theo split-conformal chuẩn hoá. Thang đo là độ lệch chuẩn anomaly của tập train theo (ô, tháng × giờ). Riêng mưa (mm) chỉ có p90. Khoảng chỉ được phục vụ cho các cặp mục tiêu × dải có coverage cross-fit trong ±0,03. | v2 dự báo 7 ngày nhưng không cho biết độ bất định. |
| 4 | Đánh giá không gian: Côn Đảo là một fold riêng, 66 ô đất liền chia 5 khối bằng KMeans. Khi train mỗi fold, loại các ô cách ô bị giữ lại ≤ 0,12°. rho(h) và rho LOYO của fold chỉ tính trên các ô train của fold (dùng cho cả dòng train lẫn dòng đánh giá ô bị giữ lại); mỗi ô bị giữ lại vẫn dùng climatology train của chính nó. Stride và k lấy đúng giá trị hiệu lực của `final` (`metadata.json.sampling_args`). Số vòng boosting (best_iteration của mô hình cuối) và target mode được chọn trên **tất cả** các ô, kể cả ô bị giữ lại; điều này được ghi trong `spatial_folds.json`, `fold_meta.json` và `test_report.spatial`. | v2 chưa có holdout không gian. Lưới khoảng 8 km có tự tương quan mạnh. |
| 5 | Chỉ fit trọng số V3 trên VAL_CAL, lưới {0; 0,25; 0,5; 0,75; 1}. Một trọng số chỉ được giữ khi cận dưới 90 % của lợi ích bootstrap > 0, và phải thoả w(1) ≥ w(3) ≥ w(6). Hiệu chỉnh nối mượt từ 1 đến 9h. Phát hành ≤ 2025-09-23 23:00 thì không dùng V3 và ghi fallback `v3_knowledge_window`. Kết quả chính trên test chỉ tính các phát hành từ 2025-10-01. | Các cửa sổ của V3 phủ toàn bộ validation của v2. Trọng số chỉ đặt ở 1/3/6h làm đường dự báo bị nhảy. |
| 6 | `dev_selection.json` lưu toàn bộ bảng so sánh. `final` đọc tệp này thay vì gõ tay `--modes`. Ledger `test_ledger.jsonl` là toàn cục, chỉ ghi thêm và có chuỗi hash. Mục `started` được ghi **trước** khi đọc dữ liệu test, mục `completed` (kèm hash kết quả) khi xong; có `started` là đủ để chặn mọi lần chấm lại, và `final` cũng từ chối chạy khi ledger đã có mục v2.1. `test` còn từ chối nếu `test_report.json` hoặc `figures/` đã tồn tại. Ledger được khởi tạo với các lần v1, v2 và V3 đã dùng cửa sổ test. | Cơ chế "chấm test một lần" của v2 có thể bị lách bằng cách đổi `--out`. |
| 7 | rho(h) cho các dòng train cũng tính theo kiểu leave-one-year-out, khớp với climatology LOYO. | Để docstring "không đặc trưng nào chứa nhãn của chính nó" đúng theo nghĩa đen. |
| 8 | Booster ngắn phủ 1..36h. Việc chuyển sang booster dài dùng taper 3 tham số {w0, a, b}, chọn trên VAL_CAL, có phạt độ gồ ghề. | Mây ở 24→25h nhảy khoảng 10 lần so với các giờ lân cận. |
| 9 | Tuỳ chọn train từ 2017: chỉ nhận khi ≥ 4/6 mục tiêu tốt hơn trên VAL_FIT và không mục tiêu nào kém đi quá 0,5 %. Có kiểm tra dịch chuyển trung bình theo năm (z leave-one-year-out > 3). | Thêm năm dữ liệu giúp climatology, rho và std ổn định hơn, nhưng có thể dữ liệu đến từ phiên bản NWP khác. |
| 10 | `metadata.json` ghi phiên bản thư viện, sha của `pip freeze`, sha của code và dữ liệu, CLI và seed. Có 24 trường hợp parity và lệnh `--verify-artifacts` chạy trên laptop. | Việc train chuyển sang máy khác nên phải chứng minh được nguồn gốc của artifact. |

Giao diện phục vụ (`backend/long_range_model_v21.py`) là tập cha của v2: giữ nguyên các khoá cũ và thêm các khoá phẳng
`rain_probability_raw`, `*_p10`, `*_p90`, `precipitation_mm_p90`, cùng `interval_level`, `rain_calibration`,
`horizon_bands`, `components`. Router chỉ đổi sang v2.1 bằng một dòng import, sau khi verify đạt và team leader quyết định.

## 2. Các bước trên Colab

Chi tiết từng bước có trong `notebooks/colab_train_v21/README.md`. Tóm tắt:

1. Trên laptop, chạy `python scripts\export_colab_data.py --out D:\wether_app\colab_upload`. Lệnh chỉ đọc DB,
   xuất 67 tệp npz int16×10 (đã kiểm tra khôi phục được chính xác) cùng manifest sha256, rồi tạo `code.zip`.
2. Tải thư mục đó lên Drive và đổi tên thành `MyDrive/sky_weather_colab`.
3. Mở `train_long_range_v21_colab.ipynb` và chọn Run all. Notebook tự cài thư viện đúng phiên bản, chạy smoke test,
   rồi lần lượt `dev`, `final`, `spatial`, `test` (chấm một lần) và tạo tệp zip.
4. Trên laptop: kiểm tra sha256 của zip, giải nén vào `backend/models/long_range_v21/`, chạy `--verify-artifacts`,
   sau đó chạy pytest và ruff.

## 3. Thời gian và RAM dự kiến

| Giai đoạn | 2 vCPU Colab | RAM đỉnh (ước tính) |
|---|---|---|
| dev (3 mode × 2 loại booster + so sánh 2017) | 2–3 giờ | 6–10 GB (có bộ chặn 10 GiB; stride tự tăng nếu cần) |
| final, train từ 2021 | khoảng 1,5 giờ | khoảng 5–6 GB (v2 trên laptop: 36 phút, 4,85 GB với 4 luồng) |
| final, train từ 2017 | 2,5–3 giờ | khoảng 8–10 GB |
| spatial (6 fold) | khoảng 1 giờ | khoảng 5 GB |
| test | 15–30 phút | khoảng 4–6 GB |

Trên laptop, export mất **52 giây** và tạo ra 57,3 MB dữ liệu cùng `code.zip` 57,9 MB, tổng cộng 111 MB. Ngoài ra laptop chỉ
chạy verify, mất vài phút.

## 4. Kết quả kiểm tra hiện có (chỉ smoke, không phải kết quả mô hình)

- Đã chạy trọn chuỗi dev → final → spatial → test → verify trên 3 ô với stride rất thưa, trong thư mục tạm
  (đã xoá sau khi chạy). Parity giữa trainer và module phục vụ: sai lệch tối đa 9,0e-6 (ngưỡng 1e-4). Lần chấm test thứ
  hai bị ledger từ chối.
- Loader npz và loader SQLite cho ra DataFrame giống hệt nhau (cùng sha256 chuẩn hoá) trên 3 ô thật và trên DB tổng hợp.

## 5. Giới hạn cần nói thẳng

- Nhãn là dữ liệu mô hình Open-Meteo, không phải quan trắc. Mọi skill chỉ là skill mô phỏng.
- Cửa sổ test đã được v1, v2 và V3 dùng trước đây. "Chấm một lần" chỉ đúng trong phạm vi chương trình v2.1, và ledger ghi rõ điều này.
- VAL_FIT và VAL_CAL mỗi cửa sổ chỉ khoảng 9–10 tuần, chủ yếu rơi vào mùa mưa. Coverage và hiệu chỉnh trong mùa khô có thể lệch;
  kết quả theo mùa sẽ được báo cáo đúng như đo được.
- Blend V3 không bao giờ sạch hoàn toàn. Chỉ tập con phát hành từ 2025-10-01 (khoảng 12,5 tháng) là sạch.
- Cửa sổ val_select của V3 (2024-10-01..2025-09-23) chứa trọn VAL_CAL, nên skill của V3 trên VAL_CAL (và trọng số blend V3) hơi lạc quan. Ghi trong `serving_policy.json.diagnostics.v3_val_select_overlap` và LIMITATIONS.
- Bộ hiệu chỉnh mưa và lượng tử conformal được fit trên giá trị 1..9h đã blend V3, trong khi phát hành test ≤ 2025-09-23 phục vụ v2.1 một mình ở 1..9h. Vì vậy `test_report.calibration_intervals_by_v3_window` báo riêng Brier/ECE và coverage 1..9h cho hai cửa sổ.
- Conformal giả định tính hoán đổi, nhưng sai số lại tự tương quan, nên coverage chỉ là xấp xỉ. Độ phủ 80 % không có nghĩa là độ chính xác 80 %.
- Holdout không gian đo khả năng chuyển giao của booster. Một ô mới vẫn cần có lịch sử Open-Meteo.
- Từ ngày 4 trở đi, skill có thể chỉ ngang climatology. Nếu vậy sẽ ghi "không phân biệt được" thay vì "tốt hơn".

## 6. Điểm lệch so với SPEC

- `evaluation.json` giữ cấu trúc của v2 (khoá cấp cao nhất là tên mục tiêu), vì router hiện đang duyệt
  `report.items()`. Bảng theo dải nằm ở `evaluation.json[target].test.by_band[band]`, và bản đầy đủ
  `test.by_band[target][band]` nằm trong `test_report.json`. Các mục `baselines_extra`, `bootstrap_ci`,
  `calibration`, `intervals`, `spatial_holdout` được đặt trong từng mục tiêu.
- Dữ liệu xuất ra là npz thay vì parquet, vì laptop chưa cài pyarrow. `code.zip` do `export_colab_data.py` tạo
  (không dùng script tạm) để có thể dựng lại.
- Chọn phương pháp khoảng: mặc định dùng normalized. Chỉ đổi sang phương pháp khác nếu sai số coverage cross-fit giảm
  được hơn 1 điểm phần trăm.
- λ của phạt độ gồ ghề được đặt để độ gồ ghề ở mức điển hình (median J(10..48) của booster dài) tốn 0,2 % metric.
  Đây không phải giới hạn trên tuyệt đối.
- Hạng dưới của conformal là floor((n+1)·0,1), hạng trên là ceil((n+1)·0,9).
- Diurnal-damped dùng đúng rho(h) như SPEC, không dùng rho(24⌈h/24⌉).
- Các tiêu chí thành công (ECE ≤ 0,02, coverage ±0,05, J ≤ 1,5, ...) được tính và báo cáo trong
  `test_report.criteria`, chứ không được dùng để tinh chỉnh mô hình.

## 7. Checklist khi đổi router sang v2.1

- Đổi `import long_range_model_v2 as long_range_model` sang `long_range_model_v21` trong `main.py` và `routers/*.py`.
- Đồng thời sửa `tests/test_monitor.py` (và mọi test khác đang cô lập mô hình long-range bằng `LONG_RANGE_V2_MODEL_DIR`) để đặt `LONG_RANGE_V21_MODEL_DIR`; nếu không, test sẽ nạp artifact thật trong `models/long_range_v21` và kết quả phụ thuộc máy.
- `components.v3_model_version` chỉ khác `None` khi V3 thật sự được áp dụng; `components.v3_applied_targets` liệt kê mục tiêu.
