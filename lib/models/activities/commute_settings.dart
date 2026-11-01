part of '../activities.dart';

class CommuteSettings {
  const CommuteSettings({
    this.leaveHour = 7,
    this.leaveMinute = 30,
    this.returnHour = 17,
    this.returnMinute = 30,
    this.homeId,
    this.workId,
    this.briefEnabled = false,
    this.briefHour = 6,
    this.briefMinute = 30,
    this.briefInQuiet = true,
  });

  final int leaveHour;
  final int leaveMinute;
  final int returnHour;
  final int returnMinute;

  /// Id dia diem "Nhà" / "Nơi làm, học" (null = chua chon).
  final String? homeId;
  final String? workId;

  /// Thong bao tom tat mua buoi sang.
  final bool briefEnabled;
  final int briefHour;
  final int briefMinute;

  /// Cho phep gui thong bao buoi sang trong gio yen lang (nguoi dung tu dat
  /// gio nen mac dinh gui).
  final bool briefInQuiet;

  CommuteSettings copyWith({
    int? leaveHour,
    int? leaveMinute,
    int? returnHour,
    int? returnMinute,
    String? homeId,
    String? workId,
    bool? briefEnabled,
    int? briefHour,
    int? briefMinute,
    bool? briefInQuiet,
  }) => CommuteSettings(
    leaveHour: leaveHour ?? this.leaveHour,
    leaveMinute: leaveMinute ?? this.leaveMinute,
    returnHour: returnHour ?? this.returnHour,
    returnMinute: returnMinute ?? this.returnMinute,
    homeId: homeId ?? this.homeId,
    workId: workId ?? this.workId,
    briefEnabled: briefEnabled ?? this.briefEnabled,
    briefHour: briefHour ?? this.briefHour,
    briefMinute: briefMinute ?? this.briefMinute,
    briefInQuiet: briefInQuiet ?? this.briefInQuiet,
  );

  Map<String, dynamic> toJson() => {
    'leaveHour': leaveHour,
    'leaveMinute': leaveMinute,
    'returnHour': returnHour,
    'returnMinute': returnMinute,
    'homeId': homeId,
    'workId': workId,
    'briefEnabled': briefEnabled,
    'briefHour': briefHour,
    'briefMinute': briefMinute,
    'briefInQuiet': briefInQuiet,
  };

  factory CommuteSettings.fromJson(Map<String, dynamic> j) {
    const d = CommuteSettings();
    int h(String k, int def) {
      final v = j[k];
      return v is int && v >= 0 && v < 24 ? v : def;
    }

    int m(String k, int def) {
      final v = j[k];
      return v is int && v >= 0 && v < 60 ? v : def;
    }

    String? id(String k) => j[k] is String ? j[k] as String : null;
    return CommuteSettings(
      leaveHour: h('leaveHour', d.leaveHour),
      leaveMinute: m('leaveMinute', d.leaveMinute),
      returnHour: h('returnHour', d.returnHour),
      returnMinute: m('returnMinute', d.returnMinute),
      homeId: id('homeId'),
      workId: id('workId'),
      briefEnabled: j['briefEnabled'] == true,
      briefHour: h('briefHour', d.briefHour),
      briefMinute: m('briefMinute', d.briefMinute),
      briefInQuiet: j['briefInQuiet'] is bool
          ? j['briefInQuiet'] as bool
          : d.briefInQuiet,
    );
  }
}

HourlyForecast? _slotAt(List<HourlyForecast> hours, DateTime at) {
  final slot = HcmTime.startOfHour(at);
  for (final h in hours) {
    if (h.time == slot) return h;
  }
  return null;
}

bool _isRainy(HourlyForecast h) =>
    isThunderstormCode(h.weatherCode) ||
    (h.isObserved
        ? (h.precipitationMm ?? 0) >= 0.5
        : (h.rainProbability ?? 0) >= 0.5 || (h.precipitationMm ?? 0) >= 1);

/// Mot dong di / ve: "Về 17:30: mưa 70% – mang áo mưa". [verb] = "Đi" /
/// "Về"; lan toi cua gio do tu [nowHcm] (qua gio hon 30 phut -> ngay mai).
/// null neu chua co du bao cho gio do.
({DateTime at, String text, bool bad})? commuteLine(
  String verb,
  int hour,
  int minute,
  List<HourlyForecast> hours,
  DateTime nowHcm, {
  String Function(double c)? formatTemp,
}) {
  final today = HcmTime.startOfDay(nowHcm);
  var at = today.add(Duration(hours: hour, minutes: minute));
  if (at.isBefore(nowHcm.subtract(const Duration(minutes: 30)))) {
    at = at.add(const Duration(days: 1));
  }
  final h = _slotAt(hours, at);
  if (h == null) return null;
  // Hom nay: "Về 17:30"; ngay mai: "Sáng mai đi 07:30" / "Chiều mai về 17:30".
  final hm = clockHm(hour, minute);
  final String when;
  if (HcmTime.startOfDay(at) == today) {
    when = '$verb $hm';
  } else {
    final part = hour < 11
        ? 'Sáng'
        : hour < 14
        ? 'Trưa'
        : hour < 18
        ? 'Chiều'
        : 'Tối';
    when = '$part mai ${verb.toLowerCase()} $hm';
  }
  final p = h.isObserved ? null : h.rainProbability;
  final pct = p == null ? null : (p * 100).round();
  final mm = h.precipitationMm ?? 0;
  final feels = feelsLikeOf(h) ?? h.temperature;
  String temp(double c) => formatTemp?.call(c) ?? '${c.round()}°C';
  String advice;
  var bad = true;
  if (isThunderstormCode(h.weatherCode)) {
    advice = 'dông, sét – mang áo mưa, tránh trú dưới cây';
  } else if ((pct ?? 0) >= 50 || (h.isObserved && mm >= 0.5)) {
    advice = pct == null ? 'đang mưa – mang áo mưa' : 'mưa $pct% – mang áo mưa';
  } else if ((pct ?? 0) >= 30) {
    advice = 'có thể mưa ($pct%) – để sẵn áo mưa';
  } else if (feels >= 38) {
    advice = 'nóng, cảm giác ${temp(feels)} – mang nước, áo chống nắng';
  } else if ((h.uvIndex ?? 0) >= 8) {
    advice = 'nắng gắt (UV ${h.uvIndex!.round()}) – che chắn kỹ';
  } else {
    bad = false;
    advice = pct == null
        ? 'khô ráo, ${temp(h.temperature)}'
        : 'ít mưa ($pct%), ${temp(h.temperature)}';
  }
  return (at: at, text: '$when: $advice', bad: bad);
}

/// Khung mua lien tiep dai nhat trong ngay [day] (6h-22h): (gio bat dau,
/// gio het); null neu khong mua.
(int, int)? rainSpan(List<HourlyForecast> hours, DateTime day) {
  final d0 = HcmTime.startOfDay(day);
  (int, int)? best;
  int? start;
  for (var hr = 6; hr <= 22; hr++) {
    final h = _slotAt(hours, d0.add(Duration(hours: hr)));
    final rainy = h != null && _isRainy(h);
    if (rainy) start ??= hr;
    if ((!rainy || hr == 22) && start != null) {
      final end = rainy ? hr + 1 : hr;
      if (best == null || end - start > best.$2 - best.$1) best = (start, end);
      start = null;
    }
  }
  return best;
}

/// Noi dung thong bao buoi sang, vd. "Hôm nay: mưa 15:00–18:00 ở Q1, mang áo mưa
/// khi về." [places]: (ten, du lieu theo gio) cua Nha va Noi lam; du lieu
/// null = chua tai. null neu khong co du lieu nao cho ngay [dayHcm].
String? morningBrief(
  List<({String name, List<HourlyForecast>? hours})> places,
  DateTime dayHcm,
  CommuteSettings c,
) {
  final d0 = HcmTime.startOfDay(dayHcm);
  final rainy = <String>[];
  final dry = <String>[];
  var whenLeave = false;
  var whenBack = false;
  for (final p in places) {
    final hs = p.hours;
    if (hs == null || !hs.any((h) => HcmTime.startOfDay(h.time) == d0)) {
      continue;
    }
    final span = rainSpan(hs, dayHcm);
    if (span == null) {
      dry.add(p.name);
      continue;
    }
    rainy.add('mưa ${clockHm(span.$1, 0)}–${clockHm(span.$2, 0)} ở ${p.name}');
    bool covers(int h) => h >= span.$1 && h < span.$2;
    if (covers(c.leaveHour)) whenLeave = true;
    if (covers(c.returnHour)) whenBack = true;
  }
  if (rainy.isEmpty && dry.isEmpty) return null;
  if (rainy.isEmpty) {
    return 'Hôm nay: không có mưa đáng kể ở ${dry.join(' và ')}.';
  }
  final tip = whenLeave && whenBack
      ? 'mang áo mưa cả lúc đi và về'
      : whenLeave
      ? 'mang áo mưa khi đi'
      : whenBack
      ? 'mang áo mưa khi về'
      : 'để sẵn áo mưa trong cốp xe';
  return 'Hôm nay: ${rainy.join('; ')}, $tip.';
}
