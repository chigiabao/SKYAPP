/// Cau tom tat / giai thich sinh tu so lieu THAT bang quy tac don gian
/// (khong mo hinh, khong bia so). Moi ham la ham thuan de test.
///
/// Moi DateTime la gio TP.HCM (xem HcmTime).
library;

import '../../models/units.dart';
import '../../models/weather.dart';
import '../../utils/forecast_format.dart';

String _hh(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:00';

/// Ma WMO dong (95, 96, 99).
bool isThunderCode(int? code) => code == 95 || code == 96 || code == 99;

bool _hasRainSource(HourlyForecast h) =>
    h.source == DataSource.observed ||
    h.source == DataSource.forecast ||
    h.source == DataSource.ai;

bool _hasRainReading(HourlyForecast h) {
  if (!_hasRainSource(h)) return false;
  final value = h.isObserved ? h.precipitationMm : h.rainProbability;
  return value != null &&
      value.isFinite &&
      value >= 0 &&
      (h.isObserved || value <= 1);
}

// Sorted rows must cover every hour exactly once; duplicates cannot fill gaps.
bool _completeRainWindow(
  List<HourlyForecast> hours,
  DateTime start,
  DateTime end,
) {
  if (hours.length != end.difference(start).inHours) return false;
  for (var i = 0; i < hours.length; i++) {
    if (hours[i].time != start.add(Duration(hours: i)) ||
        !_hasRainReading(hours[i])) {
      return false;
    }
  }
  return true;
}

/// Gio co mua: gio "thuc te" -> luong mua >= 0.1 mm; gio du bao / thong ke
/// -> xac suat >= [minProb].
bool _isRainHour(HourlyForecast h, double minProb) {
  if (!_hasRainReading(h)) return false;
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
///   1. Co gio mua (xac suat >= 50 % hoac uoc tinh >= 0,1 mm):
///      gio da ghi nhan chi duoc goi la uoc tinh mo hinh, khong xac nhan
///      mua tai cho; gio du bao hien kha nang mua va xac suat.
///   2. Khong gio nao >= 50 % nhung dinh >= 30 % hoac tong >= 2 mm:
///      "Có thể mưa rải rác, khả năng cao nhất khoảng HH:00 (P%)."
///   3. Khong mua: mo ta dieu kien hien tai "… đến hết ngày." neu moi gio
///      con lai trong ngay cung dieu kien, con lai "Không có mưa đáng kể
///      trong 24 giờ tới."
///   4. Them "Gió giật tới X km/h." neu gio giat lon nhat >= 15 km/h.
/// null neu khong du bang chung de tom tat; du lieu cu khong duoc ket luan.
String? hourlySummary(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  WeatherCondition? currentCondition,
  UnitPrefs units = const UnitPrefs(),
  bool isStale = false,
}) {
  if (isStale) return null;
  final next = _upcoming(hours, nowHcm, 24);
  if (next.isEmpty) return null;
  final start = HcmTime.startOfHour(nowHcm);
  final parts = <String>[];
  final rainIdx = next.indexWhere((h) => _isRainHour(h, 0.5));
  if (rainIdx >= 0) {
    final h = next[rainIdx];
    if (h.time == start && h.isObserved) {
      parts.add(
        'Mô hình ước tính có mưa lúc ${_hh(h.time)}; chưa xác nhận tại chỗ.',
      );
    } else if (h.time == start) {
      parts.add('Có khả năng mưa ngay bây giờ (${h.rainPercent}%).');
    } else {
      parts.add(
        h.isObserved
            ? 'Mô hình ước tính có mưa lúc ${_hh(h.time)}.'
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
    // No hour reaches 50 %, but a 30-49 % peak or >= 2 mm in total is still
    // rain worth mentioning (otherwise this line contradicts the rain bar).
    HourlyForecast? peak;
    var totalMm = 0.0;
    for (final h in next) {
      if (!_hasRainReading(h)) continue;
      totalMm += h.precipitationMm ?? 0;
      if (!h.isObserved &&
          (peak == null ||
              (h.rainProbability ?? 0) > (peak.rainProbability ?? 0))) {
        peak = h;
      }
    }
    final peakProb = peak?.rainProbability ?? 0;
    if (peak != null && (peakProb >= 0.3 || totalMm >= 2)) {
      parts.add(
        'Có thể mưa rải rác, khả năng cao nhất khoảng ${_hh(peak.time)} '
        '(${peak.rainPercent}%).',
      );
    } else if (_completeRainWindow(
          next,
          start,
          start.add(const Duration(hours: 24)),
        ) &&
        !next.any((h) => isThunderCode(h.weatherCode))) {
      if (rest.isNotEmpty && rest.every((h) => h.condition == c)) {
        parts.add('${_conditionPhrase(c)} đến hết ngày.');
      } else {
        parts.add('Không có mưa đáng kể trong 24 giờ tới.');
      }
    }
  }
  double? gust;
  for (final h in next) {
    final g = h.windGusts;
    if (g != null && (gust == null || g > gust)) gust = g;
  }
  if (gust != null && gust >= 15) {
    parts.add(
      units.wind == WindUnit.kmh
          ? 'Gió giật tới ${gust.round()}\u00A0km\u2060/\u2060h.'
          : 'Gió giật tới ${units.windText(gust).replaceAll(' ', ' ')}.',
    );
  }
  return parts.isEmpty ? null : parts.join(' ');
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

/// Mot o du bao tren dong thoi gian mua: xac suat 0..1 va luong mua mm.
typedef RainSlot = ({DateTime time, double? p, double? mm, bool thunder});

/// [count] gio toi; bo gio da ghi nhan, khong bien luong mua thanh xac suat.
List<RainSlot> rainTimeline(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  int count = 24,
}) => [
  for (final h in _upcoming(hours, nowHcm, count))
    if (!h.isObserved)
      (
        time: h.time,
        p: _hasRainReading(h) ? h.rainProbability : null,
        mm: h.precipitationMm ?? h.precipitationMedian,
        thunder: isThunderCode(h.weatherCode),
      ),
];

/// Cau tom tat HANH DONG duoi so nhiet do o dau trang (mot dong), vd.
/// "Dự báo mưa 12–13h · nhớ mang ô" / "Không mưa đến tối".
///
/// Cua so xet: den 24:00 hom nay (truoc 18h) hoac den 06:00 sang mai.
/// Gio du bao mua = xac suat >= 30 % / ma dong. Chi gop gio lien tiep.
/// Gio da ghi nhan chi la uoc tinh, khong xac nhan dang mua tai cho.
/// Khong ket luan kho khi
/// thieu nguon, so lieu, gio phu cua so, hoac du lieu cu.
String? heroRainSummary(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  bool isStale = false,
}) {
  if (isStale) return null;
  final start = HcmTime.startOfHour(nowHcm);
  final evening = nowHcm.hour >= 18;
  final end = evening
      ? HcmTime.startOfDay(nowHcm).add(const Duration(hours: 30))
      : HcmTime.startOfDay(nowHcm).add(const Duration(days: 1));
  final next = _upcoming(hours, nowHcm, end.difference(start).inHours);
  if (next.isEmpty) return null;
  bool rain(HourlyForecast h) =>
      !h.isObserved &&
      (_isRainHour(h, 0.3) ||
          (_hasRainSource(h) && isThunderCode(h.weatherCode)));
  final i = next.indexWhere(rain);
  if (i < 0) {
    if (next.first.time == start &&
        next.first.isObserved &&
        _isRainHour(next.first, 0.3)) {
      return 'Ước tính có mưa lúc ${_hh(start)} · chưa xác nhận tại chỗ';
    }
    if (!_completeRainWindow(next, start, end) ||
        next.any((h) => (h.precipitationMm ?? 0) >= 0.1)) {
      return null;
    }
    return evening ? 'Đêm nay không mưa' : 'Không mưa đến tối';
  }

  // Khong noi mua lien tuc qua mot gio duoi nguong.
  var last = i;
  for (var k = i + 1; k < next.length; k++) {
    if (next[k].time != next[k - 1].time.add(const Duration(hours: 1))) break;
    if (rain(next[k])) {
      last = k;
    } else {
      break;
    }
  }
  final block = next.sublist(i, last + 1);
  final thunder = [
    for (final h in block)
      if (isThunderCode(h.weatherCode)) h,
  ];
  String hr(DateTime t) => ForecastFormat.clock(t.hour, 0);
  DateTime endOf(HourlyForecast h) => h.time.add(const Duration(hours: 1));
  final blockEnd = endOf(block.last);
  final likely = block.any((h) => (h.rainProbability ?? 0) >= 0.7);

  final String what;
  if (thunder.isNotEmpty) {
    final tEnd = endOf(thunder.last);
    final tPart = 'Dự báo dông ${hr(thunder.first.time)}–${hr(tEnd)}';
    what = blockEnd.isAfter(tEnd) ? '$tPart, mưa đến ${hr(blockEnd)}' : tPart;
  } else {
    final range = '${hr(block.first.time)}–${hr(blockEnd)}';
    var maxP = 0;
    for (final h in block) {
      if (!h.isObserved && h.rainPercent > maxP) maxP = h.rainPercent;
    }
    what = likely ? 'Dự báo mưa $range' : 'Có thể mưa $range ($maxP%)';
  }

  // Loi khuyen theo gio di / ve (16–19h) va muc do.
  bool overlaps(int fromH, int toH) => block.any(
    (h) =>
        h.time.hour >= fromH &&
        h.time.hour < toH &&
        HcmTime.startOfDay(h.time) == HcmTime.startOfDay(block.first.time),
  );
  final String tip;
  if (overlaps(16, 19)) {
    tip = 'mang áo mưa khi về';
  } else if (thunder.isNotEmpty) {
    tip = 'tránh ra ngoài lúc dông';
  } else if (overlaps(6, 9)) {
    tip = 'mang áo mưa khi đi';
  } else {
    tip = likely ? 'nhớ mang ô' : 'nên mang ô';
  }
  return '$what · $tip';
}

/// Xac suat mua lon nhat (%) trong [hoursAhead] gio toi (gio du bao), null
/// neu khong co so lieu.
int? maxRainPercent(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  int hoursAhead = 2,
}) {
  int? best;
  for (final h in _upcoming(hours, nowHcm, hoursAhead)) {
    if (h.isObserved || !_hasRainReading(h)) continue;
    final p = h.rainPercent;
    if (best == null || p > best) best = p;
  }
  return best;
}

/// Mo ta ap suat muc bien (hPa).
String pressureCaption(double hpa) {
  if (hpa < 1000) return 'Thấp';
  if (hpa <= 1020) return 'Bình thường';
  return 'Cao';
}
