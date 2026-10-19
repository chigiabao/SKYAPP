# Nâng cấp dự báo riêng 1–168 giờ

## Phạm vi và trạng thái 19/10/2026

Yêu cầu mới nhất: dùng mô hình do nhóm huấn luyện cho dự báo live theo giờ,
ngày, bản đồ và dọc tuyến; không âm thầm thay bằng NWP ngoài hay khí hậu.
Tiếp tục hoàn thiện Home responsive, nguồn/lỗi rõ ràng và giảm chuyển động.
Bổ sung sau review: xác suất mưa ngày AI phải để `null` cho đến khi có mô hình
và hiệu chuẩn sự kiện ngày riêng; replay map phải qua guard chống rò rỉ.
Coverage tuyến đường đã có test: thiếu dự báo hoặc thiếu chỉ số nguy cơ
không được diễn giải là an toàn; AI riêng không dự báo dông/gió giật.

Tài liệu đối chiếu source và artifact hiện có; bằng chứng chạy DB thật bên dưới
do leader bàn giao. Worker tài liệu không chạy code, test, ingest hoặc train.
Leader đã chạy lại backend: **290 test đạt**; log
`build/resume-backend-tests-final.log` (log cục bộ, không đưa lên Git).
Chưa xác minh đầy đủ trên thiết bị thật; số test v3 cũ vẫn là lịch sử.

## Triển khai và artifact đã có

- `backend/long_range_model.py`: tạo đặc trưng lịch sử và suy luận direct
  từng horizon thật từ 1 đến 168 giờ, không lặp dự báo 1/3/6h để kéo dài.
- `backend/scripts/train_long_range.py`: train và đánh giá trên 67 ô thật,
  6 mục tiêu: `temperature`, `humidity`, `precipitation_mm`, `wind_speed`,
  `cloud_cover`, `rain_probability`. Mỗi mục tiêu có một booster dùng horizon
  làm đặc trưng; không phải 168 model riêng, không dùng nhãn giả đệ quy.
- `backend/models/long_range/metadata.json` và `evaluation.json` cùng sáu file:
  `temperature.txt`, `humidity.txt`, `precipitation_mm.txt`, `wind_speed.txt`,
  `cloud_cover.txt`, `rain_probability.txt`.

| Bằng chứng metadata | Giá trị |
| --- | --- |
| Phiên bản | `lgbm-direct-168h-20261019T105854Z` |
| Thời điểm train | `2026-10-19T10:58:54.877773+00:00` |
| `trained_through` | `2024-12-24T16:00:00+07:00` |
| `fit_labels_through` | `2024-06-30T21:00:00+07:00` |
| `selection_labels_through` | `2024-12-24T16:00:00+07:00` |
| Tài nguyên đo được của lượt train | 39,16 giây; peak RSS 259,9 MiB; 2 luồng |
| Số mẫu train / validation / test mỗi mục tiêu | 45.024 / 11.256 / 11.256 |

39,16 giây (~39,2) và 259,9 MiB (~260) là số đã ghi nhận, không phải cam kết
tài nguyên cho lượt chạy/máy khác. Lệnh tái lập, chạy từ `backend/`:

```bash
python scripts/train_long_range.py --train --max-seconds 180
```

Luồng `/weather/ai-forecast` v3 ngắn hạn và pipeline `/admin/retrain` v3 vẫn
riêng biệt; không coi train/retrain v3 là cập nhật model long-range.

## Nguồn dữ liệu và chống rò rỉ

Metadata ghi nguồn từng ô là `historical-forecast-api` trong
`backend/data/history/cells_history.db`. Đây là **đầu ra lịch sử của mô hình
thời tiết bên ngoài, không phải đo trạm**. Mô hình riêng học các nhãn đó;
tự huấn luyện không đồng nghĩa tự có quan trắc độc lập.

| Split theo giờ địa phương (+07) | Bắt đầu | Kết thúc |
| --- | --- | --- |
| Train | 01/01/2021 00:00 | 30/06/2024 23:00 |
| Validation | 08/07/2024 00:00 | 24/12/2024 23:00 |
| Test | 01/01/2025 00:00 | 16/10/2026 23:00 |

`split_masks` yêu cầu issue và **issue+168h** cùng nằm trong split tương ứng,
kể cả khi mẫu chỉ chọn horizon ngắn hơn. Có khoảng cách 168 giờ giữa các
split; không refit trên validation/test. Validation dùng chọn iteration nên
`trained_through` bao gồm nhãn chọn mô hình, không chỉ nhãn fit.

Sampling chọn issue không hoàn lại, seed 42, stride 5; mỗi ô có 672 mẫu train,
168 validation và 168 test, cân bằng các horizon thật. Mỗi horizon test chỉ
có 67 mẫu; mỗi nhóm ngày có 1.608 mẫu. Không phải đánh giá toàn bộ mọi giờ
trong DB và không có spatial holdout độc lập của lượt train giới hạn này.

DB chưa có issue-vintage/thời điểm dữ liệu thực sự sẵn có; chia thời gian đúng
không chứng minh đầu vào đã có sẵn khi dự báo trong vận hành. Đây là đánh giá
held-out/hindcast trên nhãn mô hình, không phải bằng chứng dự báo quan trắc
hoặc backtest vận hành hoàn chỉnh.

## Kết quả held-out thực tế

Nguồn: `backend/models/long_range/evaluation.json`, nhánh `test`.
Các số làm tròn dưới đây là lỗi; **thấp hơn tốt hơn**, không phải phần trăm
chính xác. Mỗi mục tiêu overall có 11.256 mẫu, ngày 7 có 1.608 mẫu, horizon
145–168h từ issue (không phải ngày lịch thứ bảy của response daily).

| Mục tiêu / metric | Overall AI | Persistence | Khí hậu | Ngày 7 AI | Persistence ngày 7 | Khí hậu ngày 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Nhiệt độ MAE (°C) | 0,9418 | 2,9331 | 0,9941 | 0,9719 | 3,0731 | 1,0062 |
| Độ ẩm MAE (điểm %) | 5,7469 | 14,2408 | 6,0827 | 6,0456 | 15,0752 | 6,1314 |
| Lượng mưa MAE (mm/giờ) | 0,3441 | 0,4666 | 0,3725 | 0,3267 | 0,4694 | 0,3478 |
| Tốc độ gió MAE (km/h) | 3,2065 | 4,5869 | 3,3081 | 3,2723 | 4,9277 | 3,2267 |
| Độ phủ mây MAE (điểm %) | 21,5011 | 27,0518 | 24,8836 | 22,0875 | 28,2761 | 25,2079 |
| Mưa giờ Brier | 0,129114 | 0,272033 | 0,130392 | 0,126045 | 0,284204 | 0,124295 |

Cả sáu mục tiêu overall thắng hai baseline theo metric chính, nhưng không
thắng mọi horizon/ô/ngày hay mọi metric:

- **Gió ngày 7 kém khí hậu**: MAE 3,272264 so với 3,226698 km/h;
  RMSE 4,206572 so với 4,137860 km/h. Ngày 6 cũng không thắng khí hậu theo MAE.
- **Mưa giờ ngày 7 kém khí hậu theo Brier**: 0,126045 so với 0,124295;
  log-loss AI 0,396307 so với khí hậu 0,431203 vẫn tốt hơn. Overall log-loss
  AI 0,404832 so với khí hậu 0,438608. Ngày 4 cũng không thắng khí hậu theo Brier.
- **Nhiệt độ ngày 7 chỉ hơn nhẹ khí hậu**: MAE 0,971923 so với 1,006242 °C;
  RMSE 1,291255 so với 1,309167 °C. Overall RMSE 1,248364 so với 1,309272 °C.
  Không suy rộng thành bảo đảm chính xác 7 ngày ngoài thực tế.
- Mây overall có MAE tốt hơn khí hậu nhưng RMSE **33,003293 kém 31,017369**;
  không tuyên bố vượt baseline ở mọi thước đo. Độ ẩm ngày 6 cũng kém khí hậu
  theo MAE dù overall tốt hơn.

## Hợp đồng API live và replay

- `routers/weather.py`: live `/weather/hourly`, `/weather/daily`, map và
  `routers/route.py` dùng chung chuỗi tương lai từ AI riêng. Không fallback
  forecast ngoài hoặc khí hậu. `source=observed` là nhãn hợp đồng cho giờ đầu
  vào hiện có, **không biến dữ liệu mô hình thành số đo trạm**; tương lai là `ai`.
- Current analysis ngoài vẫn có chủ đích. Model cần 48 giờ lịch sử liên tục,
  ô đã train, issue sau `trained_through`; phục vụ live còn yêu cầu đầu vào
  mới trong 3 giờ. Horizon tối đa 168h tính từ issue, không phải vô điều kiện
  168h tính từ lúc gọi. Query daily nhận đến 14 ngày không có nghĩa model phủ
  14 ngày; thiếu phủ trả 503 thay vì bịa hoặc đổi nguồn.
- `/weather/bundle`: giữ `current` nếu có; hourly/daily bị 503 thành `[]` ở
  phần tương ứng và `forecast_error`. `ai_forecast` v3 có `ai_error` riêng;
  không trộn hai lỗi. Không bảo đảm bundle thành công khi chính current thiếu.
- `/weather/forecast-status`: `experimental=true`, trạng thái/capabilities
  artifact và tóm tắt test overall/theo ngày. Artifact available không bảo đảm
  đầu vào mọi ô đều mới hay chứng minh kỹ năng vượt baseline ở mọi nơi.
- Rain probability giờ chưa hiệu chuẩn. Daily AI có
  **`rain_day_probability = null`**, không max các xác suất giờ thành xác suất
  sự kiện ngày. Cần train và hiệu chuẩn riêng sự kiện tổng mưa ngày ≥1 mm
  trước khi công bố phần trăm ngày. `precipitation_total` vẫn là tổng lượng
  mưa giờ dự đoán (và giờ đầu vào đã có trong ngày), không phải xác suất.
- UV, AQI, gió giật tương lai chưa được mô hình hỗ trợ: `null`, không gán 0
  hoặc kéo giá trị hiện tại thành dự báo. Tổng hợp daily có thể còn giá trị
  của giờ đầu vào hôm nay; đó không phải dự báo các giờ tương lai.
- Bundle replay có `forecast_provider=historical_reference`: tham chiếu
  lịch sử/khí hậu, **không phải backtest**. Outlook map replay nay gọi
  `long_range_model.predict` có guard; issue trước hoặc bằng `trained_through`
  bị từ chối và không có AI outlook, không dùng dự đoán v3 legacy bị rò rỉ.
  Issue sau mốc đó vẫn phải đáp ứng điều kiện dữ liệu/model, không tự bảo đảm
  outlook sẽ có hoặc replay trở thành backtest.
- Route dùng AI riêng; giữ geometry khi model không khả dụng, trả rõ
  `forecast_available` và `hazard_assessment_complete`. Test kiểm tra AI riêng
  không nhận coverage nguy cơ đầy đủ ngay cả khi có mã trời/gió giả lập.
  Đây là kiểm chứng hợp đồng phần mềm, không chứng minh tuyến đường an toàn.

## Ingest và bằng chứng DB thật

`backend/ingest.py` mặc định đọc `EXTERNAL_FORECAST_ENABLED=0`: không tải
dự báo tương lai ngoài; vẫn cập nhật đầu vào thời tiết và AQ từ bên ngoài.
Bật `1` chỉ cho phép thu thập dự báo tham chiếu, không làm live chuyển nguồn.
`--forecast-only` yêu cầu opt-in này. Không hứa hẹn thời hạn giữ dữ liệu,
forecast vintage hoặc artifact vượt những gì đã được kiểm chứng.

Theo bằng chứng leader bàn giao, **khoảng 18:06 ngày 19/10/2026 (+07)** đã
chạy thật `ingest.py --location tsn` trên DB thật. Đầu vào `tsn` đến **18:00**;
bundle đã kiểm tra có **48 hourly + 7 daily**, nguồn `observed` và `ai`,
`forecast_error=None`. Đây là snapshot của lần kiểm tra đó, không phải cam
kết luôn mới hoặc bằng chứng ingest toàn vùng. **Các ô khác vẫn có thể cũ
cho đến khi ingest**. Worker tài liệu không chạy lại lệnh này.

## UI và xác minh còn lại

Source Home có overview/focus theo kích thước màn hình; mobile có điều hướng
gắn nhãn, desktop có rail; tab **Dự báo / Điều kiện**; trạng thái lỗi/nguồn
và hỗ trợ reduced motion. Luồng chính không được gán nguồn fallback giả.
Đây là mô tả triển khai, không phải xác nhận UI đã vượt mọi kiểm tra.

- Backend đã kiểm tra replay guard, cache đổi revision, daily null, route
  thiếu coverage và metadata không quảng bá frame khi lịch sử đầu vào lỗi.
- Browser đã kiểm tra 390x844, 375x667, 844x390, 1440x960 với reduced motion;
  không có lỗi JavaScript, bundle 48 giờ/7 ngày AI. Ảnh/log trong
  `build/self-forecast-ui/`. Flutter có test chữ 200% sáng/tối và daily null
  không hiện hoặc đọc phần trăm giả; xem kết quả cuối trong bàn giao.
- Snapshot backend ngày 19/10/2026 (+07): cả 67 ô có dữ liệu
  đầu vào 18:00 và outlook AI; khung 0/1/24/72h sau warm-up mất 137–143 ms.
  Log `build/resume-live-map.log`; không phải phép đo thiết bị hoặc ingest mới.
- Chưa chạy golden, TalkBack/VoiceOver thật, FPS/pin điện thoại hay xác minh
  ký iOS/App Groups. Mưa giờ chưa hiệu chuẩn; giới hạn dữ liệu/model còn nguyên.
