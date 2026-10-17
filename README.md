# Sky Weather – Ứng dụng thời tiết TP. Hồ Chí Minh

Đồ án sinh viên: ứng dụng Flutter (Android, web, iOS) hiển thị thời tiết cho **TP.HCM mới** (sau sáp nhập 2025 với Bình Dương và Bà Rịa – Vũng Tàu), lấy dữ liệu từ backend FastAPI của nhóm, kèm mô hình AI (LightGBM) dự báo nhiệt độ và khả năng mưa trong 1, 3, 6 giờ tới.

- Phạm vi: **168 phường/xã/đặc khu**, gộp thành **67 ô lưới** của Open-Meteo (các phường cùng rơi vào một ô lưới dùng chung một chuỗi dữ liệu). Ngoài ra có điểm `tsn` (gần Tân Sơn Nhất, điểm huấn luyện ban đầu), là alias của ô `om-10.7909-106.6313`.
- Danh sách và ranh giới phường/xã: OpenStreetMap (© OpenStreetMap contributors, ODbL), xem [backend/data/locations/SOURCES.md](backend/data/locations/SOURCES.md).
- Dữ liệu thời tiết: Open-Meteo, theo giờ, múi giờ GMT+7. Backend tự cập nhật mỗi giờ (phút 05) cho 68 chuỗi (67 ô + `tsn`).
- Đây là **dữ liệu mô hình**, không phải số đo trạm. Dự báo AI chỉ là **thử nghiệm**. Cảnh báo trong app không phải cảnh báo chính thức; cảnh báo chính thức xem tại Đài KTTV khu vực Nam Bộ.
- Mã nguồn: https://github.com/chigiabao/SKYAPP
- Báo cáo chi tiết: [docs/bao_cao.md](docs/bao_cao.md). Câu hỏi bảo vệ: [docs/cau_hoi_bao_ve.md](docs/cau_hoi_bao_ve.md).

## Kiến trúc

```
+---------------------------+        HTTP/JSON        +-----------------------------+
|  Ứng dụng Flutter         |  ------------------->   |  Backend FastAPI (Python)   |
|  sky_weather_app          |  <-------------------   |  main.py (lịch ingest/giờ)  |
|  - Provider (trạng thái)  |                         |  routers/weather.py         |
|  - Cache offline          |                         |  routers/locations.py       |
|  - flutter_map (OSM)      |                         |  routers/route.py (OSRM)    |
|  - Android / web / iOS    |                         |  routers/auth.py, sync.py   |
|                           |                         |  routers/feedback.py        |
|                           |                         |  routers/monitor.py         |
|                           |                         |  ai_model.py                |
+---------------------------+                         +--------------+--------------+
                                                                     |
                                     +-------------------------------+--------------+
                                     |                                              |
                          +----------v----------+                     +-------------v------------+
                          | SQLite weather.db   |                     | LightGBM v3 toàn cục     |
                          | 68 chuỗi theo giờ,  |                     | backend/models/v3/       |
                          | dự báo NWP, AQI,    |                     | (v2 1 điểm: models/,     |
                          | phường/xã, ô lưới   |                     |  dùng dự phòng)          |
                          +----------^----------+                     +-------------^------------+
                                     |                                              |
                    ingest.py (Open-Meteo, mỗi giờ)           scripts/train_global_v3.py
                                                              + notebooks/global_model.ipynb
                          scripts/backfill_history.py  -->  data/history/cells_history.db
                          (lịch sử theo ô, dùng để huấn luyện v3)
```

## Cấu trúc thư mục

```
sky_weather_app/
├── lib/                          # ứng dụng Flutter (config, models, providers, screens, services, ui, widgets, utils)
├── test/                         # test Flutter
├── android/ ios/ web/ ...        # nền tảng Flutter
├── .github/workflows/ios-ipa.yml # CI: test, build IPA chưa ký, web, apk debug
├── tool/
│   └── cdp_screenshot.mjs        # chụp màn hình bản web qua Chrome DevTools Protocol
├── backend/                      # FastAPI + SQLite + mô hình
│   ├── main.py                   # khởi tạo app, /health, lịch ingest hằng giờ
│   ├── routers/weather.py        # các endpoint /weather/*
│   ├── routers/locations.py      # /locations/* (danh sách, tìm kiếm, GPS, GeoJSON)
│   ├── routers/admin.py          # /admin/ingest (localhost hoặc ADMIN_TOKEN)
│   ├── routers/route.py          # /route: tuyến OSRM + thời tiết dọc tuyến
│   ├── routers/auth.py, sync.py  # tài khoản tuỳ chọn, /me, /privacy
│   ├── routers/feedback.py       # /feedback (verified = false)
│   ├── routers/monitor.py        # /admin/monitor, /admin/retrain, /admin/rollback
│   ├── ingest.py                 # tải dữ liệu mới + dự báo 7 ngày từ Open-Meteo
│   ├── ai_model.py               # tạo đặc trưng + suy luận v2/v3 (dùng chung với huấn luyện)
│   ├── convert_excel_to_sqlite.py
│   ├── scripts/
│   │   ├── build_locations.py    # tạo danh sách phường/xã, ranh giới, ô lưới từ OSM
│   │   ├── backfill_history.py   # tải lịch sử theo ô (ngân sách API, chạy tiếp được)
│   │   ├── train_global_v3.py    # huấn luyện + đánh giá mô hình v3
│   │   └── train_global_v3_ext.py # khoảng p10–p90, hiệu chuẩn mưa, mục tiêu mới + cổng phục vụ
│   ├── tests/                    # pytest
│   ├── data/
│   │   ├── weather.db
│   │   ├── locations/            # locations.json, cells.json, *.geojson, SOURCES.md
│   │   └── history/              # cells_history.db (dữ liệu huấn luyện v3)
│   └── models/
│       ├── *.pkl, *.json         # mô hình v2 (1 điểm tsn)
│       └── v3/                   # mô hình v3 toàn cục, metadata_v3.json, evaluation_v3.json, extension_v3.json, per_cell_metrics*.csv
├── notebooks/
│   ├── weather_forecasting.ipynb # v2: EDA, huấn luyện, đánh giá tại tsn
│   ├── global_model.ipynb        # v3: kiểm tra dữ liệu, rò rỉ, kết quả theo ô, spatial holdout
│   └── figures/                  # hình xuất từ notebook
├── data/                         # file Excel gốc (không chỉnh sửa)
├── docs/                         # báo cáo, câu hỏi bảo vệ
├── screenshots/                  # ảnh chụp ứng dụng
└── (ngoài thư mục này) ../Chuc nang/1.docx   # đề bài: 11 nhóm chức năng
```

## Cách chạy

### 1. Backend

```bash
cd backend
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

- Kiểm tra: mở `http://localhost:8000/health` hoặc tài liệu API tại `http://localhost:8000/docs`.
- Khi khởi động, backend chạy ingest một lần rồi lặp lại mỗi giờ vào phút 05.
- `--host 0.0.0.0` chỉ cần khi chạy app trên điện thoại thật.
- Test: `cd backend && python -m pytest tests -q` (chạy 2026-10-17 17:43: **195 passed**, 59 giây).

### 2. Backfill lịch sử theo ô (tùy chọn, dùng cho huấn luyện v3)

```bash
cd backend
python scripts/backfill_history.py --status        # xem độ phủ và mức dùng API
python scripts/backfill_history.py --max-hours 3   # chạy tối đa 3 giờ, lần sau chạy tiếp từ chỗ dừng
```

Script ghi vào file riêng `backend/data/history/cells_history.db`, giữ dưới ngân sách gọi API theo phút/giờ/ngày của Open-Meteo (mặc định 500 / 4500 / 9000), tự nghỉ khi hết ngân sách.

### 3. Ứng dụng Flutter

```bash
# chạy tại thư mục gốc (sky_weather_app)
D:\flutter\bin\flutter pub get
D:\flutter\bin\flutter run
D:\flutter\bin\flutter test --exclude-tags golden   # chạy 2026-10-17 17:44: 439 passed, 4 skipped
```

- **Android emulator**: mặc định gọi `http://10.0.2.2:8000` (địa chỉ của máy host nhìn từ emulator), không cần cấu hình.
- **Điện thoại thật** (cùng mạng Wi‑Fi với máy chạy backend):
  ```bash
  D:\flutter\bin\flutter run --dart-define=API_BASE_URL=http://<IP-máy-tính>:8000
  ```
- Chạy trên điện thoại thật qua IP LAN: dùng bản **debug/profile**. Bản `--release` chỉ cho phép HTTP tới 10.0.2.2/localhost/127.0.0.1 (network_security_config), nên sẽ không kết nối được tới IP LAN.
- Mở cổng 8000 trên Windows Firewall cho mạng Private và chạy backend với `--host 0.0.0.0`.
- Trước buổi demo nên mở `/weather/daily` một lần cho mỗi địa điểm sẽ trình bày (lần đầu mất khoảng 1,5 s để tính trung bình nhiều năm).
- **Đổi máy chủ lúc chạy:** vào **Cài đặt → Máy chủ dữ liệu**, nhập địa chỉ (ví dụ `http://192.168.1.10:8000`) và kiểm tra kết nối. Địa chỉ được lưu trên máy và ưu tiên hơn giá trị `API_BASE_URL` lúc build, nên không cần build lại.
- Cấu hình nằm tại `lib/config/api_config.dart`.
- Golden test (so ảnh chụp, gắn tag `golden`) phụ thuộc font và hệ điều hành nên được tách khỏi lệnh test chính.

### 4. Build Android

```bash
# chạy tại thư mục gốc (sky_weather_app)
D:\flutter\bin\flutter build apk --debug
```

`android/gradle.properties` đặt `kotlin.incremental=false`: pub cache nằm ở ổ C còn dự án ở ổ D, biên dịch Kotlin tăng dần lỗi khi đường dẫn khác ổ đĩa nên phải tắt.

Bundle id / applicationId: `com.skyweather.app` (iOS và Android dùng chung). Bản Android cài trước đây với id `com.example.sky_weather_app` sẽ là một ứng dụng riêng, cần gỡ thủ công.

### 4b. Web

```bash
D:\flutter\bin\flutter run -d chrome          # API mặc định http://localhost:8000
D:\flutter\bin\flutter build web              # kết quả ở build/web
```

- Trên web, API mặc định là `http://localhost:8000`. Ghi đè bằng `--dart-define=API_BASE_URL=...` như các nền tảng khác.
- Backend đã bật CORS cho mọi origin (`backend/main.py`).
- Thông báo hệ thống và chạy nền (workmanager) không có trên web: app dùng bản Noop, cảnh báo vẫn hiện trong ứng dụng.
- Trình duyệt chỉ cho dùng GPS khi trang mở qua **https** hoặc **localhost**. Nếu mở qua `http://<IP LAN>`, app báo rõ là bị chặn; khi đó hãy tìm địa điểm theo tên.

### 4c. Cài lên iPhone (không cần máy Mac)

1. Push code lên nhánh `main` của GitHub. Workflow `.github/workflows/ios-ipa.yml` sẽ tự chạy. Có thể chạy tay ở **Actions → Build iOS / Web / Android → Run workflow** và nhập `api_base_url`.
2. Chờ job `ios` xong (runner macOS), mở lần chạy đó và tải artifact **SkyWeather-unsigned-ipa** (file zip chứa `SkyWeather-unsigned.ipa`). Cũng có artifact web và apk debug.
3. Giải nén. Trong 3uTools chọn **Toolbox → IPA Signature**, đăng nhập Apple ID, ký file `.ipa` rồi cài lên máy. Trên iPhone vào **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị** để tin cậy Apple ID đó. Với iOS 16 trở lên còn phải bật **Chế độ nhà phát triển**.

Giới hạn của Apple ID miễn phí:
- Ứng dụng **hết hạn sau 7 ngày**, phải ký và cài lại (dữ liệu trong app vẫn giữ nếu cài đè cùng bundle id).
- Mỗi Apple ID cài tối đa 3 app tự ký cùng lúc.
- Không có push notification từ xa và không có App Groups. Thông báo cục bộ (cảnh báo, nhắc hoạt động) vẫn hoạt động.
- Chạy nền dùng BGAppRefreshTask: iOS tự quyết định thời điểm chạy (thường vài giờ một lần, có thể không chạy nếu ít mở app), nên không được đúng mỗi giờ như Android.

**Đặt `API_BASE_URL`** (giá trị được nhúng lúc build, nên đổi địa chỉ thì phải build lại):
- Nhập vào ô `api_base_url` khi chạy tay workflow, hoặc tạo biến repo **Settings → Secrets and variables → Actions → Variables → `API_BASE_URL`** (áp dụng cho mỗi lần push).
- IP LAN: `http://192.168.x.x:8000`. iPhone và máy chạy backend phải cùng mạng Wi‑Fi; lần đầu iOS hỏi quyền "Mạng cục bộ", hãy chọn Cho phép.
- Tunnel https (dùng được cả khi khác mạng): `cloudflared tunnel --url http://localhost:8000` rồi dùng địa chỉ `https://xxx.trycloudflare.com` mà lệnh in ra. Địa chỉ này đổi sau mỗi lần chạy lại cloudflared.
- Nếu để trống, app dùng `http://10.0.2.2:8000`, địa chỉ này không dùng được trên iPhone. Khi đó vào **Cài đặt → Máy chủ dữ liệu** trong app để nhập địa chỉ đúng, không cần build lại.

**App Transport Security**: `Info.plist` đặt `NSAllowsArbitraryLoads = true` để app gọi được backend `http://` qua IP LAN. Không dùng `NSAllowsLocalNetworking` vì khóa này không chắc phủ địa chỉ IP, và khi có nó iOS sẽ bỏ qua `NSAllowsArbitraryLoads`. Rủi ro: app được phép gửi HTTP không mã hóa tới mọi máy, nên dữ liệu trên Wi‑Fi công cộng có thể bị đọc hoặc sửa. Bản release Android chặn việc này, còn bản iOS thì không. Chấp nhận được với đồ án vì không có dữ liệu cá nhân (app không gửi tọa độ, chỉ gửi id phường/xã). Nếu chỉ dùng tunnel https thì có thể xóa khóa này.

**Trạng thái kiểm chứng iOS:** lần chạy gần nhất của workflow trên https://github.com/chigiabao/SKYAPP (2026-10-17 17:43 giờ Việt Nam, commit `b71166b`) kết thúc **success**, tức IPA chưa ký build được (kiểm tra qua GitHub API lúc 17:50). Nhóm không có Mac và **chưa có nhật ký chạy trên iPhone thật**. Nếu job `ios` lỗi, xem log của bước `flutter build ios`.

Trên iPhone: chế độ chuyến đi chạy nền nhờ `UIBackgroundModes: location` (quyền "Khi dùng ứng dụng" là đủ, iOS hiện thanh chỉ báo vị trí); token đăng nhập lưu trong Keychain.

**Widget màn hình chính (iOS): chưa làm.** Android có widget (`WeatherWidgetProvider`, layout XML: nhiệt độ, trạng thái, khả năng mưa 3 giờ, tên địa điểm đầu tiên; cập nhật khi app tải dữ liệu và khi tác vụ nền chạy). Trên iOS, Dart đã gọi `HomeWidget.saveWidgetData` (lỗi được bỏ qua khi chưa có extension) nhưng chưa có WidgetKit extension, vì phải sửa `ios/Runner.xcodeproj/project.pbxproj` mà không có Mac để thử, một lỗi sẽ làm hỏng build IPA. Khi có Mac:
1. Mở `ios/Runner.xcworkspace` bằng Xcode → **File → New → Target → Widget Extension** (ví dụ tên `SkyWeatherWidget`, bỏ chọn Live Activity / Configuration Intent).
2. Bật capability **App Groups** cho cả `Runner` và extension, cùng một id (ví dụ `group.com.skyweather.app`). Lưu ý: Apple ID miễn phí không có App Groups (xem trên), nên widget iOS cần tài khoản Apple Developer trả phí.
3. Trong Dart gọi `HomeWidget.setAppGroupId('group.com.skyweather.app')` trước `saveWidgetData`, và thêm `HomeWidget.updateWidget(iOSName: 'SkyWeatherWidget')` trong `lib/services/home_widget_service.dart`.
4. Trong extension, đọc `UserDefaults(suiteName: "group.com.skyweather.app")` các khóa `sw_place`, `sw_temp`, `sw_condition`, `sw_rain3h` để vẽ SwiftUI view.
5. Đặt Deployment Target của extension bằng của Runner, rồi build thử trên máy trước khi push.

### 4d. Git

- `.gitignore` đã loại bỏ `build/`, `.dart_tool/`, `__pycache__`, `.pytest_cache`, `backend/data/*.db`, `backend/data/history/` và `*.backup-*.db`. GitHub chặn file lớn hơn 100 MB.
- `backend/data/locations/` và `backend/models/` vẫn được commit. Hiện file lớn nhất khoảng 7 MB.
- Job `test` trong workflow chạy song song với các job build. Riêng test golden (ảnh chụp trên Windows) không chặn build, vì font và khử răng cưa trên Linux có thể khác. Test golden gắn `@Tags(['golden'])` (khai báo trong `dart_test.yaml`); workflow chạy `flutter test --exclude-tags golden`, rồi chạy riêng `--tags golden` ở bước không chặn.

### 5. Huấn luyện lại mô hình

```bash
pip install numpy pandas lightgbm joblib scikit-learn matplotlib jupyter
cd backend && python scripts/train_global_v3.py   # v3, ghi vào backend/models/v3/
python scripts/train_global_v3_ext.py             # chạy ngay sau: khoảng tin cậy, hiệu chỉnh, mục tiêu mới
cd ../notebooks && jupyter notebook global_model.ipynb
```

`global_model.ipynb` đọc kết quả của script (đặt `RETRAIN = True` để chạy lại). `weather_forecasting.ipynb` là mô hình v2 một điểm. Khởi động lại backend sau khi huấn luyện lại.

## Endpoint

Mọi `/weather/*` (trừ `/weather/map` và `/weather/map/meta`) nhận `location_id`: id phường/xã (từ `/locations`), một `cell_id`, hoặc `tsn` (mặc định). Hầu hết nhận thêm `at` (ISO 8601) để xem lại một thời điểm trong quá khứ.

| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | `/health` | Trạng thái API, DB, lần ingest gần nhất; `cells`: tổng số ô, số ô có dữ liệu trong 3 giờ qua, danh sách ô cũ |
| GET | `/locations` | 168 phường/xã/đặc khu + `tsn` (id, tên, loại, tỉnh cũ, tọa độ, `cell_id`) |
| GET | `/locations/search?q=` | Tìm theo tên, có dấu hoặc không dấu, tối đa 20 kết quả |
| GET | `/locations/nearest?lat=&lon=` | Phường/xã chứa điểm GPS (hoặc gần nhất); ngoài ranh giới trả 404 "Ngoài vùng hỗ trợ (TP.HCM)" |
| GET | `/locations/boundary` | Ranh giới TP.HCM mới (GeoJSON, đã đơn giản hóa, © OSM) |
| GET | `/locations/wards` | Ranh giới từng phường/xã (GeoJSON, © OSM) |
| GET | `/locations/current` | Cũ: điểm cố định gần Tân Sơn Nhất |
| GET | `/weather/current` | Giờ mới nhất của chuỗi dữ liệu, kèm chất lượng không khí nếu có |
| GET | `/weather/hourly?hours=24` | 1–168 giờ: giờ đã có dữ liệu, rồi dự báo Open-Meteo mới nhất, thiếu thì dùng trung bình nhiều năm; trường `source` cho biết nguồn |
| GET | `/weather/daily?days=7` | 1–14 ngày, tổng hợp theo cùng cách như `/hourly` |
| GET | `/weather/history?start_date=&end_date=` | Dữ liệu theo giờ trong khoảng, tối đa 365 ngày |
| GET | `/weather/ai-forecast` | LightGBM: nhiệt độ và xác suất mưa (≥ 0,1 mm) sau 1/3/6 giờ từ 48 giờ dữ liệu cuối; kèm `model_version` và `evaluation` (kết quả test tại ô đó) |
| GET | `/weather/ai-verify` | Dự báo AI phát hành tại `at` (mặc định 6 giờ trước) đặt cạnh giá trị thực tế |
| GET | `/weather/map?offset_hours=0` | Mỗi ô lưới (67 mục, alias `tsn` được gộp) tại khung hiện tại + `offset_hours` (0–72): nhiệt độ, gió (`wind_speed`, `wind_direction`, `wind_gusts`), lượng mưa, mưa 3 giờ sau khung, `alert` (mã dông hoặc ≥ 10 mm trong 3 giờ; theo mô hình, không chính thức), `source`, `valid_time`. Chế độ xem lại (`at`) chỉ cho `offset_hours=0`, khác thì trả 400 |
| GET | `/weather/map/meta` | `now`, `max_offset_hours` (tối đa 72; 0 khi xem lại), `issued_at` của lần dự báo mới nhất, dùng cho thanh thời gian |
| GET | `/route?from_lat=&from_lon=&to_lat=&to_lon=&depart_at=&profile=` | Tuyến đường từ OSRM (backend gọi; `profile` = `driving` / `cycling` / `foot`) kèm thời tiết khoảng mỗi 2 km theo giờ đến dự kiến, `alert` theo mẫu |
| POST | `/route/along-weather` | Body `{geometry, depart_at?, duration_min?, profile?}`: làm mới thời tiết dọc tuyến app đã có, không gọi lại OSRM |
| POST | `/feedback` | Báo lỗi / góp ý / báo dự báo sai (`kind` = `bug` / `suggestion` / `wrong_forecast`); không cần đăng nhập; 10 lần/giờ mỗi IP; trả `verified: false` |
| GET | `/feedback/summary` | Thống kê phản hồi theo loại, theo ô, tỉ lệ báo sai dự báo mưa (quản trị) |
| POST | `/auth/register` | Tạo tài khoản tuỳ chọn (email, mật khẩu 8–128 ký tự) |
| POST | `/auth/login` | Đăng nhập, trả token Bearer (hạn 30 ngày); tối đa 5 lần sai mỗi 15 phút |
| POST | `/auth/logout` | Huỷ token hiện tại |
| GET | `/me` | Thông tin tài khoản (cần `Authorization: Bearer <token>`) |
| DELETE | `/me` | Xoá tài khoản cùng mọi dữ liệu (cần mật khẩu) |
| GET / PUT / DELETE | `/me/data` | Tài liệu đồng bộ có `version`; `PUT` gửi `base_version`, trả 409 kèm bản hiện tại khi xung đột |
| GET | `/me/export` | Xuất toàn bộ dữ liệu tài khoản dạng JSON |
| GET | `/privacy` | Chính sách quyền riêng tư: lưu gì, giữ bao lâu, xoá thế nào |
| POST | `/admin/ingest` | Chạy ingest thủ công |
| GET | `/admin/ingest/log` | Nhật ký các lần ingest gần nhất |
| GET | `/admin/monitor?days=7` | Chất lượng AI đã phát hành so với thực tế, cảnh báo nhầm / bỏ sót, lỗi ingest, số lần gọi API (Open-Meteo, OSRM), phản hồi mới |
| POST | `/admin/retrain` | Chạy nền `train_global_v3.py` rồi `train_global_v3_ext.py` vào `models/v3_candidate/`; chỉ thay `models/v3` khi tốt hơn (bản cũ giữ ở `models/v3_prev/`); 409 nếu đang có lần chạy khác |
| GET | `/admin/retrain/{job_id}` | Trạng thái một lần huấn luyện lại |
| POST | `/admin/rollback` | Hoán đổi `models/v3` và `models/v3_prev` |

Mọi `/admin/*` (và `/feedback/summary`) chỉ nhận yêu cầu từ localhost, hoặc cần header `X-Admin-Token` nếu đặt biến môi trường `ADMIN_TOKEN`.

`/weather/ai-forecast` trả thêm `temperature_p10`, `temperature_p90`, `uncertainty_note` và các mục tiêu đã qua cổng kiểm chứng (`humidity`, `wind_speed`, `wind_gusts`, `precipitation_mm`; danh sách ở `enabled_targets`) khi có `backend/models/v3/extension_v3.json`. App hiện chưa hiển thị các trường này.

Trung bình nhiều năm (khi cần): ô có khoảng 3 năm dữ liệu trong `weather.db`, hoặc khoảng 2 năm sau khi ghép `data/history/cells_history.db`, dùng khí hậu riêng; ô khác dùng của `tsn`.

## Ảnh chụp màn hình

Chụp từ bản web, khung 390×844 (dữ liệu thật từ backend của nhóm).

| Trang chủ | Chi tiết | Xem lại 07/10 | Kiểm chứng AI |
|---|---|---|---|
| ![](screenshots/glass/01_home_live_390.png) | ![](screenshots/glass/04_home_details_390.png) | ![](screenshots/glass/06_home_replay_0710_390.png) | ![](screenshots/glass/08_ai_verify_390.png) |

| Bản đồ – nhiệt độ | Bản đồ – gió (phóng to) | Thanh thời gian +18 giờ | Cài đặt |
|---|---|---|---|
| ![](screenshots/phaseC/map_temp.png) | ![](screenshots/phaseC/map_zoomed.png) | ![](screenshots/phaseC/map_slider.png) | ![](screenshots/glass/09_settings_390.png) |

Ảnh bản đồ chụp bằng trình duyệt không có mạng nên nền OpenStreetMap hiện màu tối; trên máy có mạng, nền bản đồ hiển thị bình thường.
