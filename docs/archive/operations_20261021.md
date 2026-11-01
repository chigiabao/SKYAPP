# Phat trien van hanh ngay 21/10/2026

## Ket qua

Tiep tuc yeu cau phat trien, tap trung vao freshness, ingestion va retry
tac vu nen. Khong huan luyen lai hoac thay model/evaluation artifacts.

- Backend scheduler co mot lan retry som sau 300 giay khi error/partial,
  roi quay ve HH:05. Busy khong tinh la ingestion that bai; qua chu ky gio
  moi se reset ngan sach retry, ke ca da busy qua ranh gio.
- Health co scheduler.state, last_attempt_at, last_finished_at, last_outcome,
  next_run_at, consecutive_failures. Day la trang thai cua process dang phuc
  vu API; not_started cho biet lifespan chua chay, disabled khi INGEST_ENABLED=0.
- Shutdown dat stopping neu worker con chay sau timeout, stopped chi khi
  worker ket thuc. Event.wait giup dung som thoi gian cho; khong khoi tao
  them luot sau stop. Network request dang chay van theo HTTP timeout hien co.
- Parser kiem tra array length, timestamp gio/trung, timezone, boolean va
  NaN/Infinity/overflow. Optional null van la null, gia tri 0 van duoc giu.
  Historical khong co nhiet do dung duoc trong cua so yeu cau se that bai.
- Parse rieng tung location trong batch; giu thu tu/location va chi danh dau
  series loi. Forecast tham chieu/AQ loi khong huy du lieu weather hop le.
- Background Flutter giu public Future<int> cho caller cu, them callback
  tra ket qua retry cho Workmanager. Timeout/network/server tam thoi yeu cau
  retry; HTTP 401/403, invalid data/bad request/not found khong retry.
  Thanh cong tung dia diem va dedup duoc giu; flush truoc khi dispose provider.

## Du lieu live

Request kiem tra upstream nho tra HTTP200. Da sao luu SQLite bang backup API
truoc khi chay pipeline tren DB that:
`build/weather-before-operations-20261021.db` (64,946,176 bytes).

Luot thu cong ID51 luc 19:25:32-19:26:11 (+07): status ok, 2,881 hang moi,
506 hang cap nhat, 67/67 chuoi rieng biet thanh cong, 0 loi, 8 HTTP requests
(khoang 174 weighted calls), 39.2 giay. Health co 68 o vi co alias dung chung
chuoi. Chi luu input toi gio hien tai, khong ghi gio tuong lai vao hourly_weather.
External forecasts van tat; du bao live do model cua app sinh.
Log: `build/operations-live-ingest-20261021.log`.
PowerShell danh dau native stderr logging la NativeCommandError; ket qua
JSON/ingest_log va du lieu sau cap nhat xac nhan luot ingest da thanh cong.

Backend moi port8025, PID21576, bind127.0.0.1, lifespan on,
INGEST_ENABLED=1, EXTERNAL_FORECAST_ENABLED=0, mot worker.
Luot startup 19:41:57-19:42:27 thanh cong; scheduler waiting, next20:05,
consecutive_failures=0. Health healthy/readytrue, latest19:00 ngay21/10,
fresh68/68. Bundle48gio/7ngay, observed+ai, forecast_errornull.
Khong doi dong ho, khong dung replay de thay the du lieu live.
Contract daily AI co san dung max xac suat gio khi du24gio, khong phai
xac suat su kien mua ngay da hieu chuan. Smoke browser cu doi null moi ngay
da duoc cap nhat de kiem tra max tren ngay du24gio trong bundle, range/null
va confidence/skill_note; khong thay logic production hoac artifacts.

Preview web: http://127.0.0.1:8112 ; API moi: http://127.0.0.1:8025 .
Tien trinh backend cu8024 duoc giu nguyen. Auto-review tu choi dung PID17484
vi chua du bang chung quyen so huu; khong tim cach vuot quy trinh nay.

## Kiem chung

- Backend focused sau independent review: 101 passed, 6.12s.
- Backend full: 492 passed, 15 skipped (fixture synthetic model training),
  50.23s; `--skip-model-training -p no:cacheprovider`, DB test rieng.
  `build/operations-backend-final.log` va `.xml`.
- Flutter focused: 67 passed; `build/operations-flutter-focused.log`.
- Flutter full: 721 passed, 4 live skipped trong full run, exclude golden,
  57s; `build/operations-flutter-full.log`.
- Sau do 4 live tests chay rieng tren API8025: ca 4 passed, khong skip.
  `build/operations-flutter-live.log`. Test replay khong ep phai co archive;
  neu khong co thi phai unavailable/no_archived_forecast va horizons rong.
- Analyze: No issues found, 3.4s; `build/operations-analyze-final.log`.
- Web build thanh cong, 36.6s, API_BASE_URL port8025, resources local;
  `build/operations-web-build.log`. Browser live390x844,375x667,844x390,
  1440x960, Home/Conditions, reduced motion; khong pageerror. Da xem anh
  phone nho/desktop/Conditions. `build/operations-live-ui/results.json`
  va PNG cung thu muc; khong phai replay hay mock weather.
- Bang chung health/bundle luc19:53 (+07): `build/operations-live-health.json`
  va `build/operations-live-bundle.json`; latest19h, fresh68/68, readytrue,
  scheduler waiting20:05. Chua cho den20:05 de khang dinh da quan sat luot gio
  tiep theo; cadence/retry duoc kiem tra bang fake clock trong pytest.
- CI gate readiness duoc bo sung ingest/reliability tests; chua chay GitHub
  runner trong luot nay. `git diff --check` dat, chi canh bao LF/CRLF.
- Independent backend review da xu ly per-location parse va retry qua gio;
  khong con finding trong scope. Cac test shutdown co ca worker ket thuc muon.

## Bien moi truong van hanh backend

| Bien | Mac dinh | Y nghia |
|---|---|---|
| `HOST` | `127.0.0.1` | Dia chi bind khi chay `python main.py`; dat `0.0.0.0` neu can mo ra mang. |
| `PORT` | `8000` | Cong lang nghe. |
| `RELOAD` | `0` | `1` bat auto-reload (uvicorn nhan chuoi `main:app`); chi dung khi dev. |
| `ENABLE_DOCS` | `1` | `0` tat `/docs`, `/redoc`, `/openapi.json`; nen tat o production. |
| `ADMIN_TOKEN` | (trong) | Bat buoc khi chay sau reverse proxy. Khong co token: `/admin/*` chi nhan request truc tiep tu localhost va tu choi (403) moi request co `X-Forwarded-For`, `X-Real-IP` hoac `Forwarded`. |

SQLite: moi ket noi qua `database.get_db_connection()`/`init_db()` dat
`busy_timeout` 30 giay (ingest.py va monitor da co `timeout=30`), nen ghi dong
thoi se cho thay vi bao "database is locked". Da bat WAL: `init_db()` (luc khoi
dong API) dat `PRAGMA journal_mode=WAL` mot lan, che do nay luu trong file nen
moi ket noi sau (ke ca ingest) deu dung WAL, doc khong chan ghi. Cache du bao
trong `routers/weather.py` dung `database.database_revision()` (kich thuoc/mtime
file chinh + file `-wal` khi khong rong), nen ket noi chi doc khong lam mat
cache, con moi lan commit van lam moi du bao. Sao luu nen dung `sqlite3 .backup`
(hoac copy ca `weather.db-wal`), khong chi copy rieng `weather.db`.
Long-range AI tu choi (`invalid_history`) neu 48 gio lich su thieu hoac co
gia tri khong huu han o bat ky feature dau vao nao, khong suy dien du bao.

## Gioi han

Chua chay golden, TalkBack/VoiceOver, FPS/pin hay Workmanager tren dien thoai
that. Khong coi mock callback la chung minh thong bao chay dung gio tren OS.
Chua tai danh gia model hoac doi chieu quan trac tram; khong tu cham moi muc
tren9. Scheduler can process/may chu tiep tuc chay va mang kha dung.
Chua kiem thu production TLS/proxy, HA nhieu worker, signing hay iOS App Groups.
Khong commit/push; giu nguyen dirty work va model artifacts co san.
