/// He thong "canh thoi tiet" (weather scene) cho Sky Weather.
///
/// File nay la NGUON DUY NHAT de:
///   * doi ma thoi tiet WMO (Open-Meteo) + du lieu phu -> [WeatherScene]
///     qua [resolveScene];
///   * lay bang mau / lop hieu ung cua tung canh qua [SceneTheme.of].
///
/// Cac widget ve nen ([WeatherBackground]), icon ([WeatherIcon]) va man hinh
/// Home deu doc tu day, vi vay muon chinh mau hay them canh moi chi can sua
/// file nay (xem README.md cung thu muc).
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Cac canh nen ma app co the hien thi.
///
/// Canh co hau to Day/Night da gan san ngay/dem. Cac canh con lai dung chung
/// cho ca ngay va dem; ban dem chi la bien the toi hon cua cung bang mau
/// (xem tham so `isDay` cua [SceneTheme.of]).
enum WeatherScene {
  clearDay,
  clearNight,
  partlyCloudyDay,
  partlyCloudyNight,
  cloudy,
  overcast,
  drizzle,
  rain,
  heavyRain,
  thunderstorm,
  snow,
  sleet,
  fog,
  haze,
  windy,
}

/// Cac lop hieu ung co the xep chong tren nen gradient.
///
/// Thu tu trong [SceneTheme.layers] chinh la thu tu ve (phan tu dau nam duoi
/// cung). Moi lop tuong ung voi mot painter trong `painters/`:
///
/// | Lop              | Painter                         | Ghi chu                          |
/// |------------------|---------------------------------|----------------------------------|
/// | sun              | SunPainter                      | than mat troi tho 6 s, tia 60 s  |
/// | moonStars        | MoonStarsPainter                | 80-120 sao lap lanh + trang      |
/// | shootingStar     | ShootingStarPainter             | sao bang moi 8-15 s              |
/// | cloudsThin       | CloudLayerPainter (2 lop, thua) | may mong                         |
/// | cloudsParallax   | CloudLayerPainter (3 lop)       | may trung binh, parallax         |
/// | cloudsDense      | CloudLayerPainter (4 lop, day)  | may day, toi                     |
/// | drizzle          | RainPainter(drizzle)            | 60 hat                           |
/// | rain             | RainPainter(rain)               | 140 hat + gon song               |
/// | heavyRain        | RainPainter(heavy)              | 280 hat + gon song               |
/// | lightning        | LightningPainter                | chop 5-12 s                      |
/// | snow             | SnowPainter                     | 3 lop do sau                     |
/// | sleet            | RainPainter(sleet)              | vet mua + hat bang               |
/// | fog              | FogPainter                      | dai suong xam lanh               |
/// | haze             | FogPainter(warm)                | dai mu kho mau am                |
/// | windStreaks      | WindPainter                     | vet gio                          |
enum SceneLayer {
  sun,
  moonStars,
  shootingStar,
  cloudsThin,
  cloudsParallax,
  cloudsDense,
  drizzle,
  rain,
  heavyRain,
  lightning,
  snow,
  sleet,
  fog,
  haze,
  windStreaks,
}

/// Tam nhin (m) duoi nguong nay + troi khong mua -> [WeatherScene.haze].
const double kHazeVisibilityMeters = 5000;

/// Toc do gio (km/h) tu nguong nay + troi khong mua/suong -> [WeatherScene.windy].
/// 39 km/h ~ cap 6 Beaufort ("gio manh").
const double kWindyThresholdKmh = 39;

/// Ma 3 (u am) voi luong may tu nguong nay (%) -> [WeatherScene.overcast].
const double kOvercastCloudCover = 90;

/// Doi du lieu thoi tiet sang canh nen. DAY LA HAM MAP DUY NHAT cua app.
///
/// Bang ma WMO (Open-Meteo) -> canh:
///
/// | Ma WMO  | Y nghia                          | Canh                               |
/// |---------|----------------------------------|------------------------------------|
/// | 0       | Troi quang                       | clearDay / clearNight              |
/// | 1       | Phan lon quang                   | clearDay / clearNight              |
/// | 2       | Co may mot phan                  | partlyCloudyDay / partlyCloudyNight|
/// | 3       | U am                             | overcast neu may >= 90 %, con lai cloudy |
/// | 45, 48  | Suong mu / suong mu dong bang    | fog                                |
/// | 51,53,55| Mua phun nhe/vua/day             | drizzle                            |
/// | 56, 57  | Mua phun bang gia                | sleet                              |
/// | 61, 63  | Mua nhe / vua                    | rain                               |
/// | 65      | Mua to                           | heavyRain                          |
/// | 66, 67  | Mua bang gia                     | sleet                              |
/// | 71,73,75| Tuyet roi nhe/vua/day            | snow                               |
/// | 77      | Hat tuyet                        | snow                               |
/// | 80, 81  | Mua rao nhe / vua                | rain                               |
/// | 82      | Mua rao rat to                   | heavyRain                          |
/// | 85, 86  | Mua tuyet rao                    | snow                               |
/// | 95      | Dong                             | thunderstorm                       |
/// | 96, 99  | Dong kem mua da                  | thunderstorm                       |
/// | null / ma la | Khong co ma                 | theo [cloudCover] (xem duoi), thieu ca hai -> cloudy |
///
/// Fallback khi ma null hoac khong nam trong bang: cloudCover < 20 -> clear,
/// < 60 -> partlyCloudy, < 90 -> cloudy, >= 90 -> overcast; cloudCover null
/// -> cloudy.
///
/// Thu tu uu tien (cao -> thap):
///   1. Hien tuong theo ma: dong > tuyet/mua bang > mua > mua phun > suong mu.
///      Cac canh nay KHONG BAO GIO bi gio hay tam nhin ghi de.
///   2. windy: canh "kho" (clear / partlyCloudy / cloudy / overcast / haze)
///      va [windSpeedKmh] >= [kWindyThresholdKmh]. Gio manh thang mu kho vi
///      gio lon thuong thoi tan mu.
///   3. haze: canh "kho" (clear / partlyCloudy / cloudy / overcast, ke ca khi
///      suy ra tu cloudCover) va [visibilityMeters] < [kHazeVisibilityMeters].
///   4. Canh co ban theo ma / cloudCover.
WeatherScene resolveScene({
  required int? weatherCode,
  required bool isDay,
  double? windSpeedKmh,
  double? visibilityMeters,
  double? cloudCover,
}) {
  final WeatherScene clear = isDay
      ? WeatherScene.clearDay
      : WeatherScene.clearNight;
  final WeatherScene partly = isDay
      ? WeatherScene.partlyCloudyDay
      : WeatherScene.partlyCloudyNight;

  WeatherScene? base;
  switch (weatherCode) {
    case 0:
    case 1:
      base = clear;
    case 2:
      base = partly;
    case 3:
      base = (cloudCover != null && cloudCover >= kOvercastCloudCover)
          ? WeatherScene.overcast
          : WeatherScene.cloudy;
    case 45:
    case 48:
      return WeatherScene.fog;
    case 51:
    case 53:
    case 55:
      return WeatherScene.drizzle;
    case 56:
    case 57:
    case 66:
    case 67:
      return WeatherScene.sleet;
    case 61:
    case 63:
    case 80:
    case 81:
      return WeatherScene.rain;
    case 65:
    case 82:
      return WeatherScene.heavyRain;
    case 71:
    case 73:
    case 75:
    case 77:
    case 85:
    case 86:
      return WeatherScene.snow;
    case 95:
    case 96:
    case 99:
      return WeatherScene.thunderstorm;
    default:
      // Ma null hoac ngoai bang -> suy tu luong may.
      if (cloudCover == null) {
        base = WeatherScene.cloudy;
      } else if (cloudCover < 20) {
        base = clear;
      } else if (cloudCover < 60) {
        base = partly;
      } else if (cloudCover < kOvercastCloudCover) {
        base = WeatherScene.cloudy;
      } else {
        base = WeatherScene.overcast;
      }
  }

  // Den day base chac chan la canh "kho" (khong mua, khong suong).
  if (windSpeedKmh != null && windSpeedKmh >= kWindyThresholdKmh) {
    return WeatherScene.windy;
  }
  if (visibilityMeters != null && visibilityMeters < kHazeVisibilityMeters) {
    return WeatherScene.haze;
  }
  return base;
}

/// Tien ich cho [WeatherScene].
extension WeatherSceneX on WeatherScene {
  /// Nhan tieng Viet (dung cho giao dien va Semantics).
  String get label {
    switch (this) {
      case WeatherScene.clearDay:
        return 'Trời quang';
      case WeatherScene.clearNight:
        return 'Đêm quang';
      case WeatherScene.partlyCloudyDay:
        return 'Có mây';
      case WeatherScene.partlyCloudyNight:
        return 'Đêm có mây';
      case WeatherScene.cloudy:
        return 'Nhiều mây';
      case WeatherScene.overcast:
        return 'U ám';
      case WeatherScene.drizzle:
        return 'Mưa phùn';
      case WeatherScene.rain:
        return 'Mưa';
      case WeatherScene.heavyRain:
        return 'Mưa to';
      case WeatherScene.thunderstorm:
        return 'Dông';
      case WeatherScene.snow:
        return 'Tuyết';
      case WeatherScene.sleet:
        return 'Mưa tuyết';
      case WeatherScene.fog:
        return 'Sương mù';
      case WeatherScene.haze:
        return 'Mù khô';
      case WeatherScene.windy:
        return 'Gió mạnh';
    }
  }

  /// Canh da gan ban dem (clearNight, partlyCloudyNight).
  bool get isNightVariant =>
      this == WeatherScene.clearNight || this == WeatherScene.partlyCloudyNight;

  /// Canh da gan ban ngay (clearDay, partlyCloudyDay).
  bool get isDayVariant =>
      this == WeatherScene.clearDay || this == WeatherScene.partlyCloudyDay;

  /// Co mua / tuyet / dong.
  bool get isPrecipitation => const {
    WeatherScene.drizzle,
    WeatherScene.rain,
    WeatherScene.heavyRain,
    WeatherScene.thunderstorm,
    WeatherScene.snow,
    WeatherScene.sleet,
  }.contains(this);

  /// Doi canh co cap ngay/dem sang ban tuong ung; canh khac giu nguyen.
  WeatherScene withDaytime(bool isDay) {
    switch (this) {
      case WeatherScene.clearDay:
      case WeatherScene.clearNight:
        return isDay ? WeatherScene.clearDay : WeatherScene.clearNight;
      case WeatherScene.partlyCloudyDay:
      case WeatherScene.partlyCloudyNight:
        return isDay
            ? WeatherScene.partlyCloudyDay
            : WeatherScene.partlyCloudyNight;
      default:
        return this;
    }
  }
}

const SystemUiOverlayStyle _lightStatusBar = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Color(0x00000000),
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

/// Bang mau + lop hieu ung cua mot canh. Bat bien, tao duoc bang `const`.
///
/// Thu tu chong lop khi ve (tu duoi len), dung cho ca [WeatherBackground] va
/// cho phep tinh tuong phan [cardBackdropAt]:
///   1. [gradient] (doc, 3 diem dung 0 / 0.5 / 1);
///   2. [overlay] (mau co alpha, lam dịu nen sang);
///   3. [layers] (mat troi, may, mua...) - may dung [cloudColor];
///   4. scrim den alpha [contrastScrim] (chi canh sang);
///   5. the kinh: [glassTint] voi alpha [glassAlpha] (+ blur o phia Home);
///   6. chu trang.
///
/// Moi canh duoc kiem thu de chu trang tren the kinh dat >= 4.5:1 o moi vi tri
/// doc man hinh (ke ca khi co 2 lop may chong nhau phia sau).
@immutable
class SceneTheme {
  const SceneTheme({
    required this.gradient,
    required this.overlay,
    required this.glassAlpha,
    required this.glassTint,
    required this.contrastScrim,
    required this.iconColor,
    required this.accent,
    required this.cloudColor,
    required this.statusBar,
    required this.layers,
    required this.isBright,
  });

  /// 3 mau gradient doc (tren -> giua -> duoi).
  final List<Color> gradient;

  /// Lop phu mau (co alpha) ve ngay tren gradient, duoi cac hieu ung.
  final Color overlay;

  /// Do dac cua the kinh (0.18 - 0.22).
  final double glassAlpha;

  /// Mau nen the kinh. Canh sang dung mau toi (the toi hon nen) de giu tuong
  /// phan; canh toi dung trang (kinh mo).
  final Color glassTint;

  /// Alpha cua lop den phu toan man hinh tren hieu ung: 0 voi canh toi,
  /// 0.12 - 0.20 voi canh sang.
  final double contrastScrim;

  /// Mau chinh cua icon thoi tiet tren canh nay.
  final Color iconColor;

  /// Mau nhan (slider, nut, gia tri noi bat, giot mua cua icon).
  final Color accent;

  /// Mau may / suong (alpha = do dac toi da cua mot lop may hoac dai suong).
  final Color cloudColor;

  /// Kieu thanh trang thai / thanh dieu huong phu hop.
  final SystemUiOverlayStyle statusBar;

  /// Cac lop hieu ung, phan tu dau ve duoi cung.
  final List<SceneLayer> layers;

  /// Nen sang (can scrim + kinh toi de chu trang doc duoc).
  final bool isBright;

  /// Mau the kinh da gom alpha, dung truc tiep cho `BoxDecoration.color`.
  Color get glassColor => glassTint.withValues(alpha: glassAlpha);

  /// Mau scrim da gom alpha.
  Color get scrimColor =>
      const Color(0xFF000000).withValues(alpha: contrastScrim);

  /// Gradient doc san sang dung cho `BoxDecoration`.
  LinearGradient get linearGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: gradient,
    stops: const [0, 0.5, 1],
  );

  /// Mau gradient tai vi tri doc [t] (0 = dinh, 1 = day man hinh).
  Color gradientAt(double t) {
    final double u = t.clamp(0.0, 1.0);
    if (u <= 0.5) return Color.lerp(gradient[0], gradient[1], u * 2)!;
    return Color.lerp(gradient[1], gradient[2], (u - 0.5) * 2)!;
  }

  /// Mau nen phia sau chu (KHONG co the kinh) tai vi tri doc [t]:
  /// gradient + overlay (+ [cloudLayers] lop may) + scrim.
  Color backdropAt(double t, {int cloudLayers = 0}) {
    Color c = Color.alphaBlend(overlay, gradientAt(t));
    for (int i = 0; i < cloudLayers; i++) {
      c = Color.alphaBlend(cloudColor, c);
    }
    return Color.alphaBlend(scrimColor, c);
  }

  /// Mau hieu dung phia sau chu nam TRONG the kinh tai vi tri doc [t].
  Color cardBackdropAt(double t, {int cloudLayers = 0}) =>
      Color.alphaBlend(glassColor, backdropAt(t, cloudLayers: cloudLayers));

  /// So lop may toi da co the chong nhau (dung cho kiem tra tuong phan).
  int get maxCloudOverlap {
    if (layers.contains(SceneLayer.cloudsDense)) return 2;
    if (layers.contains(SceneLayer.cloudsParallax)) return 2;
    if (layers.contains(SceneLayer.fog) || layers.contains(SceneLayer.haze)) {
      return 2;
    }
    if (layers.contains(SceneLayer.cloudsThin)) return 1;
    return 0;
  }

  /// Ty le tuong phan WCAG giua hai mau (1 - 21).
  static double contrastRatio(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    final double hi = la > lb ? la : lb;
    final double lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Noi suy hai bang mau (mau va so thuc). [layers], [statusBar] va
  /// [isBright] lay cua [a] khi t < 0.5, cua [b] khi t >= 0.5.
  static SceneTheme lerp(SceneTheme a, SceneTheme b, double t) {
    if (identical(a, b) || t <= 0) return a;
    if (t >= 1) return b;
    return SceneTheme(
      gradient: [
        Color.lerp(a.gradient[0], b.gradient[0], t)!,
        Color.lerp(a.gradient[1], b.gradient[1], t)!,
        Color.lerp(a.gradient[2], b.gradient[2], t)!,
      ],
      overlay: Color.lerp(a.overlay, b.overlay, t)!,
      glassAlpha: lerpDouble(a.glassAlpha, b.glassAlpha, t)!,
      glassTint: Color.lerp(a.glassTint, b.glassTint, t)!,
      contrastScrim: lerpDouble(a.contrastScrim, b.contrastScrim, t)!,
      iconColor: Color.lerp(a.iconColor, b.iconColor, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
      cloudColor: Color.lerp(a.cloudColor, b.cloudColor, t)!,
      statusBar: t < 0.5 ? a.statusBar : b.statusBar,
      layers: t < 0.5 ? a.layers : b.layers,
      isBright: t < 0.5 ? a.isBright : b.isBright,
    );
  }

  /// Bang mau cua canh [s].
  ///
  /// [isDay] chi anh huong cac canh dung chung ngay/dem (cloudy, rain, fog,
  /// windy...): `isDay: false` tra ve bien the dem (gradient pha 55 % voi
  /// mau dem, kinh toi, khong scrim). Canh *Day / *Night bo qua [isDay].
  static SceneTheme of(WeatherScene s, {bool isDay = true}) {
    if (isDay || s.isDayVariant || s.isNightVariant) return _day[s]!;
    return _nightCache.putIfAbsent(s, () => _nightVariant(_day[s]!));
  }

  static final Map<WeatherScene, SceneTheme> _nightCache = {};

  static const List<Color> _nightBase = [
    Color(0xFF0B1026),
    Color(0xFF1B2A55),
    Color(0xFF33427A),
  ];

  static SceneTheme _nightVariant(SceneTheme d) {
    const double mix = 0.55;
    return SceneTheme(
      gradient: [
        for (int i = 0; i < 3; i++)
          Color.lerp(d.gradient[i], _nightBase[i], mix)!,
      ],
      overlay: const Color(0x00000000),
      glassAlpha: 0.20,
      glassTint: const Color(0xFF0B1026),
      contrastScrim: 0,
      iconColor: d.iconColor,
      accent: d.accent,
      cloudColor: Color.lerp(d.cloudColor, const Color(0x2E3A4670), 0.6)!,
      statusBar: _lightStatusBar,
      layers: d.layers,
      isBright: false,
    );
  }

  static const Map<WeatherScene, SceneTheme> _day = {
    WeatherScene.clearDay: SceneTheme(
      gradient: [Color(0xFF3A8DDE), Color(0xFF6DB6F2), Color(0xFFA8D8F7)],
      overlay: Color(0x480A2A5C),
      glassAlpha: 0.22,
      glassTint: Color(0xFF0B2545),
      contrastScrim: 0.16,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFFFD45C),
      cloudColor: Color(0x00FFFFFF),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.sun],
      isBright: true,
    ),
    WeatherScene.clearNight: SceneTheme(
      gradient: [Color(0xFF0B1026), Color(0xFF1B2A55), Color(0xFF33427A)],
      overlay: Color(0x00000000),
      glassAlpha: 0.18,
      glassTint: Color(0xFFFFFFFF),
      contrastScrim: 0,
      iconColor: Color(0xFFF1F4FF),
      accent: Color(0xFFB9C6FF),
      cloudColor: Color(0x00FFFFFF),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.moonStars, SceneLayer.shootingStar],
      isBright: false,
    ),
    WeatherScene.partlyCloudyDay: SceneTheme(
      gradient: [Color(0xFF3F86CF), Color(0xFF6FA9DF), Color(0xFF98BFE2)],
      overlay: Color(0x500A2A5C),
      glassAlpha: 0.22,
      glassTint: Color(0xFF0B2545),
      contrastScrim: 0.20,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFFFD45C),
      cloudColor: Color(0x2CF4F8FF),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.sun, SceneLayer.cloudsParallax],
      isBright: true,
    ),
    WeatherScene.partlyCloudyNight: SceneTheme(
      gradient: [Color(0xFF0E1630), Color(0xFF212E58), Color(0xFF3A4673)],
      overlay: Color(0x00000000),
      glassAlpha: 0.20,
      glassTint: Color(0xFF0B1026),
      contrastScrim: 0,
      iconColor: Color(0xFFF1F4FF),
      accent: Color(0xFFB9C6FF),
      cloudColor: Color(0x267A86B0),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.moonStars, SceneLayer.cloudsParallax],
      isBright: false,
    ),
    WeatherScene.cloudy: SceneTheme(
      gradient: [Color(0xFF6E7F96), Color(0xFF8F9CB0), Color(0xFFAAB4C3)],
      overlay: Color(0x3A1A2433),
      glassAlpha: 0.22,
      glassTint: Color(0xFF18202C),
      contrastScrim: 0.18,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFDCE6F5),
      cloudColor: Color(0x28E8EDF5),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsParallax],
      isBright: true,
    ),
    WeatherScene.overcast: SceneTheme(
      gradient: [Color(0xFF56657A), Color(0xFF6F7C90), Color(0xFF8A95A6)],
      overlay: Color(0x20161E2A),
      glassAlpha: 0.22,
      glassTint: Color(0xFF161E2A),
      contrastScrim: 0.16,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFCBD5E3),
      cloudColor: Color(0x30C5CCD8),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsDense],
      isBright: true,
    ),
    WeatherScene.drizzle: SceneTheme(
      gradient: [Color(0xFF4D627C), Color(0xFF677C96), Color(0xFF8193AA)],
      overlay: Color(0x18141E2C),
      glassAlpha: 0.20,
      glassTint: Color(0xFF141E2C),
      contrastScrim: 0.14,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFF9FD3FF),
      cloudColor: Color(0x2CB8C2D0),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsParallax, SceneLayer.drizzle],
      isBright: true,
    ),
    WeatherScene.rain: SceneTheme(
      gradient: [Color(0xFF3B4D64), Color(0xFF52657E), Color(0xFF6A7C94)],
      overlay: Color(0x00101826),
      glassAlpha: 0.20,
      glassTint: Color(0xFF101826),
      contrastScrim: 0.12,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFF7CC4FF),
      cloudColor: Color(0x2C9AA6B8),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsDense, SceneLayer.rain],
      isBright: true,
    ),
    WeatherScene.heavyRain: SceneTheme(
      gradient: [Color(0xFF2A374A), Color(0xFF3D4C62), Color(0xFF52627A)],
      overlay: Color(0x00000000),
      glassAlpha: 0.20,
      glassTint: Color(0xFF0E1522),
      contrastScrim: 0,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFF6BB8FF),
      cloudColor: Color(0x2A8590A3),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsDense, SceneLayer.heavyRain],
      isBright: false,
    ),
    WeatherScene.thunderstorm: SceneTheme(
      gradient: [Color(0xFF171B29), Color(0xFF262D40), Color(0xFF394257)],
      overlay: Color(0x00000000),
      glassAlpha: 0.18,
      glassTint: Color(0xFFFFFFFF),
      contrastScrim: 0,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFFFE066),
      cloudColor: Color(0x2E5A6378),
      statusBar: _lightStatusBar,
      layers: [
        SceneLayer.lightning,
        SceneLayer.cloudsDense,
        SceneLayer.heavyRain,
      ],
      isBright: false,
    ),
    WeatherScene.snow: SceneTheme(
      gradient: [Color(0xFF8FA6BF), Color(0xFFB4C6D8), Color(0xFFD5E1EC)],
      overlay: Color(0x581B2A3E),
      glassAlpha: 0.22,
      glassTint: Color(0xFF14223A),
      contrastScrim: 0.20,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFCFE8FF),
      cloudColor: Color(0x28F2F6FB),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsThin, SceneLayer.snow],
      isBright: true,
    ),
    WeatherScene.sleet: SceneTheme(
      gradient: [Color(0xFF5F7088), Color(0xFF7A8AA0), Color(0xFF95A3B6)],
      overlay: Color(0x28182232),
      glassAlpha: 0.22,
      glassTint: Color(0xFF182232),
      contrastScrim: 0.16,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFBFE0FF),
      cloudColor: Color(0x2CB0BACA),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsDense, SceneLayer.sleet],
      isBright: true,
    ),
    WeatherScene.fog: SceneTheme(
      gradient: [Color(0xFF8A9198), Color(0xFFA3A9AF), Color(0xFFBCC1C6)],
      overlay: Color(0x4A1E242A),
      glassAlpha: 0.22,
      glassTint: Color(0xFF1E242A),
      contrastScrim: 0.20,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFE3E7EB),
      cloudColor: Color(0x32E6EBF0),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.fog],
      isBright: true,
    ),
    WeatherScene.haze: SceneTheme(
      gradient: [Color(0xFF9A8F80), Color(0xFFB3A796), Color(0xFFC9BFAE)],
      overlay: Color(0x4A2E261C),
      glassAlpha: 0.22,
      glassTint: Color(0xFF2E261C),
      contrastScrim: 0.20,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFFFD9A0),
      cloudColor: Color(0x32F0D8B0),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.haze],
      isBright: true,
    ),
    WeatherScene.windy: SceneTheme(
      gradient: [Color(0xFF3E7FBF), Color(0xFF6C9FCF), Color(0xFF98BCDD)],
      overlay: Color(0x400A2A5C),
      glassAlpha: 0.22,
      glassTint: Color(0xFF0B2545),
      contrastScrim: 0.16,
      iconColor: Color(0xFFFFFFFF),
      accent: Color(0xFFBDF2FF),
      cloudColor: Color(0x30F4F8FF),
      statusBar: _lightStatusBar,
      layers: [SceneLayer.cloudsThin, SceneLayer.windStreaks],
      isBright: true,
    ),
  };
}
