# Hệ thống cảnh thời tiết (lib/ui/weather)

Nền động thay đổi theo thời tiết thật, icon thời tiết và màn hình giả lập.

| File | Vai trò |
|------|---------|
| `weather_scene.dart` | `WeatherScene`, `SceneLayer`, `resolveScene(...)` (hàm map DUY NHẤT), `SceneTheme` (màu, kính, scrim, lớp hiệu ứng) |
| `sun_times.dart` | Giờ mặt trời mọc/lặn theo NOAA, `isDaytime(...)` |
| `weather_background.dart` | `WeatherBackground` (gradient + lớp động + child), `SceneOverride`, `effectiveScene` |
| `weather_icons.dart` | `WeatherIcon` / `WeatherIcon.fromCode` vẽ bằng CustomPainter |
| `painters/` | Mỗi lớp hiệu ứng một painter; trạng thái hạt tạo một lần, không cấp phát Paint/Path mỗi khung |
| `debug/weather_simulator_screen.dart` | "Giả lập thời tiết" (chỉ debug, `WeatherSimulatorScreen.available`) |

## Dùng ở Home

```dart
final isDay = isDaytime(HcmTime.now(), lat: 10.7909, lon: 106.6313);
final resolved = resolveScene(
  weatherCode: code,                 // WMO từ Open-Meteo
  isDay: isDay,
  windSpeedKmh: current.windSpeed,
  visibilityMeters: visibilityM,     // mét
  cloudCover: current.cloudCover?.toDouble(),
);
final scene = effectiveScene(resolved, sceneOverride);
final theme = SceneTheme.of(scene, isDay: isDay);
// Thẻ kính: BoxDecoration(color: theme.glassColor) + BackdropFilter.
WeatherBackground(scene: scene, isDay: isDay, windSpeedKmh: wind, child: ...);
```

Màu chữ trên nền luôn là trắng. Thẻ kính phải dùng `theme.glassColor`
(= `glassTint` với `glassAlpha`): cảnh sáng dùng kính tối nên chữ trắng đạt
≥ 4.5:1 (đã kiểm thử trong `test/ui/weather/scene_theme_test.dart`).

## Bảng resolveScene

| Mã WMO | Cảnh |
|--------|------|
| 0, 1 | clearDay / clearNight |
| 2 | partlyCloudyDay / partlyCloudyNight |
| 3 | overcast nếu mây ≥ 90 %, còn lại cloudy |
| 45, 48 | fog |
| 51, 53, 55 | drizzle |
| 56, 57, 66, 67 | sleet |
| 61, 63, 80, 81 | rain |
| 65, 82 | heavyRain |
| 71, 73, 75, 77, 85, 86 | snow |
| 95, 96, 99 | thunderstorm |
| null / mã lạ | theo cloudCover: < 20 clear, < 60 partlyCloudy, < 90 cloudy, còn lại overcast; không có cloudCover → cloudy |

Ưu tiên: hiện tượng theo mã (mưa, tuyết, dông, sương) > **windy** (gió ≥ 39 km/h)
> **haze** (tầm nhìn < 5000 m) > cảnh cơ bản. Windy/haze chỉ áp dụng cho cảnh
"khô" (clear / partlyCloudy / cloudy / overcast). Ngưỡng: `kWindyThresholdKmh`,
`kHazeVisibilityMeters`, `kOvercastCloudCover`.

## Thêm cảnh mới

1. Thêm giá trị vào `enum WeatherScene` và nhãn trong `WeatherSceneX.label`.
2. Thêm nhánh trong `resolveScene` (kèm dòng trong bảng chú thích) và test trong
   `resolve_scene_test.dart`.
3. Thêm `SceneTheme` vào map `_day` trong `weather_scene.dart`.
4. Thêm hình trong `WeatherIconPainter.paint` (`weather_icons.dart`).
5. Chạy `flutter test test/ui/weather --update-goldens`, xem ảnh trong
   `test/ui/weather/goldens/`, rồi chạy lại không có cờ.

## Chỉnh màu

- `gradient`: 3 điểm dừng (trên / giữa / dưới).
- `overlay`: lớp phủ có alpha, nằm dưới hiệu ứng — dùng để dịu nền sáng.
- `contrastScrim`: lớp đen phủ trên hiệu ứng (0 hoặc 0.12–0.20 với cảnh sáng).
- `glassTint` + `glassAlpha` (0.18–0.22): màu thẻ kính.
- `cloudColor`: màu mây/sương; alpha là độ đặc tối đa một lớp.
- Sau khi đổi, chạy `scene_theme_test.dart`: test kiểm chữ trắng ≥ 4.5:1 trên
  thẻ kính (kể cả 2 lớp mây chồng) và ≥ 3:1 trên nền (chữ lớn).
- Biến thể ban đêm của cảnh dùng chung (rain, fog, windy...) được tạo tự động
  trong `SceneTheme._nightVariant` (pha 55 % với màu đêm).

## Số hạt và tốc độ

| Lớp | Nơi chỉnh | Mặc định |
|-----|-----------|----------|
| Mưa | `RainField.countFor`, `RainPainter._kindSpeed/_kindLen` | 60 / 140 / 280 (phùn / mưa / to), mưa tuyết 130 |
| Tuyết | `SnowField.perLayer`, `SnowPainter._speeds` | 45 / 40 / 30 hạt, 22 / 38 / 60 px/s |
| Sao | `StarField(count:)` | 110 sao, nhấp nháy 1–4 s |
| Sao băng | `ShootingStarSchedule` | mỗi 8–15 s |
| Chớp | `LightningField` | mỗi 5–12 s, lóe 80–150 ms, tắt 400 ms |
| Mây | `_LayerViewState._painter` (layers, density) | mỏng 2 lớp, parallax 3, dày 4 |
| Mặt trời | `SunPainter` | thở 1.0–1.08 / 6 s, tia 60 s/vòng |

Chất lượng tự giảm khi khung hình chậm (build + raster trung bình > 16 ms
trong ~60 khung): `WeatherBackground.qualityScale` 1.0 → 0.6 → 0.35.
`lowPower: true` khóa ở 0.35. `WeatherBackground.resetQuality()` để đặt lại.

## Khả năng truy cập và hiệu năng

- `MediaQuery.disableAnimations` → nền tĩnh, không hạt, đổi cảnh tức thì.
- Ticker dừng khi app vào nền hoặc khi `TickerMode` tắt (tab ẩn).
- Mỗi lớp nằm trong `RepaintBoundary` riêng; painter nhận `repaint:` là đồng hồ
  chung nên không rebuild widget mỗi khung.
- Golden test: `seed` cố định + `debugFixedTime` để vẽ đúng một khung.

## Thêm cảnh mới / chỉnh gradient & hạt

**Thêm cảnh mới (ví dụ "mưa đá")**

1. `weather_scene.dart`: thêm giá trị vào `enum WeatherScene`, nhãn tiếng Việt
   trong `WeatherSceneX.label`, nhánh mã WMO trong `resolveScene` (cập nhật
   bảng chú thích phía trên hàm và bảng ở README này).
2. Khai báo `SceneTheme` trong map `_day`: `gradient` (3 màu trên / giữa /
   dưới), `overlay`, `glassTint` + `glassAlpha` (0,18–0,22), `contrastScrim`,
   `cloudColor`, `accent`, `iconColor`, `statusBar`, `layers` (thứ tự vẽ, phần
   tử đầu nằm dưới cùng), `isBright`. Bản ban đêm được sinh tự động.
3. Nếu cần lớp hiệu ứng mới: thêm vào `enum SceneLayer`, viết painter trong
   `painters/` (tạo trạng thái hạt MỘT lần, không cấp phát Paint/Path trong
   `paint`, nhận `repaint:` là đồng hồ chung) và nối vào `_LayerViewState`
   trong `weather_background.dart`. Lớp có hạt phải nằm trong
   `_particleLayers` để tắt khi "Giảm chuyển động".
4. Vẽ icon trong `WeatherIconPainter.paint` (`weather_icons.dart`).
5. Test: `resolve_scene_test.dart`, `scene_theme_test.dart` và
   `test/glass_contrast_test.dart` (chữ trắng / chữ phụ / màu nhấn trên thẻ
   kính phải ≥ 4,5:1 sau khi chồng lớp). Cập nhật golden:
   `flutter test test/ui/weather --update-goldens`, xem ảnh rồi chạy lại.
6. Kiểm tra bằng màn hình "Giả lập thời tiết" (bản debug: nhấn giữ tên thành
   phố ở Home hoặc Cài đặt → Gỡ lỗi → Giả lập thời tiết).

**Chỉnh gradient / kính**

- Sửa 3 màu `gradient`; cảnh sáng thì tăng `contrastScrim` (0,12–0,20) hoặc
  `overlay` thay vì đổi màu chữ — chữ luôn trắng.
- Màu chữ phụ, tiêu đề thẻ, màu nhấn, màu "mưa" trên kính KHÔNG đặt tay: lấy
  từ `GlassInk.of(context)` (`glass_ink.dart`), tự tăng độ đậm đến khi đạt
  4,5:1 cho từng cảnh. Lớp tối sau phần đầu trang (`headerScrim`) cũng được
  tính tự động.
- Khoảng cách, bo góc, cỡ chữ, thời lượng chuyển động: `design_tokens.dart`.

**Chỉnh hạt (mưa, tuyết, sao, mây)**

- Số hạt: `RainField.countFor`, `SnowField.perLayer`, `StarField(count:)`.
- Tốc độ / độ dài vệt: `RainPainter._kindSpeed`, `_kindLen`,
  `SnowPainter._speeds`.
- Mây: số lớp và độ dày trong `_LayerViewState._painter`; màu / độ đặc theo
  `SceneTheme.cloudColor` (alpha = độ đặc tối đa một lớp).
- Giọt mưa bắn trên mép thẻ: Home đăng ký vị trí thẻ qua `SplashRegistry`
  (`widgets/glass_card.dart`) → `WeatherBackground.splashTargets`, mép trên
  (`SplashEdge.top`); chỉ bật với cảnh mưa / mưa to / dông / mưa tuyết.
- Sau khi chỉnh, mở giả lập, xem số FPS ở cuối màn hình; nền tự hạ chất
  lượng (1,0 → 0,6 → 0,35) khi khung hình chậm.

**Nối cảnh vào app**

Chỉ một nơi tính cảnh: `app_scene.dart` (`AppSceneScope` trong
`MaterialApp.builder`). `isDay = isDaytime(provider.nowHcm, lat, lon)` với
toạ độ `ApiConfig.latitude/longitude`; ở chế độ xem lại `nowHcm` là thời
điểm xem lại. `scene = effectiveScene(resolveScene(mã WMO, isDay, gió, tầm
nhìn, mây), SceneOverride)`. Khi đang tải lại (chưa có dữ liệu) giữ cảnh cũ.
Màn hình phụ dùng `GlassPage` để có cùng nền và theme kính.
