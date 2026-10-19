/// Hoat dong ngoai troi va cham diem tung gio (thuan Dart).
///
/// Moi hoat dong co "ho so" (nhiet do de chiu, muc so mua / UV / gio / AQI,
/// khung gio hop ly trong ngay). [scoreHour] cho 0-100 kem ly do;
/// [bestWindows] tim khung gio lien tiep tot nhat trong 24-48 gio toi.
library;

import 'dart:math' as math;

import 'weather.dart';
import 'weather_alerts.dart' show feelsLikeOf, isThunderstormCode;

/// Muc nhay cam voi thoi tiet (nhan he so phat).
enum Sensitivity {
  low('Ít', 0.7),
  normal('Vừa', 1.0),
  high('Nhiều', 1.4);

  const Sensitivity(this.label, this.factor);
  final String label;
  final double factor;
}

/// Ho so mot hoat dong.
class ActivityProfile {
  const ActivityProfile({
    required this.tempLo,
    required this.tempHi,
    required this.rainWeight,
    required this.uvMax,
    required this.gustMax,
    required this.aqiWeight,
    required this.hours,
    this.durationHours = 1,
    this.preferSun = false,
    this.goldenHours = const [],
  });

  /// Khoang nhiet do cam giac de chiu, °C.
  final double tempLo;
  final double tempHi;

  /// Diem tru toi da khi chac chan mua (xac suat 100 %).
  final double rainWeight;

  /// UV toi da khong bi tru diem.
  final double uvMax;

  /// Gio giat toi da khong bi tru diem, km/h.
  final double gustMax;

  /// He so tru diem theo AQI (0 = khong quan tam).
  final double aqiWeight;

  /// Gio trong ngay cho phep (gio bat dau, 0-23).
  final Set<int> hours;

  /// Do dai khung goi y, gio.
  final int durationHours;

  /// Can nang (phoi do): duoc cong diem khi UV vua phai.
  final bool preferSun;

  /// Gio "vang" duoc cong diem (chup anh).
  final List<int> goldenHours;
}

/// Danh sach hoat dong (de bai muc 4: di lam / di hoc, tap the duc, hoat
/// dong ngoai troi).
enum Activity {
  running(
    'Chạy bộ',
    ActivityProfile(
      tempLo: 20,
      tempHi: 30,
      rainWeight: 60,
      uvMax: 5,
      gustMax: 35,
      aqiWeight: 1,
      hours: {5, 6, 7, 8, 9, 16, 17, 18, 19, 20},
    ),
  ),
  cycling(
    'Đạp xe',
    ActivityProfile(
      tempLo: 20,
      tempHi: 31,
      rainWeight: 70,
      uvMax: 5,
      gustMax: 30,
      aqiWeight: 0.8,
      hours: {5, 6, 7, 8, 9, 16, 17, 18, 19},
      durationHours: 2,
    ),
  ),
  commute(
    'Đi làm / đi học',
    ActivityProfile(
      tempLo: 20,
      tempHi: 34,
      rainWeight: 70,
      uvMax: 8,
      gustMax: 45,
      aqiWeight: 0.4,
      hours: {6, 7, 8, 9, 16, 17, 18, 19},
    ),
  ),
  laundry(
    'Giặt phơi đồ',
    ActivityProfile(
      tempLo: 24,
      tempHi: 40,
      rainWeight: 100,
      uvMax: 12,
      gustMax: 50,
      aqiWeight: 0,
      hours: {7, 8, 9, 10, 11, 12, 13, 14},
      durationHours: 3,
      preferSun: true,
    ),
  ),
  outing(
    'Đi chơi',
    ActivityProfile(
      tempLo: 22,
      tempHi: 32,
      rainWeight: 60,
      uvMax: 6,
      gustMax: 40,
      aqiWeight: 0.6,
      hours: {7, 8, 9, 10, 15, 16, 17, 18, 19, 20, 21},
      durationHours: 3,
    ),
  ),
  photography(
    'Chụp ảnh',
    ActivityProfile(
      tempLo: 20,
      tempHi: 34,
      rainWeight: 80,
      uvMax: 9,
      gustMax: 40,
      aqiWeight: 0.5,
      hours: {5, 6, 7, 8, 15, 16, 17},
      goldenHours: [5, 6, 16, 17],
    ),
  ),
  watering(
    'Tưới cây',
    ActivityProfile(
      tempLo: 18,
      tempHi: 34,
      rainWeight: 50,
      uvMax: 4,
      gustMax: 40,
      aqiWeight: 0,
      hours: {5, 6, 7, 8, 16, 17, 18},
    ),
  );

  const Activity(this.label, this.profile);
  final String label;
  final ActivityProfile profile;
}

/// Mac dinh khi nguoi dung chua chon.
/// Di lam / di hoc dung dau: nguoi dung TP.HCM di xe may can biet mua luc
/// di / ve nhat.
const List<Activity> kDefaultFavorites = [
  Activity.commute,
  Activity.running,
  Activity.laundry,
  Activity.outing,
];

/// Diem mot gio.
class HourScore {
  const HourScore(this.time, this.score, this.penalties);
  final DateTime time;

  /// 0-100.
  final double score;

  /// Yeu to bi tru diem -> diem tru (de chon ly do).
  final Map<String, double> penalties;
}

/// Cham diem mot gio cho [a]. Gia tri thieu (null) khong bi tru diem.
/// Gio ngoai [ActivityProfile.hours] -> 0 (tru khi [anyHour]).
HourScore scoreHour(
  Activity a,
  HourScoreInput h, {
  Sensitivity sensitivity = Sensitivity.normal,
  bool anyHour = false,
}) {
  final p = a.profile;
  final pen = <String, double>{};
  if (!anyHour && !p.hours.contains(h.time.hour)) {
    return HourScore(h.time, 0, const {'giờ': 100});
  }
  final f = sensitivity.factor;

  final t = h.feelsLike ?? h.temperature;
  if (t != null) {
    if (t > p.tempHi) pen['nóng'] = (t - p.tempHi) * 6 * f;
    if (t < p.tempLo) pen['lạnh'] = (p.tempLo - t) * 5 * f;
  }

  var rain = 0.0;
  if (h.rainProbability != null) rain = h.rainProbability!.clamp(0, 1) * 1.0;
  if ((h.precipitationMm ?? 0) >= 0.5) rain = math.max(rain, 0.9);
  if (rain > 0) pen['mưa'] = rain * p.rainWeight * f;
  if (isThunderstormCode(h.weatherCode)) {
    pen['dông'] = 60 * f;
  }

  final uv = h.uvIndex;
  if (uv != null && uv > p.uvMax) pen['UV'] = (uv - p.uvMax) * 8 * f;

  final g = h.windGusts;
  if (g != null && g > p.gustMax) pen['gió'] = (g - p.gustMax) * 1.5 * f;

  final aqi = h.usAqi;
  if (aqi != null && aqi > 50 && p.aqiWeight > 0) {
    pen['AQI'] = (aqi - 50) * 0.4 * p.aqiWeight * f;
  }

  var score = 100.0 - pen.values.fold(0.0, (s, v) => s + v);
  if (p.preferSun && uv != null && uv < 2) {
    pen['ít nắng'] = 15;
    score -= 15;
  }
  if (p.goldenHours.contains(h.time.hour)) score += 10;
  return HourScore(h.time, score.clamp(0, 100).toDouble(), pen);
}

/// Dau vao cham diem (tach khoi [HourlyForecast] de test ca bien / null).
class HourScoreInput {
  const HourScoreInput({
    required this.time,
    this.temperature,
    this.feelsLike,
    this.rainProbability,
    this.precipitationMm,
    this.uvIndex,
    this.windGusts,
    this.usAqi,
    this.weatherCode,
  });

  factory HourScoreInput.from(HourlyForecast h) => HourScoreInput(
    time: h.time,
    temperature: h.temperature,
    feelsLike: feelsLikeOf(h),
    // Gio "thuc te": xac suat chi la 0/1 -> chi dung luong mua.
    rainProbability: h.isObserved ? null : h.rainProbability,
    precipitationMm: h.precipitationMm,
    uvIndex: h.uvIndex,
    windGusts: h.windGusts,
    usAqi: h.usAqi,
    weatherCode: h.weatherCode,
  );

  final DateTime time;
  final double? temperature;
  final double? feelsLike;
  final double? rainProbability;
  final double? precipitationMm;
  final double? uvIndex;
  final double? windGusts;
  final int? usAqi;
  final int? weatherCode;
}

/// Muc danh gia khung gio.
enum WindowRating {
  good('Tốt'),
  fair('Khá'),
  poor('Kém');

  const WindowRating(this.label);
  final String label;

  static WindowRating of(double score) => score >= 75
      ? WindowRating.good
      : (score >= 55 ? WindowRating.fair : WindowRating.poor);
}

/// Mot khung gio goi y.
class ActivityWindow {
  const ActivityWindow({
    required this.activity,
    required this.start,
    required this.end,
    required this.score,
    required this.reason,
  });

  final Activity activity;
  final DateTime start;
  final DateTime end;
  final double score;

  /// Ly do ngan, vd. "Mưa 10% · 27–29°C · UV thấp".
  final String reason;

  WindowRating get rating => WindowRating.of(score);
}

/// Diem khung = 70 % trung binh + 30 % gio te nhat.
double _windowScore(List<HourScore> s) {
  final avg = s.fold(0.0, (a, b) => a + b.score) / s.length;
  final worst = s.map((e) => e.score).reduce(math.min);
  return avg * 0.7 + worst * 0.3;
}

String _reason(List<HourScoreInput> hs, List<HourScore> ss) {
  final parts = <String>[];
  final probs = [
    for (final h in hs)
      if (h.rainProbability != null) h.rainProbability!,
  ];
  if (probs.isNotEmpty) {
    parts.add('Mưa ${(probs.reduce(math.max) * 100).round()}%');
  } else if (hs.any((h) => h.precipitationMm != null)) {
    final mm = hs.map((h) => h.precipitationMm ?? 0).reduce(math.max);
    parts.add(mm < 0.1 ? 'Không mưa' : 'Mưa ${mm.toStringAsFixed(1)} mm');
  }
  final temps = [
    for (final h in hs)
      if ((h.feelsLike ?? h.temperature) != null)
        (h.feelsLike ?? h.temperature)!,
  ];
  if (temps.isNotEmpty) {
    final lo = temps.reduce(math.min).round();
    final hi = temps.reduce(math.max).round();
    parts.add(lo == hi ? 'Cảm giác $lo°C' : 'Cảm giác $lo–$hi°C');
  }
  // Yeu to tru diem nhieu nhat (neu dang ke).
  final tot = <String, double>{};
  for (final s in ss) {
    s.penalties.forEach((k, v) => tot[k] = (tot[k] ?? 0) + v);
  }
  tot.removeWhere((k, v) => k == 'mưa' || k == 'nóng' || k == 'lạnh');
  if (tot.isNotEmpty) {
    final worst = tot.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (worst.value / ss.length >= 5) parts.add('Lưu ý ${worst.key}');
  } else {
    final uvs = [
      for (final h in hs)
        if (h.uvIndex != null) h.uvIndex!,
    ];
    if (uvs.isNotEmpty && uvs.reduce(math.max) <= 3) parts.add('UV thấp');
  }
  return parts.isEmpty ? 'Thiếu dữ liệu chi tiết' : parts.join(' · ');
}

/// Toi da [limit] khung gio khong chong nhau, diem cao truoc, trong
/// [horizonHours] gio tinh tu dau gio hien tai ([nowHcm] - gio TP.HCM, ke ca
/// che do xem lai). Khung phai gom cac gio lien tiep co du lieu.
/// [hourBonus]: diem cong theo gio bat dau (thoi quen nguoi dung).
List<ActivityWindow> bestWindows(
  Activity activity,
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  int horizonHours = 48,
  int limit = 3,
  Sensitivity sensitivity = Sensitivity.normal,
  Map<int, double> hourBonus = const {},
}) {
  final from = HcmTime.startOfHour(nowHcm);
  final to = from.add(Duration(hours: horizonHours));
  final next = [
    for (final h in hours)
      if (!h.time.isBefore(from) && h.time.isBefore(to)) h,
  ]..sort((a, b) => a.time.compareTo(b.time));
  final inputs = [for (final h in next) HourScoreInput.from(h)];
  final scores = [
    for (final h in inputs) scoreHour(activity, h, sensitivity: sensitivity),
  ];
  final d = activity.profile.durationHours;
  final cands = <ActivityWindow>[];
  for (var i = 0; i + d <= next.length; i++) {
    final w = scores.sublist(i, i + d);
    // Lien tiep va deu trong khung gio cho phep.
    var ok = true;
    for (var k = 0; k < d; k++) {
      if (k > 0 &&
          next[i + k].time.difference(next[i + k - 1].time) !=
              const Duration(hours: 1)) {
        ok = false;
      }
      if (!activity.profile.hours.contains(next[i + k].time.hour)) ok = false;
    }
    if (!ok) continue;
    // Thoi quen (habits.dart): cong diem theo gio bat dau, ghi ro ly do.
    final bonus = hourBonus[next[i].time.hour] ?? 0;
    final reason = _reason(inputs.sublist(i, i + d), w);
    cands.add(
      ActivityWindow(
        activity: activity,
        start: next[i].time,
        end: next[i + d - 1].time.add(const Duration(hours: 1)),
        score: math.min(100, _windowScore(w) + bonus),
        reason: bonus > 0 ? '$reason · Hợp giờ quen' : reason,
      ),
    );
  }
  // On dinh: diem cao truoc, bang diem -> som hon truoc.
  cands.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c != 0 ? c : a.start.compareTo(b.start);
  });
  final out = <ActivityWindow>[];
  for (final c in cands) {
    if (out.length >= limit) break;
    if (out.any((o) => c.start.isBefore(o.end) && o.start.isBefore(c.end))) {
      continue;
    }
    out.add(c);
  }
  return out;
}

/// Lich hoat dong lap lai (de bai muc 4: dia diem, thoi gian, lich lap lai,
/// muc nhay cam).
class ActivityRoutine {
  const ActivityRoutine({
    required this.id,
    required this.activity,
    required this.placeId,
    required this.hour,
    this.minute = 0,
    this.weekdays = const {1, 2, 3, 4, 5, 6, 7},
    this.sensitivity = Sensitivity.normal,
  });

  final String id;
  final Activity activity;
  final String placeId;
  final int hour;
  final int minute;

  /// DateTime.monday (1) .. DateTime.sunday (7).
  final Set<int> weekdays;
  final Sensitivity sensitivity;

  /// Lan dien ra tiep theo tu [nowHcm] (trong 8 ngay), null neu khong co ngay.
  DateTime? nextAfter(DateTime nowHcm) {
    if (weekdays.isEmpty) return null;
    final day = HcmTime.startOfDay(nowHcm);
    for (var i = 0; i < 8; i++) {
      final d = day.add(Duration(days: i));
      final t = d.add(Duration(hours: hour, minutes: minute));
      if (weekdays.contains(d.weekday) && !t.isBefore(nowHcm)) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'activity': activity.name,
    'placeId': placeId,
    'hour': hour,
    'minute': minute,
    'weekdays': weekdays.toList()..sort(),
    'sensitivity': sensitivity.name,
  };

  static ActivityRoutine? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final a = Activity.values.where((e) => e.name == j['activity']);
    final h = j['hour'];
    final m = j['minute'];
    if (a.isEmpty ||
        j['id'] is! String ||
        j['placeId'] is! String ||
        h is! int ||
        h < 0 ||
        h > 23) {
      return null;
    }
    final wd = j['weekdays'];
    return ActivityRoutine(
      id: j['id'] as String,
      activity: a.first,
      placeId: j['placeId'] as String,
      hour: h,
      minute: m is int && m >= 0 && m < 60 ? m : 0,
      weekdays: wd is List
          ? {
              for (final d in wd)
                if (d is int && d >= 1 && d <= 7) d,
            }
          : const {1, 2, 3, 4, 5, 6, 7},
      sensitivity: Sensitivity.values.firstWhere(
        (s) => s.name == j['sensitivity'],
        orElse: () => Sensitivity.normal,
      ),
    );
  }
}

/// Danh gia mot lan dien ra cua lich: diem gio do (khong xet khung gio cho
/// phep cua hoat dong vi nguoi dung da chon gio), null neu thieu du lieu.
HourScore? scoreRoutineAt(
  ActivityRoutine r,
  List<HourlyForecast> hours,
  DateTime at,
) {
  final slot = HcmTime.startOfHour(at);
  for (final h in hours) {
    if (h.time == slot) {
      return scoreHour(
        r.activity,
        HourScoreInput.from(h),
        sensitivity: r.sensitivity,
        anyHour: true,
      );
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Gio di / ve va thong bao buoi sang

/// "7h30" / "17h" (cach noi quen thuoc).
String shortHm(int h, int m) =>
    m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';

/// Gio di / ve (di lam / di hoc), dia diem Nha / Noi lam, thong bao buoi
/// sang. Mac dinh: di 7:30, ve 17:30, thong bao 6:30 (tat cho toi khi
/// nguoi dung bat).
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

/// Mot dong di / ve: "Về 17h30: mưa 70% – mang áo mưa". [verb] = "Đi" /
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
  final day = HcmTime.startOfDay(at) == today ? '' : ' mai';
  final when = '$verb$day ${shortHm(hour, minute)}';
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

/// Noi dung thong bao buoi sang, vd. "Hôm nay: mưa 15–18h ở Q1, mang áo mưa
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
    rainy.add('mưa ${span.$1}–${span.$2}h ở ${p.name}');
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
