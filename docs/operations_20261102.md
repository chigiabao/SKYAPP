# Kiem Chung Van Hanh 02/11/2026

## Ket Qua Moi

- Ingest that tren snapshot WAL-aware cua SQLite: 67/67 series thanh cong,
  them871rows; timestamp moi nhat02/11 01:00 (Asia/Ho_Chi_Minh). Khong ingest
  vao DB goc, khong training/promotion, EXTERNAL_FORECAST_ENABLED=0.
- /ready200,68/68cells fresh, model available. /weather/bundle200 co48hourly,
  7daily, forecast_provider=sky_weather_ai, khong forecast_error. Tat ca gio
  tuong lai va daily deu source=ai. /weather/ai-forecast200, current_inference.
  Artifact short-range lgbm-hcmc-global-v3-20261023; khong doi model phuc vu.
- Chromium390x844: Home hien cap nhat01:00, du bao theo gio/7ngay; map hien
  observed01:00 khac gio xem. Anh/API o build/ops-live-20261102. Snapshot
  la du lieu that tai thoi diem fetch, khong phai dich vu ingest lien tuc.
- Docker Desktop duoc khoi dong; image sky-weather-api:ops-20261102 build
  va chay thanh cong, user app (khong root). DB trong volume rieng,
  models mount read-only. /live,/ready,/weather/bundle200.
- Thu tai nhe48requests, concurrency4, tat ca200, median0.078s,p950.287s,
  max0.301s. Day la warm/local smoke, khong phai capacity/SLA production.
- Mua ban do nen: tile.openstreetmap.org bi DNS NXDOMAIN tren may nay.
  Khong doi DNS, hardcode IP, thay provider, proxy tile hay tat TLS.
  Map weather grid van hien va canh bao mat nen; chua xac nhan tiles that.

## Bao Tri Va Proxy

- Retention worker doc lap HTTP requests, bat cung ingest theo mac dinh;
  MAINTENANCE_ENABLED co the override. Chay startup va kiem tra300s/lantick;
  gate1lan/ngay/DB chi ghi nhan sau transaction thanh cong, loi se thu lai.
  Giu policy feedback365ngay/forecastlog90ngay/account expiry cu.
  Shutdown signal + join toi da5s, khong block vo han; chi bat1replica ghi.
- Test container khong goi API: seed OPS_RETENTION_OLD/KEEP vao volume thu,
  restart voi MAINTENANCE_ENABLED=1; OLD bi xoa, KEEP con. Khong xoa DB that.
- deploy/nginx.conf.template log metrics-only, error_log sink de khong lo
  request target tu nginx. Mat forensic error detail la tradeoff co chu y;
  can giam sat status/readiness/metrics. CDN/APM/WAF phai cau hinh rieng.
- nginx stable-alpine: nginx -t PASS sau thay placeholder bang cert thu.
  TLS smoke tin cay cert local (giu verify): GET live200, malformed reset422.
  Sentinel query/body GPS/token/email/password khong co trong app logs,
  nginx logs va access log file (chi time/status/bytes/duration).
  Cert/key chi de test trong build/, khong dung production.

## Kiem Thu Va Gioi Han

- Backend893passed15skipped (--skip-model-training), focused84passed;
  tool snapshot/runweb12passed; scoped Ruff PASS. Khong sua Dart dot nay,
  Flutter882pass/golden16/contract3 la ket qua dot sua truoc (xem handoff).
- Chi co Windows/Chrome/Edge; khong co Android/iOS that ket noi.
  Khong co SMTP_HOST/FROM/credentials trong process hay .env; chua gui email.
  Chua kiem thong bao nen/device signing/VoiceOver/TalkBack va rollout HTTPS
  tren server that. Can operator cung cap dich vu SMTP va ket noi dien thoai.
- API POST /route can app/backend cung dot; client GET cu se405.
- Preview http://127.0.0.1:8163 chi loopback, snapshot that da refresh1lan,
  scheduler ingest/maintenance off. Khong goi preview la production.
- Independent review tim thay snapshot alias co the ghi DB nguon; da chan
  resolved target/samefile voi ca2nguon va2dich truoc backup/import/startup.
  Regression hardlink/symlink qua CLI tren DB synthetic deu PASS.
