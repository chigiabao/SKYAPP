/// Cau tom tat / giai thich sinh tu so lieu THAT bang quy tac don gian
/// (khong mo hinh, khong bia so). Moi ham la ham thuan de test.
///
/// Moi DateTime la gio TP.HCM (xem HcmTime).
library;

import '../../models/weather.dart';

String _hh(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:00';

/// Ma WMO dong (95, 96, 99).
bool isThunderCode(int? code) => code == 95 || code == 96 || code == 99;

/// Gio co mua: gio "thuc te" -> luong mua >= 0.1 mm; gio du bao / thong ke
/// -> xac suat >= [minProb].
bool _isRainHour(HourlyForecast h, double minProb) {
  if (h.isObserved) return (h.precipitationMm ?? 0) >= 0.1;
  return (h.rainProbability ?? 0) >= minProb;
}

List<HourlyForecast> _upcoming(
  List<HourlyForecast> hours,
  DateTime nowHcm,
  int count,
) {
  final start = HcmTime.startOfHour(nowHcm);
  final end = start.add(Duration(hours: count));
  return [
    for (final h in hours)
      if (!h.time.isBefore(start) && h.time.isBefore(end)) h,
  ]..sort((a, b) => a.time.compareTo(b.time));
}

/// Mot cau tom tat cho the "Theo giờ" (24 gio toi).
///
/// Quy tac (theo thu tu):
///   1. Co gio mua (xac suat >= 50 % hoac gio thuc te >= 0,1 mm):
///      dang mua -> "Đang có mưa, kéo dài đến khoảng HH:00." / "Có khả năng
///      mưa ngay bây giờ (P%)."; sau do -> "Có khả năng mưa từ khoảng HH:00
///      (P%)." (P = xac suat cua gio do; gio thuc te khong ghi %).
///   2. Khong mua: mo ta dieu kien hien tai "… đến hết ngày." neu moi gio
///      con lai trong ngay cung dieu kien, con lai "Không có mưa đáng kể
///      trong 24 giờ tới."
///   3. Them "Gió giật tới X km/h." neu gio giat lon nhat >= 15 km/h.
/// null neu khong co gio nao.
String? hourlySummary(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  WeatherCondition? currentCondition,
}) {
  final next = _upcoming(hours, nowHcm, 24);
  if (next.isEmpty) return null;
  final parts = <String>[];
  final rainIdx = next.indexWhere((h) => _isRainHour(h, 0.5));
  if (rainIdx >= 0) {
    final h = next[rainIdx];
    if (rainIdx == 0 && h.isObserved) {
      var last = 0;
      while (last + 1 < next.length && _isRainHour(next[last + 1], 0.5)) {
        last++;
      }
      final endT = next[last].time.add(const Duration(hours: 1));
      parts.add('Đang có mưa, kéo dài đến khoảng ${_hh(endT)}.');
    } else if (rainIdx == 0) {
      parts.add('Có khả năng mưa ngay bây giờ (${h.rainPercent}%).');
    } else {
      parts.add(
        h.isObserved
            ? 'Có mưa từ khoảng ${_hh(h.time)}.'
            : 'Có khả năng mưa từ khoảng ${_hh(h.time)} (${h.rainPercent}%).',
      );
    }
  } else {
    final today = HcmTime.startOfDay(nowHcm);
    final rest = [
      for (final h in next)
        if (HcmTime.startOfDay(h.time) == today) h,
    ];
    final c = currentCondition ?? next.first.condition;
    if (rest.isNotEmpty && rest.every((h) => h.condition == c)) {
      parts.add('${_conditionPhrase(c)} đến hết ngày.');
    } else {
      parts.add('Không có mưa đáng kể trong 24 giờ tới.');
    }
  }
  double? gust;
  for (final h in next) {
    final g = h.windGusts;
    if (g != null && (gust == null || g > gust)) gust = g;
  }
  if (gust != null && gust >= 15) {
    parts.add('Gió giật tới ${gust.round()}\u00A0km\u2060/\u2060h.');
  }
  return parts.join(' ');
}

String _conditionPhrase(WeatherCondition c) {
  switch (c) {
    case WeatherCondition.sunny:
      return 'Trời quang';
    case WeatherCondition.partlyCloudy:
      return 'Trời có mây';
    case WeatherCondition.cloudy:
      return 'Trời nhiều mây';
    case WeatherCondition.foggy:
      return 'Có sương mù';
    case WeatherCondition.windy:
      return 'Gió lớn';
    case WeatherCondition.drizzle:
    case WeatherCondition.rainy:
    case WeatherCondition.showers:
    case WeatherCondition.thunderstorm:
      return 'Trời ${c.description.toLowerCase()}';
  }
}

/// Canh bao tu du bao mo hinh (KHONG phai canh bao chinh thuc).
class WeatherAlert {
  const WeatherAlert({
    required this.start,
    required this.end,
    required this.thunder,
    required this.maxPercent,
  });

  /// Gio dau tien du dieu kien (gio TP.HCM).
  final DateTime start;

  /// Het gio cuoi cung du dieu kien.
  final DateTime end;
  final bool thunder;

  /// Xac suat mua lon nhat trong khoang (%), null neu chi co gio thuc te.
  final int? maxPercent;

  /// "Cảnh báo mưa dông 15:00–18:00" / "Khả năng mưa cao 15:00–18:00".
  String get title => '$kind · $range';

  /// "Cảnh báo mưa dông" / "Khả năng mưa cao".
  String get kind => thunder ? 'Cảnh báo mưa dông' : 'Khả năng mưa cao';

  /// "15:00–18:00" (khong ngat dong quanh dau gach).
  String get range => '${_hh(start)}\u2060–\u2060${_hh(end)}';

  String get detail =>
      '${maxPercent == null ? '' : 'Tới $maxPercent% · '}'
      'dự báo mô hình, không phải cảnh báo chính thức';

  @override
  bool operator ==(Object other) =>
      other is WeatherAlert &&
      other.start == start &&
      other.end == end &&
      other.thunder == thunder;

  @override
  int get hashCode => Object.hash(start, end, thunder);
}

/// Canh bao khi trong 6 gio toi co gio xac suat mua >= 70 % hoac ma dong
/// (95/96/99). Khoang = tu gio dau den het gio cuoi du dieu kien.
WeatherAlert? weatherAlert(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
}) {
  final next = _upcoming(hours, nowHcm, 6);
  bool hit(HourlyForecast h) =>
      isThunderCode(h.weatherCode) ||
      (!h.isObserved && (h.rainProbability ?? 0) >= 0.7);
  final hits = next.where(hit).toList();
  if (hits.isEmpty) return null;
  int? maxP;
  for (final h in hits) {
    if (h.isObserved || h.rainProbability == null) continue;
    final p = h.rainPercent;
    if (maxP == null || p > maxP) maxP = p;
  }
  return WeatherAlert(
    start: hits.first.time,
    end: hits.last.time.add(const Duration(hours: 1)),
    thunder: hits.any((h) => isThunderCode(h.weatherCode)),
    maxPercent: maxP,
  );
}

/// Giai thich "Cảm giác như": so nhiet do cam giac voi nhiet do thuc va gan
/// cho do am (nong hon) hoac gio (mat hon).
String feelsLikeSentence({
  required double temperature,
  required double feelsLike,
  int? humidity,
  double? windKmh,
}) {
  final d = feelsLike - temperature;
  if (d >= 2) {
    if (humidity != null && humidity >= 60) {
      return 'Độ ẩm làm cảm giác nóng hơn.';
    }
    return 'Cảm giác nóng hơn nhiệt độ thực.';
  }
  if (d <= -2) {
    if (windKmh != null && windKmh >= 10) return 'Gió làm cảm giác mát hơn.';
    return 'Cảm giác mát hơn nhiệt độ thực.';
  }
  return 'Tương tự nhiệt độ thực.';
}

/// Cau UV tu uv_index theo gio cua ngay hom nay: gio cuoi >= 3 ->
/// "Dùng kem chống nắng đến HH:00."; khong con gio >= 3 -> "UV thấp phần còn
/// lại của ngày."; null neu khong co so lieu UV theo gio.
String? uvSentence(List<HourlyForecast> hours, {required DateTime nowHcm}) {
  final start = HcmTime.startOfHour(nowHcm);
  final today = HcmTime.startOfDay(nowHcm);
  final rest = [
    for (final h in hours)
      if (!h.time.isBefore(start) &&
          HcmTime.startOfDay(h.time) == today &&
          h.uvIndex != null)
        h,
  ]..sort((a, b) => a.time.compareTo(b.time));
  if (rest.isEmpty) {
    // Het gio du lieu trong ngay: chi ket luan khi UV hien tai da thap va
    // da qua troi toi (khong doan).
    return null;
  }
  HourlyForecast? last;
  for (final h in rest) {
    if (h.uvIndex! >= 3) last = h;
  }
  if (last == null) return 'UV thấp phần còn lại của ngày.';
  return 'Dùng kem chống nắng đến '
      '${_hh(last.time.add(const Duration(hours: 1)))}.';
}

/// Cau AQI: so voi cung gio hom qua neu du lieu theo gio co muc do (chi khi
/// API tra ve gio do); khong thi noi ve PM2.5. null neu khong co gi.
String? aqiSentence({
  required int? aqi,
  required double? pm25,
  required List<HourlyForecast> hours,
  required DateTime nowHcm,
}) {
  if (aqi != null) {
    final y = HcmTime.startOfHour(nowHcm).subtract(const Duration(days: 1));
    for (final h in hours) {
      if (h.time == y && h.usAqi != null) {
        final d = aqi - h.usAqi!;
        if (d.abs() <= 10) return 'Chỉ số tương tự hôm qua vào giờ này.';
        return d > 0
            ? 'Cao hơn hôm qua vào giờ này ($d điểm).'
            : 'Thấp hơn hôm qua vào giờ này (${-d} điểm).';
      }
    }
  }
  final p = pm25;
  if (p == null) return null;
  // WHO 2021: trung binh 24 h khuyen nghi 15 ug/m3.
  final v = p.toStringAsFixed(1).replaceAll('.', ',');
  if (p <= 15) {
    return 'Bụi mịn PM2.5 $v\u00A0µg/m³, trong mức khuyến nghị của WHO.';
  }
  final x = (p / 15).toStringAsFixed(1).replaceAll('.', ',');
  return 'Bụi mịn PM2.5 $v\u00A0µg/m³, gấp $x lần mức khuyến nghị 24 giờ '
      'của WHO.';
}

/// Cau do am theo diem suong.
String? humiditySentence(double? dewPoint) {
  final d = dewPoint;
  if (d == null) return null;
  final r = d.round();
  if (d >= 24) return 'Điểm sương $r°, không khí rất oi.';
  if (d >= 20) return 'Điểm sương $r°, khá oi.';
  if (d >= 15) return 'Điểm sương $r°, dễ chịu.';
  return 'Điểm sương $r°, không khí khô.';
}

/// Tong luong mua: [past24] = 24 gio qua tu cac gio "thuc te" (null neu du
/// lieu khong co du 24 gio do), [next24] = 24 gio toi tu gio du bao (null
/// neu khong co gio du bao nao co luong mua).
({double? past24, double? next24}) rainTotals(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
}) {
  final now = HcmTime.startOfHour(nowHcm);
  final pastStart = now.subtract(const Duration(hours: 24));
  final past = [
    for (final h in hours)
      if (h.isObserved &&
          !h.time.isBefore(pastStart) &&
          h.time.isBefore(now) &&
          h.precipitationMm != null)
        h,
  ];
  double? next;
  for (final h in _upcoming(hours, nowHcm, 24)) {
    if (h.isObserved) continue;
    final mm = h.precipitationMm ?? h.precipitationMedian;
    if (mm == null) continue;
    next = (next ?? 0) + mm;
  }
  return (
    past24: past.length >= 24
        ? past.fold<double>(0, (a, h) => a + h.precipitationMm!)
        : null,
    next24: next,
  );
}

/// Cau dau tien cua [hourlySummary] (dong "Hôm nay" o dau trang).
String? firstSentence(String? text) {
  if (text == null) return null;
  final i = text.indexOf('. ');
  return i < 0 ? text : text.substring(0, i + 1);
}

/// Mo ta ap suat muc bien (hPa).
String pressureCaption(double hpa) {
  if (hpa < 1000) return 'Thấp';
  if (hpa <= 1020) return 'Bình thường';
  return 'Cao';
}
