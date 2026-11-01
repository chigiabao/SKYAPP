# Hướng dẫn nâng mọi hạng mục lên ≥ 9/10

Ngày lập: 23/10/2026
Workspace: `D:\wether_app\sky_weather_app` (Windows, Git Bash hoặc PowerShell)
Người thực hiện: AI agent tiếp theo. Làm **đúng thứ tự**, **từng bước một**, chạy kiểm tra sau mỗi bước.

Phạm vi: chỉ phần sản phẩm (app Flutter, backend, AI, bảo mật, repo). **Không đụng báo cáo** (`D:\wether_app\deliverables\*`, `Chuc nang\*`, `docs/bao_cao.md`).

## Điểm hiện tại và mục tiêu

| Hạng mục | Hiện tại | Mục tiêu | Phần làm |
|---|---|---|---|
| Ứng dụng Flutter | 8,5 | ≥ 9 | Bước 6 |
| Backend FastAPI | 8,0 | ≥ 9 | Bước 4, 5 |
| AI/ML | 7,0 | ≥ 9 | Bước 2, 3 |
| Bảo mật | 8,0 | ≥ 9 | Bước 4 |
| Repo hygiene | 5,5 | ≥ 9 | Bước 1, 7 |

Kết quả kiểm tra lúc lập tài liệu (mốc so sánh, không được làm giảm):

- Backend: `675 passed, 2 subtests passed` (`python -m pytest -q` trong `backend/`).
- Flutter: `flutter analyze` → `No issues found!`; `flutter test` → `749 passed, 7 skipped`.

---

## Quy tắc bắt buộc (đọc trước khi làm)

1. **Không** chạy `git reset`, `git checkout -- .`, `git clean`, `git push`, `git commit`. Commit chỉ khi người dùng đồng ý ở Bước 7.
2. **Không xóa** thư mục model. Chỉ **di chuyển** ra ngoài repo (Bước 1) để có thể khôi phục.
3. **Không** tune tham số trên tập **test**. Mọi lựa chọn (offset, ngưỡng, trọng số) chỉ được chọn trên `val_select` hoặc tập calibration. Test chỉ được đánh giá **một lần** ở cuối.
4. **Không** sửa số liệu cho đẹp. Mọi con số ghi vào README/docs phải copy từ file JSON/CSV/log vừa sinh ra, kèm đường dẫn file nguồn.
5. **Không** thêm dependency mới vào `pubspec.yaml` hoặc `requirements.txt`.
6. Sau **mỗi bước**, chạy lại test liên quan. Nếu test đỏ, sửa trước khi sang bước tiếp. Không được xóa hoặc `skip` test để cho xanh.
7. Viết code giống style xung quanh (tên biến, comment ngắn, tiếng Anh trong code, tiếng Việt trong docs/UI).
8. Ghi nhật ký từng bước vào `docs/nang_9_diem_log_20261023.md`: lệnh đã chạy, kết quả, file đã sửa.

Lệnh kiểm tra chuẩn (dùng lại nhiều lần):

```bash
# Backend
cd backend && python -m pip install -r requirements-dev.txt   # một lần, để có ruff
cd backend && python -m pytest -q -p no:warnings
cd backend && python -m ruff check .

# Flutter (ở thư mục gốc sky_weather_app)
flutter analyze
flutter test
```

---

## Bước 1 — Dọn thư mục model trùng (Repo hygiene)

Vấn đề: `backend/models/` có 4 bản v3 (~520 MB): `v3`, `v3_candidate`, `v3_candidate_20261023`, `v3_backup_20261023`. `.gitignore` chưa chặn hai thư mục có ngày.

1. Ghi SHA-256 của mọi file trong 4 thư mục vào `D:\wether_app\build\model-archive\hashes_20261023.txt`:
   ```bash
   mkdir -p /d/wether_app/build/model-archive
   cd backend/models && sha256sum v3/* v3_candidate/* v3_candidate_20261023/* v3_backup_20261023/* > /d/wether_app/build/model-archive/hashes_20261023.txt
   ```
2. **Di chuyển** (không xóa) ra ngoài repo:
   ```bash
   mv backend/models/v3_candidate /d/wether_app/build/model-archive/
   mv backend/models/v3_candidate_20261023 /d/wether_app/build/model-archive/
   mv backend/models/v3_backup_20261023 /d/wether_app/build/model-archive/
   mv backend/models/station_temperature_candidate_20261022 /d/wether_app/build/model-archive/
   ```
   Giữ nguyên `v3/`, `long_range/`, `evaluation/` và các file v2 ở gốc `backend/models/` (code fallback còn dùng).
   Nếu Bước 2 cần backup để rollback, dùng bản trong `build/model-archive/v3_backup_20261023`.
3. Thêm vào `.gitignore` (cạnh dòng `backend/models/v3_candidate/`):
   ```
   backend/models/v3_*/
   !backend/models/v3/
   backend/models/*_candidate*/
   backend/models/*_backup*/
   ```
4. Kiểm tra: `git status --short backend/models` không còn hiện thư mục candidate/backup; chạy backend tests → vẫn 675 passed.
5. Nếu có test hoặc script trỏ vào `models/v3_candidate` (ví dụ default của `scripts/recalibrate_intervals_v3.py:445`), đổi default thành `models/v3`. Tìm bằng: `grep -rn "v3_candidate\|v3_backup" backend --include=*.py`.

**Đạt khi**: repo chỉ còn một bản v3; dung lượng `backend/models` giảm ≥ 350 MB; test xanh.

---

## Bước 2 — Sửa vấn đề interval của AI v3 (AI/ML, quan trọng nhất)

Vấn đề đã xác minh:

- Model đang phục vụ `lgbm-hcmc-global-v3-20261023` có coverage khoảng nhiệt độ trên test **88,48 / 88,11 / 89,33 %** (1h/3h/6h), dưới mục tiêu 90 %.
- App và API vẫn ghi "khoảng tin cậy 90%" (`backend/ai_model.py:431`, giá trị `nominal` trả về ở `ai_model.py:450`).
- `README.md:86` và `README.md:322` vẫn ghi số cũ `91,1 / 90,2 / 90,4%`.

### 2a. Thử hiệu chỉnh lại interval đúng phương pháp

1. Đọc `backend/scripts/train_global_v3_interval.py` và `backend/scripts/recalibrate_intervals_v3.py` để hiểu split và cách tính offset conformal.
2. Chạy lại hiệu chỉnh cho model đang phục vụ, ghi ra thư mục mới (không ghi đè `v3/`):
   ```bash
   cd backend
   python scripts/recalibrate_intervals_v3.py --run --model-dir models/v3 \
     --output models/evaluation/interval_recal_20261023
   ```
   Nếu script yêu cầu tham số khác, đọc `--help` và ghi lại vào log.
3. Cách tăng coverage hợp lệ (chọn trên calibration, **không** trên test):
   - Tính offset conformal trên cửa sổ calibration **gần thời gian test nhất** (vài tháng cuối của `val_select`), vì lỗi coverage chủ yếu do dữ liệu dịch chuyển theo thời gian.
   - Dùng mức quantile hữu hạn mẫu: `ceil((n+1)*0.9)/n`, không dùng 0,9 trực tiếp.
   - Nhóm offset theo `(horizon, cell)`; nếu nhóm có < 200 mẫu thì gộp về `(horizon)`.
4. Đánh giá **một lần** trên test. Gate: macro coverage ≥ 90 % ở cả 1h/3h/6h **và** mọi ô ≥ 85 %, **và** độ rộng trung bình tăng không quá 25 % so với hiện tại.

### 2b. Quyết định

- **Nếu đạt gate**: chép các file interval mới vào `backend/models/v3/` (giữ bản cũ trong `build/model-archive/`), cập nhật `extension_v3.json`, `evaluation_v3.json` bằng số thật, chạy lại test.
- **Nếu không đạt**: KHÔNG ép. Thay vào đó làm trung thực:
  1. Trong `backend/ai_model.py`, nhãn phải dùng **coverage đạt được trên test** thay vì `nominal`. Ví dụ `_interval_v3` trả về `iv.get("achieved_coverage", {}).get(f"{h}h")` nếu có, và `_uncertainty_note` ghi "khoảng ~88%" thay vì "khoảng tin cậy 90%".
  2. Thêm trường `achieved_coverage` (theo horizon, số từ evaluation) vào `extension_v3.json` → `interval`.
  3. Cập nhật Flutter: tìm chuỗi "khoảng 90%" bằng `grep -rn "90%" lib` và cho hiển thị theo giá trị API trả về, không hard-code.
  4. Thêm/cập nhật test backend (`backend/tests/test_ai_global.py`) kiểm tra nhãn dùng coverage thật; cập nhật test Flutter liên quan.

### 2c. Đồng bộ số liệu

- Sửa `README.md:86`, `README.md:322` theo số mới (copy từ JSON).
- Sửa mâu thuẫn trong `docs/retrain_global_v3_20261023.md`: mục 1 nói đã promote nhưng §6.3 (dòng 147) nói hash `v3/` không đổi. Ghi rõ: hash khớp **trước** khi promote; sau promote hash `v3/` = hash candidate (dẫn file `hashes_20261023.txt`). Mục 4 dòng 106 ghi "giữ nguyên production" cũng phải sửa cho khớp quyết định cuối.

**Đạt khi**: không còn chỗ nào trong code/README/app ghi coverage cao hơn số đo thật; test xanh.

---

## Bước 3 — So sánh công bằng và chọn model theo từng mục tiêu (AI/ML)

Vấn đề: trên test sạch, candidate mới **thua** model cũ ở F1 mưa cả 3 horizon (ví dụ 3h: 0,531 so với 0,549) và MAE nhiệt độ 3h/6h. Promotion dựa trên `val_select` (in-sample cho bước fallback).

1. Viết script `backend/scripts/compare_v3_versions.py` (hoặc mở rộng script có sẵn nếu đã có chức năng tương tự) so sánh `models/v3` với `build/model-archive/v3_backup_20261023` trên **cùng các hàng test**: MAE nhiệt độ, Brier + F1 mưa, coverage interval, theo horizon và theo ô. Xuất `backend/models/evaluation/compare_v3_20261023.json` và `.csv`.
2. Quy tắc chọn (ghi vào `backend/models/v3/serving_policy_v3.json`, trường mới `selection_rule`): với mỗi mục tiêu (nhiệt độ, mưa) × horizon, chọn bản thắng trên **`val_select`**, rồi báo cáo kết quả của lựa chọn đó trên test. Không chọn theo test.
3. Nếu quy tắc chọn ra booster cũ cho một mục tiêu, sửa loader trong `ai_model.py` để đọc booster theo `serving_policy_v3.json` (ví dụ trường `booster_source` theo mục tiêu/horizon). Giữ đúng `feature_columns` của booster đó; thêm test train/serve parity cho trường hợp này (xem test có sẵn với `serving_samples.json`).
4. Ghi bảng kết quả (val_select và test, có baseline persistence và climatology) vào `docs/retrain_global_v3_20261023.md` mục mới "Lựa chọn cuối".

**Đạt khi**: có file so sánh tái lập được; quyết định phục vụ dựa trên val_select và được ghi rõ; test xanh.

---

## Bước 4 — Bảo mật và rate limit (Bảo mật, Backend)

1. **Bật rate limit mặc định**: `backend/main.py:234` đổi default `RATE_LIMIT_PER_MINUTE` từ `0` thành `120`. Giữ khả năng tắt bằng biến môi trường `0`. Cập nhật `.env.example` và `docs/deploy.md`. Trong `backend/tests/conftest.py`, đặt `RATE_LIMIT_PER_MINUTE=0` cho test nếu test hiện có bị 429.
2. **Một hàm lấy IP duy nhất**: `backend/rate_limit.py:30` đã có `client_ip` hỗ trợ `X-Forwarded-For` khi `TRUST_PROXY=1`. Tách thành hàm module-level `client_ip_from_request(request)` dùng chung, rồi thay ở:
   - `backend/routers/auth.py:212` (`request.client.host`)
   - `backend/routers/feedback.py:37` (`request.client.host`)
   Chỉ tin `X-Forwarded-For` khi `TRUST_PROXY=1`; lấy IP **ngoài cùng bên phải** do proxy tin cậy thêm vào, không lấy giá trị đầu do client tự gửi.
3. **Chống dò email ở đăng ký**: `backend/routers/auth.py:202` đang trả 409 khi email tồn tại. Đổi để phản hồi giống nhau cho email mới và email đã có (ví dụ 202 với cùng thông báo), hoặc giữ 409 nhưng thêm rate limit chặt cho `/auth/register` (ví dụ 5 lần/giờ/IP, tái dùng cơ chế lockout sẵn có). Chọn một cách, ghi lý do trong log. Nếu đổi status code, cập nhật client Flutter (`lib/providers/account_provider.dart`) và test.
4. Thêm test:
   - Sau proxy (`TRUST_PROXY=1`, header `X-Forwarded-For`), hai IP khác nhau không bị khóa chung.
   - Không có `TRUST_PROXY`, header giả không đổi được IP.
   - `/auth/register` bị chặn sau N lần.

**Đạt khi**: test mới xanh, toàn bộ backend xanh, ruff sạch.

---

## Bước 5 — Bỏ re-export nội bộ ở router (Backend, kiến trúc)

Vấn đề: `backend/routers/weather.py:15-37` re-export hàng chục tên `_private` để test và module khác dùng; `backend/routers/feedback.py:21` import `_resolve_location` từ `routers.weather`.

1. `feedback.py`: import trực tiếp `from routers.weather_core import resolve_location` (đổi tên `_resolve_location` → `resolve_location` trong `weather_core.py` vì nó được dùng ngoài module; giữ alias `_resolve_location = resolve_location` tạm thời nếu nhiều chỗ dùng).
2. Với từng tên trong khối re-export: `grep -rn "weather\.<tên>" backend` để tìm nơi dùng. Đổi test/module sang import/patch trực tiếp module định nghĩa (đúng như docstring `weather.py:12-13` đã yêu cầu).
3. Xóa tên khỏi khối re-export khi không còn ai dùng. Mục tiêu: `weather.py` chỉ còn tạo `router` và `include_router`.
4. Làm từng nhóm nhỏ, chạy test sau mỗi nhóm.

**Đạt khi**: `weather.py` < 30 dòng, không có import `_tên` xuyên module trong `routers/`, test xanh.

---

## Bước 6 — Tách file Flutter quá lớn (Flutter, kiến trúc)

File > 850 dòng: `lib/screens/trip_screen.dart` (1119), `lib/screens/forecast/forecast_charts.dart` (1096), `lib/providers/account_provider.dart` (1031), `lib/models/weather.dart` (990), `lib/screens/ai_verify_screen.dart` (906).

1. Mỗi lần chỉ tách **một** file. Chỉ di chuyển code (widget private → file riêng trong thư mục con, ví dụ `lib/screens/trip/`), **không đổi hành vi**.
2. `account_provider.dart`: tách phần gọi HTTP/sync sang `lib/services/` nếu chưa có, provider chỉ giữ trạng thái.
3. `models/weather.dart`: tách theo lớp (`current`, `hourly`, `daily`, `ai_forecast`) và giữ file gốc `export` lại để không phải sửa import ở nơi khác.
4. Sau mỗi file: `flutter analyze` sạch, `flutter test` vẫn 749 passed, golden không đổi (không chạy `--update-goldens`).

**Đạt khi**: không file nào trong `lib/` > 700 dòng; analyzer sạch; test và golden xanh.

---

## Bước 7 — Hoàn thiện repo và CI (Repo hygiene)

1. Chạy toàn bộ kiểm tra: backend pytest + ruff, flutter analyze + test. Ghi số vào log.
2. Kiểm tra CI `.github/workflows/backend-tests.yml` có chạy `ruff check .` và `pytest` với ngưỡng coverage 80 %; nếu thiếu ruff thì thêm bước.
3. README: thay ba mốc số test khác nhau (650/569/492) ở đầu README bằng **một** mục "Kiểm chứng hiện tại" với số vừa chạy và ngày chạy. Các mục cũ chuyển xuống phần "Lịch sử".
4. Gom tài liệu: `docs/` có 18+ file handoff theo ngày. Tạo `docs/archive/` và **di chuyển** (không xóa) các file handoff cũ (`*_2026102[0-2].md`, `deep_review_*`, `upgrade_*`) vào đó; sửa link trong README.
5. Kiểm tra không có bí mật: `git status --short` và `grep -rn "SECRET\|PASSWORD\|TOKEN=" --include=*.env* .` chỉ ra `.env.example`.
6. **Hỏi người dùng** trước khi commit. Nếu đồng ý, chia thành các commit nhỏ theo bước (dọn model, interval AI, chọn model, bảo mật, refactor router, refactor Flutter, docs). Không commit thư mục trong `build/`.

**Đạt khi**: `git status` sạch sau commit; một README số liệu nhất quán; CI có lint + test + coverage.

---

## Tiêu chí hoàn thành cuối cùng (checklist)

- [ ] Chỉ còn một bản v3 trong repo; bản cũ ở `D:\wether_app\build\model-archive\`.
- [ ] Coverage interval hiển thị = coverage đo thật (hoặc ≥ 90 % thật sau hiệu chỉnh đúng cách).
- [ ] Quyết định phục vụ model dựa trên `val_select`, có bảng so sánh tái lập được.
- [ ] Rate limit bật mặc định; auth/feedback dùng chung hàm lấy IP; đăng ký không lộ email hoặc có rate limit.
- [ ] `routers/weather.py` không còn re-export tên private.
- [ ] Không file Dart trong `lib/` > 700 dòng.
- [ ] Backend: ≥ 675 passed, ruff sạch. Flutter: analyzer sạch, ≥ 749 passed, golden không đổi.
- [ ] README có đúng một bộ số liệu hiện tại; docs cũ đã vào `docs/archive/`.
- [ ] Nhật ký `docs/nang_9_diem_log_20261023.md` ghi đủ lệnh và kết quả.
- [ ] Báo cáo cuối cho người dùng bằng tiếng Việt: việc đã làm, việc chưa làm (và lý do), số test trước/sau.
