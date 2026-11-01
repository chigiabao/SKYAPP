# Nhật ký thực hiện nâng cấp toàn diện ≥ 9/10 (23/10/2026)

- Ngày: 23/10/2026
- Workspace: `D:\wether_app\sky_weather_app`
- Mục tiêu: Nâng các hạng mục Flutter, Backend, AI/ML, Bảo mật, Repo hygiene lên ≥ 9/10 theo tài liệu hướng dẫn.

## Mốc ban đầu (Baseline)
- Backend tests: `675 passed, 2 subtests passed in 116.31s`
- Backend ruff: cài đặt `requirements-dev.txt` (ruff 0.17.2, pytest-cov 7.1.0, coverage 7.17.0). Phát hiện 1 lỗi ruff F401 trong `backend/models/evaluation/data_upgrade_20261023/compare_models.py`.
- Flutter analyze: `No issues found! (ran in 8.3s)`
- Flutter tests: `749 passed, 7 skipped (All tests passed! in 01:14)`

---

## Bước 1 — Dọn thư mục model trùng (Repo hygiene)
- Đã tính và lưu SHA-256 của 184 file trong 4 thư mục (`v3`, `v3_candidate`, `v3_candidate_20261023`, `v3_backup_20261023`) vào `D:\wether_app\build\model-archive\hashes_20261023.txt`.
- Đã di chuyển các thư mục ra `D:\wether_app\build\model-archive\`:
  + `backend/models/v3_candidate`
  + `backend/models/v3_candidate_20261023`
  + `backend/models/v3_backup_20261023`
  + `backend/models/station_temperature_candidate_20261022`
- Đã cập nhật `.gitignore` với pattern `backend/models/v3_*/`, `!backend/models/v3/`, `backend/models/*_candidate*/`, `backend/models/*_backup*/`.
- Đã đổi default `--model-dir` trong `backend/scripts/recalibrate_intervals_v3.py` từ `models/v3_candidate` thành `models/v3`.
- Đã sửa import thừa `numpy` trong `backend/models/evaluation/data_upgrade_20261023/compare_models.py` (ruff sạch: `All checks passed!`).
- Dung lượng `backend/models`: giảm từ ~540 MB xuống 153.66 MB (giảm 386.5 MB).
- Kết quả test: `675 passed, 2 subtests passed in 68.19s`.

---

## Bước 2 — Sửa vấn đề interval của AI v3 (AI/ML)
- Đã chạy hiệu chỉnh lại interval:
  `python scripts/recalibrate_intervals_v3.py --run --model-dir models/v3 --output models/evaluation/interval_recal_20261023`
- Kết quả cổng (Gate): `gate.pass = false` (Macro coverage 1h: 87,08%, 3h: 86,37%, 6h: 86,03%, dưới mục tiêu 90%).
- Tuân thủ nguyên tắc trung thực khoa học (Quyết định 2b):
  + Không ép tune tham số trên tập test.
  + Thêm trường `achieved_coverage` vào `backend/models/v3/extension_v3.json` (`1h: 0.8848, 3h: 0.8811, 6h: 0.8933`, copy từ `extension_v3.json` mục `interval.test`).
  + Cập nhật `backend/ai_model.py`: hàm `_interval_v3` trả về coverage đạt được từ `achieved_coverage`, và `_uncertainty_note` hiển thị đúng mức đạt được ("khoảng ~88%" cho 1h/3h, "~89%" cho 6h) thay vì hard-code "khoảng tin cậy 90%".
  + Cập nhật Flutter UI: `intervalLevelLabel` và `AIIntervalNote` đã xử lý động theo coverage thực tế.
- Cập nhật và bổ sung test `test_interval_achieved_coverage_honesty` trong `backend/tests/test_ai_global.py`.
  + Đồng bộ số liệu thực tế trong `README.md:322` và sửa mâu thuẫn trong `docs/retrain_global_v3_20261023.md`.
- Kết quả test backend: `676 passed, 2 subtests passed in 83.66s`, ruff sạch: `All checks passed!`.

---

## Bước 3 — So sánh công bằng và chọn model theo từng mục tiêu (AI/ML)
- Đã viết script tái lập được: `backend/scripts/compare_v3_versions.py` so sánh `backend/models/v3` với `D:/wether_app/build/model-archive/v3_backup_20261023` trên cùng 427.326 hàng `val_select` và 620.688 hàng `test` sạch.
- Đã xuất file:
  + `backend/models/evaluation/compare_v3_20261023.json`
  + `backend/models/evaluation/compare_v3_20261023.csv`
- Quy tắc chọn: Dựa trên `val_select` (không chọn theo test). Trên `val_select`, Candidate (`v3`) thắng toàn diện trên mọi mục tiêu × horizon:
  + Temp MAE: 1h: 0,3392 vs 0,3400; 3h: 0,5581 vs 0,5693; 6h: 0,6790 vs 0,6902 (Candidate thắng cả 3).
  + Rain F1: 1h: 0,7102 vs 0,7034; 3h: 0,5988 vs 0,5951; 6h: 0,5694 vs 0,5532 (Candidate thắng cả 3).
- Cập nhật `selection_rule` và `booster_source` vào `backend/models/v3/serving_policy_v3.json`.
- Cập nhật `_load_v3()` trong `backend/ai_model.py` để hỗ trợ nạp booster theo `booster_source` của policy.
- Bổ sung test `test_serving_policy_selection_rule_and_booster_source` trong `backend/tests/test_ai_policy.py`.
- Ghi mục "7. Lựa Chọn Cuối Cùng" kèm 2 bảng kết quả (`val_select` và `test` có baseline) vào `docs/retrain_global_v3_20261023.md`.
- Kết quả test backend: `677 passed, 2 subtests passed in 76.99s`, ruff sạch: `All checks passed!`.

---

## Bước 4 — Bảo mật và rate limit (Bảo mật, Backend)
- **Bật rate limit mặc định**: `backend/main.py:234` đổi default `RATE_LIMIT_PER_MINUTE` từ `0` thành `120`. Cho phép tắt bằng `RATE_LIMIT_PER_MINUTE=0`. Đã cập nhật `backend/.env.example` và `docs/deploy.md`. Thêm `os.environ["RATE_LIMIT_PER_MINUTE"] = "0"` vào `backend/tests/conftest.py`.
- **Hàm lấy IP duy nhất chuẩn hóa**:
  + Thêm `client_ip_from_scope(scope, trust_proxy)` và `client_ip_from_request(request, trust_proxy)` vào `backend/rate_limit.py`.
  + Khi `TRUST_PROXY=1`, lấy hop ngoài cùng bên phải của `X-Forwarded-For` (hop do reverse proxy tin cậy append, ngăn chặn client giả mạo hop đầu).
  + Thay `request.client.host` bằng `client_ip_from_request(request)` trong `backend/routers/feedback.py:37` và `backend/routers/auth.py:212`.
- **Chống dò email & spam ở đăng ký**:
  + Giữ nguyên mã lỗi 409 cho tài khoản trùng (để bảo toàn tương thích hợp đồng API và Flutter client), nhưng thêm rate limit chặt chẽ 5 lần/giờ/IP cho `/auth/register` (trả về 429 nếu vượt ngưỡng).
  + Tạo bảng `registration_attempts (ip_hash TEXT, attempted_at INTEGER)` trong `backend/database.py` và tự động dọn sau 1 giờ trong `purge_expired` (giữ sạch ngữ nghĩa bảng `login_attempts`).
- **Bổ sung 3 bài test bảo mật mới** trong `backend/tests/test_security_hardening.py`:
  + `test_trusted_proxy_identifies_rightmost_hop_and_isolates_sources`: Cô lập nguồn khi đi qua reverse proxy tin cậy và nhận diện đúng hop cuối.
  + `test_untrusted_proxy_ignores_spoofed_x_forwarded_for`: Bỏ qua header giả mạo khi `TRUST_PROXY` tắt.
  + `test_register_rate_limited_per_ip`: Kiểm tra chặn 429 sau 5 lần đăng ký từ cùng 1 IP trong 1 giờ.
- **Kết quả test backend**: `680 passed, 2 subtests passed in 67.81s`, ruff sạch: `All checks passed!`.

---

## Bước 5 — Bỏ re-export nội bộ ở router (Backend, kiến trúc)
- **Chuẩn hoá resolve_location**: Đổi `_resolve_location` thành `resolve_location` trong `backend/routers/weather_core.py` (giữ alias `_resolve_location`). Chuyển `backend/routers/feedback.py` sang import trực tiếp `from routers.weather_core import resolve_location`.
- **Loại bỏ import _tên xuyên module trong `routers/`**:
  + Trong `backend/routers/route.py`: chuyển sang import trực tiếp `_floor_hour, _latest_observed, _naive, _num` từ `weather_core`, `_SEVERITY` từ `weather_daily`, và `_series` từ `weather_series`.
  + Trong `backend/routers/monitor.py`: import `_replay_ai_rain` trực tiếp từ `routers.weather_map`.
  + Trong `backend/main.py`: import trực tiếp `weather_climatology` và `ai_model`, gọi `weather_climatology._climatology` và `ai_model.canonical_cell_id`.
- **Cập nhật các bài test patch trực tiếp module định nghĩa**:
  + `test_cold_start.py`: patch `weather_climatology._climatology`.
  + `test_readiness.py`: patch `main.weather_climatology._climatology` và dùng `ai_model.canonical_cell_id`.
  + `test_verification_integrity.py`: dùng `weather_core.TS_FMT`.
  + `test_daily_confidence.py`: import `_day_confidence, SKILL_NOTES` từ `weather_daily`.
  + `test_climatology.py`: import `_climatology` từ `weather_climatology`.
  + `test_cell_history.py`: import `_clim_series, _climatology` từ `weather_climatology`, `_series` từ `weather_series`.
  + `test_map_frames.py`: import và patch trực tiếp `ai_model`, `long_range_model`, `weather_map._replay_ai_rain`.
  + `test_multilocation.py`: import và patch trực tiếp `ai_model`, `long_range_model`.
  + `test_replay.py`: patch `ai_model.verification_cutoff` trực tiếp.
  + `test_self_forecast_api.py`: dùng `weather_core.TS_FMT`, `weather_data_revision`, và patch trực tiếp `long_range_model`, `ai_model`.
- **Tối giản `backend/routers/weather.py`**:
  + Xoá toàn bộ khối re-export hàng chục tên nội bộ.
  + File chỉ còn 21 dòng (< 30 dòng), đóng vai trò thuần tuý router assembler (`include_router` cho `weather_endpoints`, `weather_ai`, `weather_map`) và public helper `invalidate_climatology()`.
- **Kết quả test backend**: `680 passed, 2 subtests passed in 80.54s`, ruff sạch: `All checks passed!`.

---

## Bước 6 — Tách file Flutter quá lớn (Flutter, kiến trúc)
- **Mục tiêu**: Không file nào trong `lib/` > 700 dòng; giữ nguyên 100% hành vi, analyzer sạch, test $\ge 749$ passed, golden không đổi.
- **Tiến hành tách toàn bộ 14+ file vượt ngưỡng 700 dòng**:
  1. `lib/models/weather.dart` (990 -> 14 dòng): Tách theo cấu trúc class sang `lib/models/weather/` (`current_weather.dart`, `hourly_forecast.dart`, `daily_forecast.dart`, `ai_forecast.dart`, `weather_data.dart`, `weather_search.dart`, `weather_result.dart`), giữ barrel export nguyên vẹn.
  2. `lib/screens/trip_screen.dart` (1119 -> 552 dòng): Tách các widget màn hình sang `lib/screens/trip/` (`trip_helpers.dart`, `nowcast_card.dart`, `route_map.dart`, `route_summary.dart`, `driving_view.dart`, `trip_history_widgets.dart`).
  3. `lib/screens/forecast/forecast_charts.dart` (1096 -> 10 dòng): Tách các biểu đồ chi tiết sang `lib/screens/forecast/charts/` (`chart_common.dart`, `hourly_temperature_chart.dart`, `hourly_rain_chart.dart`, `hourly_wind_chart.dart`, `daily_temperature_chart.dart`, `daily_bar_chart.dart`).
  4. `lib/providers/account_provider.dart` (1031 -> 681 dòng): Tách các service xử lý document/merge/storage sang `lib/services/` (`account_merger.dart`, `account_doc_builder.dart`, `account_sync_storage.dart`).
  5. `lib/screens/ai_verify_screen.dart` (906 -> 347 dòng): Tách các card kiểm chứng sang `lib/screens/ai_verify/` (`verify_chart.dart`, `evaluation_card.dart`, `horizon_card.dart`).
  6. `lib/ui/weather/weather_background.dart` (870 -> 458 dòng): Tách các layer hiệu ứng thời tiết sang `lib/ui/weather/background/` (`scene_override.dart`, `layer_view.dart`).
  7. `lib/screens/onboarding_screen.dart` (854 -> 160 dòng): Tách các bước onboarding bằng `part` sang `lib/screens/onboarding/` (`onboarding_gate.dart`, `onboarding_components.dart`, `places_step.dart`, `times_step.dart`, `notify_step.dart`).
  8. `lib/screens/account_screen.dart` (814 -> 198 dòng): Tách các card xác thực bằng `part` sang `lib/screens/account/` (`sign_in_card.dart`, `signed_in_card.dart`, `delete_account_dialog.dart`, `account_widgets.dart`).
  9. `lib/models/weather_alerts.dart` (807 -> 68 dòng): Tách các model cảnh báo bằng `part` sang `lib/models/weather_alerts/` (`alert_settings.dart`, `alert_event.dart`, `alert_notice.dart`).
  10. `lib/models/activities.dart` (793 -> 180 dòng): Tách các model hoạt động bằng `part` sang `lib/models/activities/` (`activity_score.dart`, `activity_routine.dart`, `commute_settings.dart`).
  11. `lib/ui/weather/widgets/collapsing_header.dart` (788 -> 415 dòng): Tách bằng `part` sang `lib/ui/weather/widgets/header/` (`header_metrics.dart`, `header_chips.dart`).
  12. `lib/screens/forecast/forecast_widgets.dart` (772 -> 231 dòng): Tách bằng `part` sang `lib/screens/forecast/widgets/` (`day_picker.dart`, `day_summary_card.dart`, `hourly_table.dart`).
  13. `lib/widgets/ai_forecast_card.dart` (763 -> 303 dòng): Tách bằng `part` sang `lib/widgets/ai_forecast/` (`interval_note.dart`, `prediction_column.dart`).
  14. `lib/screens/compare_screen.dart` (763 -> 214 dòng): Tách bằng `part` sang `lib/screens/compare/` (`compare_helpers.dart`, `compare_column.dart`, `compare_chart.dart`).
  15. `lib/providers/trip_provider.dart` (765 -> 673 dòng): Tách sub-models bằng `part` sang `lib/providers/trip/trip_models.dart`.
  16. `lib/providers/planner_provider.dart` (737 -> 662 dòng): Tách logic storage & brief bằng `part` sang `lib/providers/planner/` (`planner_storage.dart`, `planner_brief.dart`).
- **Kiểm tra tiêu chí**:
  + Quét toàn bộ `lib/`: `Total files > 700 lines: 0`. File lớn nhất hiện tại là `activities_screen.dart` (690 dòng).
  + `flutter analyze`: `No issues found! (ran in 7.2s)`.
  + `flutter test`: `749 passed, 7 skipped (All tests passed! in 01:04)`.
  + Golden tests giữ nguyên không đổi.

---

## Bước 7 — Hoàn thiện repo và CI (Repo hygiene)
- **Kiểm tra toàn bộ hệ thống**:
  + Backend pytest: `680 passed, 2 subtests passed in 66.00s`.
  + Backend linter (Ruff): `All checks passed!`.
  + Flutter analyze: `No issues found! (ran in 7.2s)`.
  + Flutter test: `749 passed, 7 skipped (All tests passed! in 01:04)`.
- **Hoàn thiện CI** `.github/workflows/backend-tests.yml`:
  + Bổ sung bước `Lint with ruff` (`python -m ruff check .`) chạy sau bước cài `requirements-dev.txt`.
- **Đồng bộ README.md**:
  + Thống nhất mốc kiểm chứng ở đầu README với mục "Kiểm chứng hiện tại (23/10/2026)" chứa số đo thật của cả Backend và Flutter.
  + Chuyển các mốc cập nhật cũ (650, 569, 492) xuống mục "Lịch sử cập nhật", đồng bộ các đường dẫn trỏ tới `docs/archive/`.
- **Gom tài liệu cũ sang `docs/archive/`**:
  + Di chuyển 10 file markdown cũ sang `docs/archive/`: `continuation_20261022.md`, `data_upgrade_20261022.md`, `deep_review_20261021.md`, `interval_upgrade_20261022.md`, `learning_curve_20261022.md`, `metar_history_20261022.md`, `operations_20261021.md`, `station_data_20261022.md`, `station_temperature_20261022.md`, `upgrade_20261021.md`.
  + Giữ nguyên tài liệu báo cáo đồ án (`docs/bao_cao.md`, `deliverables/*`, `Chuc nang/*`) và các hướng dẫn/kế hoạch hiện hành.
- **Quét bí mật**:
  + Quét toàn bộ repo không có bí mật / token / mật khẩu nào bị lọt. Chỉ có giá trị placeholder `ADMIN_TOKEN=change-me` trong `.env.example`.
- **Quy tắc commit**:
  + Tuân thủ nghiêm ngặt quy tắc không tự ý commit: Toàn bộ thay đổi đã sẵn sàng để người dùng xem xét và xác nhận trước khi chia commit.
