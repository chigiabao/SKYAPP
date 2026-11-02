# Trien khai backend bang Docker (21/10/2026)

Render Free demo (khong luu ben SQLite): xem [render_demo.md](render_demo.md).
Su dung Dockerfile.render rieng; Dockerfile duoi day van can volume data/model.

Bo sung cho `docs/operations_20261021.md`. Backend FastAPI chay trong 1 container,
1 process uvicorn (scheduler ingest hang gio chay trong process, khong duoc chay
trung). SQLite (WAL) va model nam tren volume.

## 1. Chuan bi

```bash
cd sky_weather_app
cp .env.example .env          # sua ADMIN_TOKEN, CORS_ORIGINS...; KHONG commit .env
# Tren Linux: thu muc data phai ghi duoc boi UID trong container (mac dinh 10001)
sudo chown -R 10001:10001 backend/data      # hoac dat APP_UID=$(id -u) trong .env
docker compose up -d --build
docker compose ps             # STATUS phai la "healthy" (HEALTHCHECK goi /live)
curl -s http://127.0.0.1:8000/ready         # 200 khi du lieu moi + model san sang, 503 neu chua
docker compose logs -f api
```

- `backend/data` -> `/app/data` (doc/ghi): `weather.db`, `weather.db-wal`,
  `history/`, `locations/` (seed). Image khong chua DB/backup/model (`.dockerignore`).
- `backend/models` -> `/app/models` (chi doc).
- Cong chi bind `127.0.0.1:8000`; ra Internet qua reverse proxy HTTPS.
- Mo rong: them replica voi `INGEST_ENABLED=0`, chi giu dung 1 instance bat ingest.
  Rate limit luu trong bo nho tung process, nen moi replica co bucket rieng.
- Cap nhat: `docker compose up -d --build`; dung container co 15s de scheduler dung.

## 2. Reverse proxy HTTPS va log rieng tu (02/11/2026)

Dung [deploy/nginx.conf.template](../deploy/nginx.conf.template) lam **toan bo**
`/etc/nginx/nginx.conf` tren Linux, khong include no vao config mac dinh.
Sao luu config cu, thay placeholder trong ban copy (khong chua secret trong repo):

| Placeholder | Gia tri operator phai chon |
|---|---|
| `__TLS_LISTEN_ADDRESS__` | Dia chi IP:cong duoc phep lang nghe, vd `127.0.0.1:8443` cho local; chi bind public sau khi duyet firewall/domain. IPv6 dung `[dia-chi]:cong`. |
| `__SERVER_NAME__` | Domain TLS thuc te. |
| `__TLS_CERTIFICATE_PATH__` | Duong dan tuyet doi den certificate/full chain tren server. |
| `__TLS_PRIVATE_KEY_PATH__` | Duong dan tuyet doi den private key tren server, quyen doc han che. Khong paste noi dung key. |

Giu nguyen cac bien nginx `$...`; khong chay `envsubst` khong gioi han vi no
co the xoa cac bien log/proxy. Chuan bi certificate hop le va thu muc
`/var/log/nginx` voi quyen ghi cho nginx, khong world-readable. Template khong
tu cap certificate, khong mo cong HTTP/redirect/ACME. Gia han certificate can
quy trinh rieng. Upstream mac dinh chi `127.0.0.1:8000`; neu doi `API_PORT`,
doi upstream tuong ung trong ban copy. Template danh cho proxy chay tren host;
loopback trong container proxy khong tro toi container API.

Truoc khi operator ap dung (lenh sau chi kiem tra, khong start/reload):

```bash
sudo nginx -t -c /etc/nginx/nginx.conf
sudo nginx -T -c /etc/nginx/nginx.conf   # kiem tra config thuc te, khong chia se output neu co secret
```

Chinh sach duoc thuc thi boi template, khong chi la khuyen cao:
- Duy nhat `privacy_metrics`: thoi gian, status, so byte response va thoi gian
  xu ly. Khong ghi IP, URI/path, query, header (Authorization/Cookie/Referer),
  request body, email, GPS hay token. Khong dung `$request`, `$request_uri`,
  `$uri`, `$args`, `$request_body` hay format `combined`, ke ca cho loi/405.
- `error_log /dev/null crit` o cap goc: huy error log, vi error log nginx co
  the chua request target ngay ca khi access log da an query. Doi lai mat
  chan doan proxy chi tiet; theo doi status/latency, uptime va `/ready`.
  Khong bat debug hay doi error log sang file/stderr/syslog tren luong that.
- Khong include vhost/log config khac, khong them access/error log override o
  server/location, khong mirror request. `nginx -T` phai chi ra dung policy
  tren cho moi listener. Neu may chia se nhieu vhost, can review rieng toan bo
  config; template nay khong chung minh config ghep la an toan.
- Template khong sua/xoa log cu. Operator can gioi han quyen, retention va
  xu ly log cu theo policy; kiem tra rieng CDN/WAF/load balancer/APM/custom
  logger, tat request/query/body/header capture ca tren luong loi. Uvicorn
  filter khong bao ve cac lop nay. Khong coi body buffering/temp file la log
  da duoc bao ve boi policy nay; review quyen/temp storage rieng neu can.

Khong dung lai vi du Caddy/nginx mac dinh truoc day: chung khong dam bao
chinh sach log nay. Access log tong hop khong du de phan tich theo endpoint;
do la danh doi co chu y de khong luu request data.

Luu y:
- `TRUST_PROXY=1` chi khi API khong the truy cap truc tiep (bind 127.0.0.1 nhu compose).
  Rate limit lay muc **phai nhat** cua `X-Forwarded-For` (do proxy them vao).
- Sau proxy bat buoc dat `ADMIN_TOKEN`; khong co token, `/admin/*` tu choi moi request co header proxy.
- Lockout dang nhap van tinh theo peer socket (la proxy) cong email; khong bi rate limit thay the.
- App Flutter build voi `--dart-define=API_BASE_URL=https://api.weather.example.com`.

### Web va API cung dia chi (26/10/2026)

Web release mac dinh goi API cung origin, khong can nguoi dung sua Cai dat.
Khong co prefix /api: /weather, /auth, /live... giu nguyen contract cu.

```powershell
# Local: mot process, tu mo trinh duyet. Port khac khong doi cau hinh frontend.
python tool/run_web.py --build --open
```

Tren server: build web khong truyen API_BASE_URL; copy build/web len may chu,
dat WEB_DIST=/var/www/sky-weather, chay backend nhu cu. Proxy HTTPS o tren
chuyen toan bo request (ca HTML/assets/API) ve backend. Khong doi port API
trong Flutter khi doi domain. WEB_DIST sai/thieu index.html se bao loi ro rang;
khong dat WEB_DIST thi backend van la API-only. Chi phuc vu thu muc build/web,
khong tro WEB_DIST vao thu muc repo hay backend/data.

Docker: them bind mount ./build/web:/app/web:ro va WEB_DIST=/app/web vao service
api sau khi build; thu muc web phai ton tai tren host. Khong build Flutter trong
container Python. Chua kiem chung Docker daemon trong dot nay.

Native Android/iOS: build API_BASE_URL=https://<domain-web> (hoac domain API
rieng dang chay). Backend phai online; loopback/emulator khong dung tren may
that. Khong the tu tao mot backend public bang cach doi URL trong code.

## 3. Bien moi truong

| Bien | Mac dinh (code) | Y nghia |
|---|---|---|
| `HOST` | `127.0.0.1` (image: `0.0.0.0`) | Dia chi bind cua `python main.py`. |
| `PORT` | `8000` | Cong lang nghe trong container. |
| `RELOAD` | `0` | `1` = auto-reload, chi dev. |
| `ENABLE_DOCS` | `1` (image: `0`) | `0` tat `/docs`, `/redoc`, `/openapi.json`. |
| `ADMIN_TOKEN` | (trong) | Header `X-Admin-Token` cho `/admin/*`; bat buoc sau proxy. |
| `CORS_ORIGINS` | `*` | Danh sach origin phan tach dau phay (vd `https://weather.example.com,http://localhost:8080`). Mobile khong gui Origin nen khong bi anh huong. |
| `CORS_ALLOW_CREDENTIALS` | `0` | Chi co hieu luc voi danh sach origin cu the, khong bao gio cung `*`. App dung `Authorization: Bearer`, khong cookie, nen de `0`. |
| `RATE_LIMIT_PER_MINUTE` | `120` | Token bucket theo IP: burst = N, hoi N/60 token/giay; vuot -> 429 + `Retry-After`. Bo qua `/live`, `/health`, `/ready`. Dat `0` de tat. |
| `TRUST_PROXY` | `0` | `1` = lay IP client tu `X-Forwarded-For` (muc cuoi). |
| `INGEST_ENABLED` | `1` | `0` tat scheduler ingest trong process (replica phu, test). |
| `MAINTENANCE_ENABLED` | theo `INGEST_ENABLED` | Worker retention doc lap request: chay khi startup, kiem tra moi 300 giay, chi xoa mot lan/ngay/DB sau thanh cong; loi se thu lai. Chi bat tren mot replica ghi duoc. |
| `EXTERNAL_FORECAST_ENABLED` | `0` | `1` cho phep lay du bao tham chieu ben ngoai. |
| `ALERT_FAILURE_THRESHOLD` | `3` | So lan ingest that bai lien tiep (error/partial, khong tinh busy) truoc khi canh bao; `0` tat. |
| `ALERT_STALE_HOURS` | `6` | Canh bao khi gio moi nhat cua chuoi mac dinh cu hon N gio (cung nguon `data_age_hours` cua `/health`); `0` tat. |
| `ALERT_WEBHOOK_URL` | (trong) | Neu dat: POST JSON canh bao (timeout 5s, thread rieng, loi chi ghi WARNING). |
| `LOG_LEVEL` | `INFO` | `DEBUG`/`INFO`/`WARNING`/`ERROR`; gia tri sai -> `INFO`. Format log cua app: `thoi-gian MUC logger thong-diep` (log access cua uvicorn giu format mac dinh). |
| `LONG_RANGE_MODEL_DIR` | `models/long_range` | Thu muc artifact model dai han. |
| `API_PORT`, `APP_UID` | `8000`, `10001` | Chi dung trong compose: cong host, UID user trong image. |

## 4. Canh bao ingest

Sau moi luot ingest (tru busy) scheduler kiem tra 2 dieu kien; moi su co chi
canh bao 1 lan, khi het loi ghi `ingest_alert_resolved` (INFO) va san sang canh bao lai.

```
2026-10-21 10:21:00,123 ERROR ingest.alert {"event": "ingest_alert", "kind": "consecutive_failures", "at": "...", "last_outcome": "error", "consecutive_failures": 3, "failure_threshold": 3, "data_age_hours": 2.1, "stale_hours": 6}
```

`kind` = `consecutive_failures` hoac `stale_data`. Webhook nhan dung JSON nay.
Giam sat ngoai nen poll `/ready` (503 khi du lieu cu/thieu) — scheduler chet hoan toan
thi khong tu canh bao duoc.

## 5. Sao luu SQLite

Khong copy rieng `weather.db` khi API dang chay (WAL). Dung backup API:

```bash
mkdir -p backups
docker compose exec api python -c "import sqlite3;s=sqlite3.connect('/app/data/weather.db');d=sqlite3.connect('/app/data/backup.db');s.backup(d);d.close()"
mv backend/data/backup.db backups/weather-$(date +%Y%m%d-%H%M).db
```

Hoac tren host co `sqlite3`: `sqlite3 backend/data/weather.db ".backup backups/weather-$(date +%F).db"`.
Kiem tra ban sao: `sqlite3 backups/<file>.db "PRAGMA integrity_check"`. Luu ban sao
ngoai may chu, xoay vong (vd 7 ngay + 4 tuan). Khoi phuc: `docker compose stop api`,
chep ban sao thanh `backend/data/weather.db`, xoa `weather.db-wal`/`-shm` cu, `docker compose start api`.
`data/history/cells_history.db` (~1 GB) it thay doi, sao luu tuong tu nhung thua hon.

## 6. Trang thai kiem chung

- Lich su 21/10: `docker compose config` hop le. Docker daemon tren may dev khong chay luc viet tai lieu,
  nen **chua build/chay thu image**; can `docker compose build` truoc khi dung that.
- Test: `backend/tests/test_deploy_ops.py` (CORS, rate limit, canh bao, LOG_LEVEL).
- Patch proxy 02/11: test policy doc lap, khong import backend/DB:
  `py -B -m unittest discover -s backend/tests -p test_proxy_config.py -v`.
  Test tinh kiem allowlist log, error-log sink, TLS placeholder, loopback va
  ghi de X-Forwarded-For; khong thay the `nginx -t` hoac kiem tra log thuc te.
- Ket qua dot patch: 4 test tren PASS; `py -B -m ruff check --no-cache
  backend/tests/test_proxy_config.py` PASS. Khong chay full backend suite,
  khong import app hay mo DB that trong cac check nay.
- Follow-up 02/11: Docker Desktop da khoi dong; image backend build/chay duoc
  voi volume DB thu rieng va model read-only, /ready200. Nginx stable-alpine
  da qua nginx -t; proxy HTTPS local tin cay cert thu, live200/reset422.
  Query/body sentinel khong co trong app/proxy/access-file logs. Thu48requests
  concurrency4 deu200 (warm/local, khong la production capacity).
  Chi tiet, artifacts va gioi han: docs/operations_20261102.md.
- SMTP that, Android/iOS that va rollout production van chua kiem chung;
  day la template/readiness patch, **khong phai da deploy production**.

## 7. Khoi phuc mat khau qua email (26/10/2026)

- Cac bien `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY`, `SMTP_FROM`, `SMTP_USERNAME`, `SMTP_PASSWORD` co trong `.env.example`. Compose truyen qua env_file; Python truc tiep can inject vao process, khong tu doc .env.
- Chi ho tro STARTTLS (thuong 587) hoac ssl/TLS truc tiep (thuong 465), luon xac minh chung chi. Khong tat TLS verification. Giu password trong secret store, khong dua vao repo/chat.
- `POST /auth/password-reset/request` tra 202 giong nhau cho email ton tai/khong ton tai; SMTP chua cau hinh tra 503 cho moi dia chi. Ma gui trong email, han 15 phut; khong log hay tra ma qua API.
- `POST /auth/password-reset/confirm` nhan email/token/password; ma dung mot lan. Thanh cong thu hoi tat ca phien. Co gioi han theo email, nguon va so lan thu ma.
- Test dung SMTP gia, chua gui email that. Sau deploy can kiem tra hop thu/thu rac, sender duoc uy quyen va reset tai khoan test. Loi SMTP sau khi chap nhan request khong doi public response (tranh tiet lo tai khoan); token gui that bai bi huy.
- Backup/restore SQLite WAL da thu tren DB tam bang `backend/tests/test_backup_restore.py`; khong thay the dien tap tren server. Docker smoke local02/11 co ket qua o muc6, khong phai production rollout.

## 8. API va bao ve log (02/11/2026)

- Trien khai app/backend cung dot: tim duong dung `POST /route` voi JSON;
  `GET /route` va `/route/` tra 405, khong con nhan toa do qua query.
- Hai endpoint password-reset gioi han 4096 byte tren stream thuc te truoc
  khi parse JSON (vuot tra 413, JSON sai tra 422), khong tin Content-Length.
- Filter `uvicorn.access` mac dinh loai query string khoi request target.
  Reverse proxy/CDN/APM/custom logger phai cau hinh rieng: khong ghi query
  hay request body chua GPS, password va reset token. Filter app khong
  bao ve log o cac lop nay. OSRM van nhan toa do de tinh duong.

### Checklist chuyen app/backend sang POST

1. Chuan bi backend moi va app/web moi trong cung dot rollout. Mobile cu
   dung GET se nhan 405: thong bao/yeu cau cap nhat, khong rollback rieng
   backend ve GET va khong them GET fallback chua GPS vao client/proxy.
2. Client gui `POST /route`, `Content-Type: application/json`, body gom
   `from_lat`, `from_lon`, `to_lat`, `to_lon`, tuy chon `depart_at`, `profile`.
   Khong dat toa do/email/password/token tren URL; proxy chuyen nguyen
   method/body, khong rewrite sang GET. Giu `/route/along-weather` la POST.
3. Truoc traffic that: thay placeholder, kiem tra `nginx -t`/`nginx -T`,
   giu API chi loopback, cau hinh ADMIN_TOKEN va proxy trust nhu muc 2.
   Tat capture request o tat ca lop CDN/APM/WAF va access/error logger khac.
4. Tren staging voi du lieu gia: thu POST hop le (co the goi OSRM, khong
   dung GPS that), GET `/route` va `/route/` phai 405, JSON sai 422 va reset
   >4096 byte phai 413. Gui query/body/header sentinel gia tren ca request
   thanh cong va loi, ke ca duong dan khong ton tai; kiem tra moi log chi co
   metadata, khong sentinel/query/body/token. Khong echo secret trong curl
   verbose, terminal history hay bao cao. Local TLS/query/body smoke da chay;
   staging/CDN/APM/WAF va route OSRM that van can kiem o moi truong dich.
5. Kiem tra web/native qua HTTPS, route va reset account test voi SMTP that
   (hop thu/thu rac, ma mot lan, thu hoi session). Kiem tra Docker build,
   health/readiness va backup/restore tren moi truong dich truoc rollout.
   Device/SMTP va Docker tren moi truong dich van la viec operator phai lam;
   test tinh/mocked khong chung minh he thong da san sang production.

## 9. Nen ban do (02/11/2026)

- App dung OSM Standard; neu mot tile khong tai duoc, flutter_map thu
  HOT do OpenStreetMap France host. Ca ban do thoi tiet va tuyen dung chung
  `lib/config/map_tiles.dart`; attribution hien ca OSM/HOT/OSM France.
- Day la community tiles: chi dung cho app/site cong khai, mien phi, phi loi
  nhuan, luu luong vua phai; khong coi la dich vu co SLA hay CDN production.
  Chinh sach: https://www.openstreetmap.fr/usage/ va
  https://operations.osmfoundation.org/policies/tiles/. Khong bulk download.
- Truoc commercial/high-traffic deployment, chon nha cung cap co giay phep
  va quota phu hop; build Flutter voi `--dart-define=MAP_TILE_URL=...`,
  `--dart-define=MAP_TILE_FALLBACK_URL=...`,
  `--dart-define=MAP_TILE_ATTRIBUTION=...` va
  `--dart-define=MAP_TILE_LICENSE_URL=...`. Fallback rong se tat nguon du phong.
  Day la compile-time config, khong phai bien backend `.env`. Dung URL XYZ
  HTTPS zoom toi da19 va attribution dung dieu khoan nha cung cap.
- Khong hardcode IP, tat TLS hay doi DNS may. App van hien tuyen/o thoi tiet
  neu hai nguon deu loi; tuyen co thong bao va nut thu lai, ban do thoi tiet
  thu lai nen khi bam lam moi. Tile requests tiet lo vung ban do dang xem
  cho nha cung cap; khong them ghi log GPS hay proxy tile qua backend.
- Mau xanh duong tren tuyen AI chi la it kha nang mua theo cac chi so dang
  co, khong phai an toan hay da loai tru dong/gio giat. Xam van la thieu
  du lieu; khong suy ra0mm/0% tu null. Khong thay doi model/nguon du bao.
