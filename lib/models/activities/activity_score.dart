part of '../activities.dart';

class HourScore {
  const HourScore(
    this.time,
    this.score,
    this.penalties, {
    this.missing = const {},
  });
  final DateTime time;

  /// 0-100 for available inputs only; use [rating] for presentation.
  final double score;
  final Set<String> missing;
  WindowRating get rating =>
      missing.isEmpty ? WindowRating.of(score) : WindowRating.unknown;

  /// Yeu to bi tru diem -> diem tru (de chon ly do).
  final Map<String, double> penalties;
}

/// Cham diem du lieu hien co; gia tri thieu khong tao muc danh gia tot.
/// Gio ngoai [ActivityProfile.hours] -> 0 (tru khi [anyHour]).
HourScore scoreHour(
  Activity a,
  HourScoreInput h, {
  Sensitivity sensitivity = Sensitivity.normal,
  bool anyHour = false,
}) {
  final p = a.profile;
  final pen = <String, double>{};
  final missing = <String>{
    if (h.feelsLike == null && h.temperature == null) 'nhiệt độ',
    if (h.rainProbability == null && h.precipitationMm == null) 'mưa',
    if (h.uvIndex == null) 'UV',
    if (h.windGusts == null) 'gió giật',
    if (p.aqiWeight > 0 && h.usAqi == null) 'AQI',
  };
  if (!anyHour && !p.hours.contains(h.time.hour)) {
    return HourScore(h.time, 0, const {'giờ': 100}, missing: missing);
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
  return HourScore(
    h.time,
    score.clamp(0, 100).toDouble(),
    pen,
    missing: missing,
  );
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
  poor('Kém'),
  unknown('Thiếu dữ liệu');

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
    this.missing = const {},
  });

  final Activity activity;
  final DateTime start;
  final DateTime end;
  final double score;
  final Set<String> missing;

  /// Ly do ngan, vd. "Mưa 10% · 27–29°C · UV thấp".
  final String reason;

  WindowRating get rating =>
      missing.isEmpty ? WindowRating.of(score) : WindowRating.unknown;
}

/// Diem khung = 70 % trung binh + 30 % gio te nhat.
double _windowScore(List<HourScore> s) {
  final avg = s.fold(0.0, (a, b) => a + b.score) / s.length;
  final worst = s.map((e) => e.score).reduce(math.min);
  return avg * 0.7 + worst * 0.3;
}

String _reason(List<HourScoreInput> hs, List<HourScore> ss, UnitPrefs u) {
  final parts = <String>[];
  final missing = {for (final s in ss) ...s.missing};
  if (missing.isNotEmpty) parts.add('Thiếu dữ liệu: ${missing.join(', ')}');
  final probs = [
    for (final h in hs)
      if (h.rainProbability != null) h.rainProbability!,
  ];
  if (probs.isNotEmpty) {
    parts.add('Mưa ${(probs.reduce(math.max) * 100).round()}%');
  } else if (hs.any((h) => h.precipitationMm != null)) {
    final mm = hs.map((h) => h.precipitationMm ?? 0).reduce(math.max);
    parts.add(mm < 0.1 ? 'Không mưa' : 'Mưa ${u.rainText(mm)}');
  }
  final temps = [
    for (final h in hs)
      if ((h.feelsLike ?? h.temperature) != null)
        (h.feelsLike ?? h.temperature)!,
  ];
  if (temps.isNotEmpty) {
    final lo = u.tempNumber(temps.reduce(math.min));
    final hi = u.tempNumber(temps.reduce(math.max));
    final unit = u.tempUnit;
    parts.add(lo == hi ? 'Cảm giác $lo$unit' : 'Cảm giác $lo–$hi$unit');
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
/// [units]: don vi hien thi nhiet do trong [ActivityWindow.reason].
List<ActivityWindow> bestWindows(
  Activity activity,
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  int horizonHours = 48,
  int limit = 3,
  Sensitivity sensitivity = Sensitivity.normal,
  Map<int, double> hourBonus = const {},
  UnitPrefs units = const UnitPrefs(),
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
    final reason = _reason(inputs.sublist(i, i + d), w, units);
    cands.add(
      ActivityWindow(
        activity: activity,
        start: next[i].time,
        end: next[i + d - 1].time.add(const Duration(hours: 1)),
        score: math.min(100, _windowScore(w) + bonus),
        missing: {for (final s in w) ...s.missing},
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
