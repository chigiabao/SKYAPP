part of '../weather_alerts.dart';

class AlertHit {
  const AlertHit(this.level, this.value);
  final AlertLevel level;
  final double value;
}

/// Chi so nhiet (NOAA, Rothfusz) tu nhiet do °C va do am %. Duoi 27 °C hoac
/// do am < 40 % -> tra ve chinh nhiet do (cong thuc khong ap dung).
double heatIndexC(double tempC, double humidity) {
  if (tempC < 27 || humidity < 40) return tempC;
  final t = UnitConvert.cToF(tempC);
  final r = humidity.clamp(0, 100).toDouble();
  final hi =
      -42.379 +
      2.04901523 * t +
      10.14333127 * r -
      0.22475541 * t * r -
      6.83783e-3 * t * t -
      5.481717e-2 * r * r +
      1.22874e-3 * t * t * r +
      8.5282e-4 * t * r * r -
      1.99e-6 * t * t * r * r;
  return (hi - 32) * 5 / 9;
}

/// Nhiet do cam giac cua mot gio: apparent_temperature neu co, neu khong tinh
/// tu nhiet do + do am; khong co do am -> null.
double? feelsLikeOf(HourlyForecast h) {
  if (h.apparentTemperature != null) return h.apparentTemperature;
  if (h.humidity == null) return null;
  return heatIndexC(h.temperature, h.humidity!);
}

bool isThunderstormCode(int? code) => code != null && code >= 95 && code <= 99;

/// Luat cho mot gio va mot loai; null = khong dat / thieu du lieu / tat.
AlertHit? evaluateHour(AlertType type, HourlyForecast h, AlertSettings s) {
  if (!s.isEnabled(type)) return null;
  switch (type) {
    case AlertType.rain:
      // Gio "thuc te": xac suat chi la 0/1 -> dung luong mua.
      if (h.isObserved) {
        final mm = h.precipitationMm;
        if (mm == null || mm < 0.5) return null;
        return AlertHit(AlertLevel.advisory, mm);
      }
      final p = h.rainProbability;
      if (p == null) return null;
      final pct = p * 100;
      if (pct < s.rainProbability) return null;
      return AlertHit(
        pct >= math.max(90, s.rainProbability)
            ? AlertLevel.warning
            : AlertLevel.advisory,
        pct,
      );
    case AlertType.heavyRain:
      final mm = h.precipitationMm ?? h.precipitationMedian;
      if (mm == null || mm < s.heavyRainMm) return null;
      return AlertHit(
        mm >= 2 * s.heavyRainMm ? AlertLevel.danger : AlertLevel.warning,
        mm,
      );
    case AlertType.thunderstorm:
      final c = h.weatherCode;
      if (!isThunderstormCode(c)) return null;
      // 96 / 99: dong kem mua da.
      return AlertHit(
        c! >= 96 ? AlertLevel.danger : AlertLevel.warning,
        c.toDouble(),
      );
    case AlertType.heat:
      AlertLevel? level;
      final t = h.temperature;
      if (t >= s.heatTemp) {
        level = t >= s.heatTemp + 4 ? AlertLevel.danger : AlertLevel.warning;
      }
      final fl = feelsLikeOf(h);
      if (fl != null && fl >= s.heatIndex) {
        final l = fl >= 54
            ? AlertLevel.danger
            : (fl >= s.heatIndex + 5
                  ? AlertLevel.warning
                  : AlertLevel.advisory);
        level = level == null ? l : _max(level, l);
      }
      if (level == null) return null;
      return AlertHit(level, math.max(t, fl ?? t));
    case AlertType.uv:
      final uv = h.uvIndex;
      if (uv == null || uv < s.uvIndex) return null;
      return AlertHit(
        uv >= 11
            ? AlertLevel.danger
            : (uv >= 8 ? AlertLevel.warning : AlertLevel.advisory),
        uv,
      );
    case AlertType.wind:
      final g = h.windGusts;
      if (g == null || g < s.windGust) return null;
      return AlertHit(
        g >= s.windGust + 25 ? AlertLevel.danger : AlertLevel.warning,
        g,
      );
    case AlertType.aqi:
      final a = h.usAqi;
      if (a == null || a < s.aqi) return null;
      return AlertHit(
        a >= 201
            ? AlertLevel.danger
            : (a >= 151 ? AlertLevel.warning : AlertLevel.advisory),
        a.toDouble(),
      );
  }
}

/// Trang thai thoi gian cua canh bao so voi "bay gio" cua app.
enum AlertTiming {
  /// Da ket thuc (end <= bay gio): khong con la canh bao dang hieu luc.
  past('Đã qua'),

  /// Bay gio nam trong khoang [start, end).
  ongoing('Đang xảy ra'),

  /// Chua bat dau.
  upcoming('Sắp tới');

  const AlertTiming(this.label);
  final String label;
}

/// Nhan cho khoang da xay ra that (so lieu da ghi nhan) nhung nam sau moc
/// xem lai.
const String kAlertRecordedLabel = 'Đã xảy ra';

/// Mot canh bao: cac gio lien tiep cung loai tai mot dia diem.
class AlertEvent {
  const AlertEvent({
    required this.type,
    required this.level,
    required this.placeId,
    required this.start,
    required this.end,
    required this.peak,
    required this.observed,
    this.asOf,
  });

  final AlertType type;
  final AlertLevel level;
  final String placeId;

  /// Gio dau tien (gio TP.HCM).
  final DateTime start;

  /// Het gio cuoi cung (khong gom).
  final DateTime end;

  /// Gia tri lon nhat trong khoang (don vi [AlertType.unit]).
  final double peak;

  /// Co gio "thuc te" (so lieu phan tich) thay vi chi du bao. Chi noi ve
  /// NGUON so lieu - o che do xem lai, gio sau thoi diem xem cung la "thuc
  /// te" - KHONG co nghia la dang xay ra (xem [timingAt]).
  final bool observed;

  /// "Bay gio" luc danh gia (gio TP.HCM; [evaluateAlerts] gan). null -> coi
  /// nhu [start] (sap toi / dang xay ra tuy du lieu cu).
  final DateTime? asOf;

  /// Qua / dang xay ra / sap toi so voi [now].
  AlertTiming timingAt(DateTime now) {
    if (!end.isAfter(now)) return AlertTiming.past;
    if (!start.isAfter(now)) return AlertTiming.ongoing;
    return AlertTiming.upcoming;
  }

  /// Trang thai theo [asOf] (khong co -> theo nguon so lieu nhu truoc).
  AlertTiming get timing => asOf == null
      ? (observed ? AlertTiming.ongoing : AlertTiming.upcoming)
      : timingAt(asOf!);

  /// Khoa chong trung: loai + dia diem + gio bat dau.
  String get key => '${type.name}|$placeId|${HcmTime.toIso(start)}';

  /// "Mưa lớn · 15:00–18:00" (them "Mai" / ngay khi khac ngay [asOf]).
  String get title => '${type.label} · ${alertWhen(start, end, asOf)}';

  /// "Tới 25 mm/h · Dự báo".
  String get detail => detailFor(const UnitPrefs());

  /// Nhan trang thai de doc. Khoang "sap toi" ma nguon la so lieu da ghi
  /// nhan chi co o che do xem lai (gio sau moc xem lai deu da qua that) ->
  /// ghi "Đã xảy ra" thay vi "Sắp tới" de khong bi hieu nham la du bao.
  /// Chi doi chu hien thi; [timing] / thu tu sap xep giu nguyen.
  String get timingText => observed && timing == AlertTiming.upcoming
      ? kAlertRecordedLabel
      : timing.label;

  /// Nhu [detail] nhung gia tri hien thi theo don vi [u] (nguong van goc).
  String detailFor(UnitPrefs u) {
    final v = peakTextFor(u);
    final src =
        '$timingText (${observed ? 'theo số liệu đã ghi nhận' : 'dự báo'})';
    return v == null ? src : '$v · $src';
  }

  String? get peakText => peakTextFor(const UnitPrefs());

  String? peakTextFor(UnitPrefs u) {
    switch (type) {
      case AlertType.thunderstorm:
        return peak >= 96 ? 'Có sét, kèm mưa đá' : 'Có sét';
      case AlertType.rain:
        return observed ? u.rainText(peak) : 'Xác suất tới ${peak.round()}%';
      case AlertType.heavyRain:
        return 'Tới ${u.rainRateText(peak)}';
      case AlertType.heat:
        return 'Cảm giác tới ${u.tempText(peak)}';
      case AlertType.uv:
        return 'Chỉ số UV tới ${WeatherFormat.compact(peak)}';
      case AlertType.wind:
        return 'Giật tới ${u.windText(peak)}';
      case AlertType.aqi:
        return 'AQI tới ${peak.round()}';
    }
  }

  /// Hai khoang thoi gian giao nhau.
  bool overlaps(DateTime s, DateTime e) => start.isBefore(e) && s.isBefore(end);
}

String _hh(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "15:00–18:00" (them "ngày d/M" khi khac ngay bat dau).
String alertRange(DateTime start, DateTime end) {
  final sameDay =
      HcmTime.startOfDay(start) ==
      HcmTime.startOfDay(end.subtract(const Duration(minutes: 1)));
  final e = sameDay ? _hh(end) : ForecastFormat.dateTime(end);
  return '${_hh(start)}\u2060–\u2060$e';
}

/// [alertRange] kem ngay khi khoang bat dau khac ngay voi [now]:
/// "Ngày mai 12:00–14:00" (cung chu voi [ForecastFormat.relativeDay]),
/// "23/10 12:00–14:00"; cung ngay -> nhu [alertRange].
String alertWhen(DateTime start, DateTime end, DateTime? now) {
  final range = alertRange(start, end);
  if (now == null) return range;
  final days = HcmTime.startOfDay(start)
      .difference(HcmTime.startOfDay(now))
      .inDays;
  if (days == 0) return range;
  if (days == 1) return '${ForecastFormat.relativeDay(start, now)} $range';
  if (days == -1) return 'Hôm qua $range';
  return '${ForecastFormat.dayMonth(start)} $range';
}

/// Thu tu khi cung muc va cung gio bat dau (nguy hiem truc tiep truoc).
const List<AlertType> _priority = [
  AlertType.thunderstorm,
  AlertType.heavyRain,
  AlertType.wind,
  AlertType.heat,
  AlertType.rain,
  AlertType.uv,
  AlertType.aqi,
];

/// Thu tu hien thi canh bao (the Home, man Canh bao): DANG XAY RA truoc,
/// roi sap toi theo gio bat dau; cung gio -> muc cao truoc; cuoi cung theo
/// do uu tien loai. Vd. dang mua luc nay dung truoc "UV cao · Mai".
int compareAlertsForDisplay(AlertEvent a, AlertEvent b, DateTime nowHcm) {
  final ao = a.timingAt(nowHcm) == AlertTiming.ongoing ? 0 : 1;
  final bo = b.timingAt(nowHcm) == AlertTiming.ongoing ? 0 : 1;
  if (ao != bo) return ao - bo;
  // Hai canh bao dang xay ra: khong so gio bat dau (deu la "bay gio").
  if (ao == 1) {
    final t = a.start.compareTo(b.start);
    if (t != 0) return t;
  }
  final l = b.level.index - a.level.index;
  if (l != 0) return l;
  return _priority.indexOf(a.type) - _priority.indexOf(b.type);
}

/// Canh bao cho mot dia diem trong [AlertSettings.lookaheadHours] gio toi,
/// sap xep theo [compareAlertsForDisplay]. Gio thong ke (climatology) bi bo
/// qua.
List<AlertEvent> evaluateAlerts(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  required String placeId,
  AlertSettings settings = const AlertSettings(),
}) {
  // Cai dat rieng cua dia diem: tat -> khong canh bao; nguong rieng ghi de.
  if (!settings.placeOverride(placeId).enabled) return const [];
  settings = settings.forPlace(placeId);
  final from = HcmTime.startOfHour(nowHcm);
  final to = from.add(Duration(hours: settings.lookaheadHours));
  final next = [
    for (final h in hours)
      if (!h.time.isBefore(from) &&
          h.time.isBefore(to) &&
          h.source != DataSource.climatology)
        h,
  ]..sort((a, b) => a.time.compareTo(b.time));

  final out = <AlertEvent>[];
  for (final type in AlertType.values) {
    if (!settings.isEnabled(type)) continue;
    DateTime? start;
    DateTime? end;
    var level = AlertLevel.advisory;
    var peak = double.negativeInfinity;
    var observed = false;

    void flush() {
      if (start == null) return;
      out.add(
        AlertEvent(
          type: type,
          level: level,
          placeId: placeId,
          start: start!,
          end: end!,
          peak: peak,
          observed: observed,
          asOf: nowHcm,
        ),
      );
      start = null;
      end = null;
      level = AlertLevel.advisory;
      peak = double.negativeInfinity;
      observed = false;
    }

    for (final h in next) {
      final hit = evaluateHour(type, h, settings);
      // Ngat khi khong dat hoac thieu gio (khoang ho trong du lieu).
      if (hit == null || (end != null && h.time != end)) flush();
      if (hit == null) continue;
      start ??= h.time;
      end = h.time.add(const Duration(hours: 1));
      level = _max(level, hit.level);
      peak = math.max(peak, hit.value);
      observed = observed || h.isObserved;
    }
    flush();
  }
  // Chi giu canh bao con hieu luc (dang xay ra / sap toi); khoang da qua
  // khong bao gio la "dang xay ra".
  out.removeWhere((e) => e.timingAt(nowHcm) == AlertTiming.past);
  out.sort((a, b) => compareAlertsForDisplay(a, b, nowHcm));
  return out;
}

/// Mot muc lich su thong bao (da hien cho nguoi dung).
