/// Lop, nhan thoi gian va thang mau cua ban do.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/place.dart';
import '../../models/units.dart';
import '../../models/weather.dart';
import '../../ui/weather/design_tokens.dart';
import '../../utils/forecast_format.dart';
import '../../utils/formatters.dart';

/// Lop hien thi tren ban do.
enum MapLayerKind { temperature, rain, wind }

extension MapLayerText on MapLayerKind {
  String get label => switch (this) {
    MapLayerKind.temperature => 'Nhiệt độ',
    MapLayerKind.rain => 'Mưa',
    MapLayerKind.wind => 'Gió',
  };

  IconData get icon => switch (this) {
    MapLayerKind.temperature => Icons.thermostat_rounded,
    MapLayerKind.rain => Icons.water_drop_outlined,
    MapLayerKind.wind => Icons.air_rounded,
  };
}

/// Goc xoay (radian, chieu kim dong ho tu huong Bac) cua mui ten gio.
/// [fromDeg] la huong gio THOI TU -> mui ten chi huong thoi TOI (+180 do).
double windArrowAngle(double fromDeg) =>
    ((fromDeg + 180) % 360) * math.pi / 180;

/// Gio giat tu nguong nay (km/h) duoc nhan manh.
const double kStrongGustKmh = 50;

String _hm(DateTime t) => ForecastFormat.hourMinute(t);

/// "Thứ 7, 17/10 · 18:00" (gio TP.HCM; kieu day du chung cua app).
String mapClockLabel(DateTime t) => ForecastFormat.moment(t);

/// Nhan khung tren ban do, vd "Đã ghi nhận (mô hình) lúc 15:00",
/// "Dự báo: Thứ 7 · 18:00". null neu khong co thoi diem.
String? mapFrameLabel(
  DataSource? source,
  DateTime? valid, {
  DateTime? observedAt,
}) {
  if (source == DataSource.observed) {
    return observedAt == null
        ? 'Đã ghi nhận (mô hình) · chưa rõ giờ dữ liệu'
        : 'Đã ghi nhận (mô hình) lúc ${ForecastFormat.dateTime(observedAt)}';
  }
  if (valid == null) return null;
  final when = '${ForecastFormat.weekday(valid)} · ${_hm(valid)}';
  return switch (source) {
    DataSource.forecast => 'Dự báo: $when',
    DataSource.ai => 'Dự báo AI: $when',
    _ => 'Dữ liệu: $when',
  };
}

/// Nguon phan "3 gio toi" theo `outlook_source`.
String? outlookSourceLabel(String? s) => switch (s) {
  'forecast' => 'Dự báo nguồn ngoài (máy chủ cũ)',
  'ai' => 'Dự báo AI Sky Weather',
  _ => null,
};

/// Nhan offset: "Bây giờ", "+3 giờ".
String offsetLabel(int h) => h == 0 ? 'Bây giờ' : '+$h giờ';

/// Mo ta gio bang chu (danh sach thay the / Semantics).
String windText(MapCell c, [UnitPrefs units = const UnitPrefs()]) {
  if (c.windSpeed == null) return 'gió không có dữ liệu';
  final b = StringBuffer('gió ${units.windText(c.windSpeed)}');
  if (c.windDirection != null) {
    b.write(
      ', thổi từ hướng ${WeatherFormat.compass(c.windDirection)} '
      'về hướng ${WeatherFormat.compass(c.windDirection! + 180)}',
    );
  }
  if (c.windGusts != null) {
    b.write(', giật ${units.windText(c.windGusts)}');
    if (c.windGusts! >= kStrongGustKmh) b.write(' (giật mạnh)');
  }
  return b.toString();
}

/// Mot muc chu giai: mau + nhan (khong chi dua vao mau).
@immutable
class LegendEntry {
  const LegendEntry(this.color, this.label);
  final Color color;
  final String label;
}

/// Thang mau theo gia tri cua lop (dung chung cho diem danh dau va chu giai).
abstract final class MapScale {
  /// Nguong nhiet do (do C): < 24, 24-27, 27-30, 30-33, >= 33.
  static const List<double> tempSteps = [24, 27, 30, 33];
  static const List<Color> tempColors = [
    Palette.tempCool,
    Palette.tempMild,
    Palette.tempWarm,
    Palette.tempHot,
    Palette.tempVeryHot,
  ];

  /// Nguong kha nang mua (%): < 20, 20-40, 40-60, 60-80, >= 80.
  static const List<int> rainSteps = [20, 40, 60, 80];
  static const List<Color> rainColors = DataColors.rainScale;

  /// Nguong gio (km/h): < 10, 10-20, 20-30, 30-40, >= 40.
  static const List<int> windSteps = [10, 20, 30, 40];
  static const List<Color> windColors = DataColors.windScale;

  /// Nhan gio giat manh.
  static const Color gust = DataColors.gust;

  static const Color noData = DataColors.noData;

  /// Chu tren nen mau sang.
  static const Color ink = Palette.onAlert;

  static Color forTemp(double? c) {
    if (c == null) return noData;
    var i = 0;
    while (i < tempSteps.length && c >= tempSteps[i]) {
      i++;
    }
    return tempColors[i];
  }

  /// Khoang nhiet do (min, max) cua khung dang xem; null = khong co du lieu.
  static (double, double)? tempRange(Iterable<MapCell> cells) {
    double? lo, hi;
    for (final c in cells) {
      final t = c.temperature;
      if (t == null) continue;
      lo = lo == null || t < lo ? t : lo;
      hi = hi == null || t > hi ? t : hi;
    }
    return lo == null ? null : (lo, hi!);
  }

  /// Mau tuong doi: [lo] -> mau mat nhat, [hi] -> nong nhat, noi suy muot
  /// giua 5 moc. Khoang < 1 do thi mo rong quanh trung binh (tranh phong dai
  /// chenh lech nho thanh do / xanh).
  static Color forTempIn(double? c, double lo, double hi) {
    if (c == null) return noData;
    final mid = (lo + hi) / 2;
    final half = math.max((hi - lo) / 2, 0.5);
    final t = ((c - (mid - half)) / (2 * half)).clamp(0.0, 1.0);
    final x = t * (tempColors.length - 1);
    final i = x.floor().clamp(0, tempColors.length - 2);
    return Color.lerp(tempColors[i], tempColors[i + 1], x - i)!;
  }

  static Color forRain(int? percent) {
    if (percent == null) return noData;
    var i = 0;
    while (i < rainSteps.length && percent >= rainSteps[i]) {
      i++;
    }
    return rainColors[i];
  }

  static Color forWind(double? kmh) {
    if (kmh == null) return noData;
    var i = 0;
    while (i < windSteps.length && kmh >= windSteps[i]) {
      i++;
    }
    return windColors[i];
  }

  static Color colorFor(
    MapLayerKind layer,
    MapCell c, [
    (double, double)? range,
  ]) => switch (layer) {
    MapLayerKind.temperature =>
      range == null
          ? forTemp(c.temperature)
          : forTempIn(c.temperature, range.$1, range.$2),
    MapLayerKind.rain => forRain(c.rainPercent),
    MapLayerKind.wind => forWind(c.windSpeed),
  };

  /// Chu giai cua lop. [temp] doi do C sang don vi dang chon.
  static List<LegendEntry> legend(
    MapLayerKind layer,
    String Function(double c) temp, [
    UnitPrefs units = const UnitPrefs(),
    (double, double)? range,
  ]) {
    if (layer == MapLayerKind.temperature && range != null) {
      // Thang tuong doi: nhan la nhiet do that tai tung moc.
      final (lo, hi) = range;
      final mid = (lo + hi) / 2;
      final half = math.max((hi - lo) / 2, 0.5);
      final n = tempColors.length - 1;
      return [
        for (var i = 0; i <= n; i++)
          LegendEntry(tempColors[i], '${temp(mid - half + 2 * half * i / n)}°'),
      ];
    }
    if (layer == MapLayerKind.temperature) {
      final s = tempSteps;
      return [
        LegendEntry(tempColors[0], '< ${temp(s[0])}°'),
        for (var i = 1; i < s.length; i++)
          LegendEntry(tempColors[i], '${temp(s[i - 1])}–${temp(s[i])}°'),
        LegendEntry(tempColors.last, '≥ ${temp(s.last)}°'),
      ];
    }
    if (layer == MapLayerKind.wind) {
      final w = windSteps;
      // Nguong tinh theo km/h; nhan theo don vi dang chon.
      String v(num x) => units.windParts(x.toDouble()).value;
      return [
        LegendEntry(windColors[0], '< ${units.windText(w[0].toDouble())}'),
        for (var i = 1; i < w.length; i++)
          LegendEntry(windColors[i], '${v(w[i - 1])}–${v(w[i])}'),
        LegendEntry(windColors.last, '≥ ${v(w.last)}'),
      ];
    }
    final s = rainSteps;
    return [
      LegendEntry(rainColors[0], '< ${s[0]}%'),
      for (var i = 1; i < s.length; i++)
        LegendEntry(rainColors[i], '${s[i - 1]}–${s[i]}%'),
      LegendEntry(rainColors.last, '≥ ${s.last}%'),
    ];
  }
}
