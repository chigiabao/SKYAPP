/// Bo luat canh bao chay tren thiet bi (thuan Dart, khong goi mang).
///
/// Dau vao: du lieu theo gio cua mot dia diem + [AlertSettings]. Dau ra:
/// danh sach [AlertEvent] (gom cac gio lien tiep cung loai). Canh bao dua tren
/// du lieu MO HINH, KHONG phai canh bao chinh thuc.
library;

import 'dart:math' as math;

import 'weather.dart';

/// Dong mien tru hien o man Canh bao / banner / thong bao.
const String kAlertDisclaimer =
    'Cảnh báo dựa trên dữ liệu mô hình, không phải cảnh báo chính thức – '
    'xem Đài KTTV khu vực Nam Bộ';

/// Muc do (tang dan).
enum AlertLevel {
  advisory('Lưu ý'),
  warning('Cảnh báo'),
  danger('Nguy hiểm');

  const AlertLevel(this.label);
  final String label;

  bool operator >=(AlertLevel o) => index >= o.index;
  bool operator >(AlertLevel o) => index > o.index;
}

AlertLevel _max(AlertLevel a, AlertLevel b) => a.index >= b.index ? a : b;

/// Cac loai canh bao.
enum AlertType {
  rain('Mưa', '%'),
  heavyRain('Mưa lớn', 'mm/h'),
  thunderstorm('Dông', ''),
  heat('Nắng nóng', '°C'),
  uv('UV cao', ''),
  wind('Gió giật mạnh', 'km/h'),
  aqi('Không khí kém', 'AQI');

  const AlertType(this.label, this.unit);
  final String label;
  final String unit;
}

/// Ngưỡng / bat-tat / gio yen lang. Gia tri mac dinh hop voi TP.HCM.
class AlertSettings {
  const AlertSettings({
    this.enabled = const {
      AlertType.rain: true,
      AlertType.heavyRain: true,
      AlertType.thunderstorm: true,
      AlertType.heat: true,
      AlertType.uv: true,
      AlertType.wind: true,
      AlertType.aqi: true,
    },
    this.rainProbability = 70,
    this.heavyRainMm = 10,
    this.heatTemp = 35,
    this.heatIndex = 41,
    this.uvIndex = 8,
    this.windGust = 50,
    this.aqi = 151,
    this.lookaheadHours = 24,
    this.minNotifyLevel = AlertLevel.warning,
    this.quietEnabled = true,
    this.quietStart = 22,
    this.quietEnd = 6,
  });

  final Map<AlertType, bool> enabled;

  /// Xac suat mua toi thieu, %.
  final double rainProbability;

  /// Luong mua mot gio toi thieu cho "Mưa lớn", mm.
  final double heavyRainMm;

  /// Nhiet do toi thieu cho "Nắng nóng", °C (nang nong: >= 35 °C).
  final double heatTemp;

  /// Chi so nhiet / nhiet do cam giac toi thieu, °C.
  final double heatIndex;
  final double uvIndex;

  /// Gio giat toi thieu, km/h.
  final double windGust;

  /// US AQI toi thieu.
  final double aqi;

  /// So gio toi xet (tinh tu dau gio hien tai).
  final int lookaheadHours;

  /// Muc uu tien: chi tao thong bao tu muc nay tro len.
  final AlertLevel minNotifyLevel;

  /// Gio yen lang [quietStart, quietEnd) (gio TP.HCM); muc Nguy hiem van bao.
  final bool quietEnabled;
  final int quietStart;
  final int quietEnd;

  bool isEnabled(AlertType t) => enabled[t] ?? true;

  /// Nguong hien hanh cua loai [t] (don vi [AlertType.unit]); null = khong
  /// chinh duoc (dong).
  double? thresholdOf(AlertType t) {
    switch (t) {
      case AlertType.rain:
        return rainProbability;
      case AlertType.heavyRain:
        return heavyRainMm;
      case AlertType.thunderstorm:
        return null;
      case AlertType.heat:
        return heatTemp;
      case AlertType.uv:
        return uvIndex;
      case AlertType.wind:
        return windGust;
      case AlertType.aqi:
        return aqi;
    }
  }

  bool inQuietHours(DateTime nowHcm) {
    if (!quietEnabled || quietStart == quietEnd) return false;
    final h = nowHcm.hour;
    return quietStart < quietEnd
        ? h >= quietStart && h < quietEnd
        : h >= quietStart || h < quietEnd;
  }

  AlertSettings copyWith({
    Map<AlertType, bool>? enabled,
    double? rainProbability,
    double? heavyRainMm,
    double? heatTemp,
    double? heatIndex,
    double? uvIndex,
    double? windGust,
    double? aqi,
    int? lookaheadHours,
    AlertLevel? minNotifyLevel,
    bool? quietEnabled,
    int? quietStart,
    int? quietEnd,
  }) => AlertSettings(
    enabled: enabled ?? this.enabled,
    rainProbability: rainProbability ?? this.rainProbability,
    heavyRainMm: heavyRainMm ?? this.heavyRainMm,
    heatTemp: heatTemp ?? this.heatTemp,
    heatIndex: heatIndex ?? this.heatIndex,
    uvIndex: uvIndex ?? this.uvIndex,
    windGust: windGust ?? this.windGust,
    aqi: aqi ?? this.aqi,
    lookaheadHours: lookaheadHours ?? this.lookaheadHours,
    minNotifyLevel: minNotifyLevel ?? this.minNotifyLevel,
    quietEnabled: quietEnabled ?? this.quietEnabled,
    quietStart: quietStart ?? this.quietStart,
    quietEnd: quietEnd ?? this.quietEnd,
  );

  /// Dat lai nguong cua mot loai.
  AlertSettings withThreshold(AlertType t, double v) {
    switch (t) {
      case AlertType.rain:
        return copyWith(rainProbability: v);
      case AlertType.heavyRain:
        return copyWith(heavyRainMm: v);
      case AlertType.thunderstorm:
        return this;
      case AlertType.heat:
        return copyWith(heatTemp: v);
      case AlertType.uv:
        return copyWith(uvIndex: v);
      case AlertType.wind:
        return copyWith(windGust: v);
      case AlertType.aqi:
        return copyWith(aqi: v);
    }
  }

  AlertSettings withEnabled(AlertType t, bool on) =>
      copyWith(enabled: {...enabled, t: on});

  Map<String, dynamic> toJson() => {
    'enabled': {for (final e in enabled.entries) e.key.name: e.value},
    'rainProbability': rainProbability,
    'heavyRainMm': heavyRainMm,
    'heatTemp': heatTemp,
    'heatIndex': heatIndex,
    'uvIndex': uvIndex,
    'windGust': windGust,
    'aqi': aqi,
    'lookaheadHours': lookaheadHours,
    'minNotifyLevel': minNotifyLevel.name,
    'quietEnabled': quietEnabled,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
  };

  /// Doc an toan: truong sai / thieu -> mac dinh.
  factory AlertSettings.fromJson(Map<String, dynamic> j) {
    const d = AlertSettings();
    double n(String k, double def) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble() : def;
    }

    int h(String k, int def) {
      final v = j[k];
      return v is int && v >= 0 && v < 24 ? v : def;
    }

    final en = <AlertType, bool>{...d.enabled};
    final raw = j['enabled'];
    if (raw is Map) {
      for (final t in AlertType.values) {
        final v = raw[t.name];
        if (v is bool) en[t] = v;
      }
    }
    final look = j['lookaheadHours'];
    return AlertSettings(
      enabled: en,
      rainProbability: n('rainProbability', d.rainProbability),
      heavyRainMm: n('heavyRainMm', d.heavyRainMm),
      heatTemp: n('heatTemp', d.heatTemp),
      heatIndex: n('heatIndex', d.heatIndex),
      uvIndex: n('uvIndex', d.uvIndex),
      windGust: n('windGust', d.windGust),
      aqi: n('aqi', d.aqi),
      lookaheadHours: look is int && look >= 1 && look <= 48
          ? look
          : d.lookaheadHours,
      minNotifyLevel: AlertLevel.values.firstWhere(
        (l) => l.name == j['minNotifyLevel'],
        orElse: () => d.minNotifyLevel,
      ),
      quietEnabled: j['quietEnabled'] is bool
          ? j['quietEnabled'] as bool
          : d.quietEnabled,
      quietStart: h('quietStart', d.quietStart),
      quietEnd: h('quietEnd', d.quietEnd),
    );
  }
}

/// Mot gio thoa dieu kien: gia tri do va muc do.
class AlertHit {
  const AlertHit(this.level, this.value);
  final AlertLevel level;
  final double value;
}

/// Chi so nhiet (NOAA, Rothfusz) tu nhiet do °C va do am %. Duoi 27 °C hoac
/// do am < 40 % -> tra ve chinh nhiet do (cong thuc khong ap dung).
double heatIndexC(double tempC, double humidity) {
  if (tempC < 27 || humidity < 40) return tempC;
  final t = tempC * 9 / 5 + 32;
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

  /// Co gio "thuc te" (dang xay ra) thay vi chi du bao.
  final bool observed;

  /// Khoa chong trung: loai + dia diem + gio bat dau.
  String get key => '${type.name}|$placeId|${HcmTime.toIso(start)}';

  /// "Mưa lớn · 15:00–18:00".
  String get title => '${type.label} · ${alertRange(start, end)}';

  /// "Tới 25 mm/h · Dự báo".
  String get detail {
    final v = peakText;
    final src = observed ? 'Đang xảy ra (số liệu phân tích)' : 'Dự báo';
    return v == null ? src : '$v · $src';
  }

  String? get peakText {
    switch (type) {
      case AlertType.thunderstorm:
        return peak >= 96 ? 'Dông kèm mưa đá' : null;
      case AlertType.rain:
        return observed
            ? '${peak.toStringAsFixed(1)} mm'
            : 'Xác suất tới ${peak.round()}%';
      case AlertType.heavyRain:
        return 'Tới ${peak.toStringAsFixed(1)} mm/h';
      case AlertType.heat:
        return 'Cảm giác tới ${peak.round()}°C';
      case AlertType.uv:
        return 'UV tới ${peak.toStringAsFixed(peak % 1 == 0 ? 0 : 1)}';
      case AlertType.wind:
        return 'Giật tới ${peak.round()} km/h';
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
  final e = sameDay ? _hh(end) : '${_hh(end)} ${end.day}/${end.month}';
  return '${_hh(start)}\u2060–\u2060$e';
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

/// Canh bao cho mot dia diem trong [AlertSettings.lookaheadHours] gio toi,
/// sap xep: muc cao truoc, roi theo gio bat dau. Gio thong ke (climatology)
/// bi bo qua.
List<AlertEvent> evaluateAlerts(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  required String placeId,
  AlertSettings settings = const AlertSettings(),
}) {
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
  out.sort((a, b) {
    final l = b.level.index - a.level.index;
    if (l != 0) return l;
    final t = a.start.compareTo(b.start);
    return t != 0 ? t : _priority.indexOf(a.type) - _priority.indexOf(b.type);
  });
  return out;
}

/// Mot muc lich su thong bao (da hien cho nguoi dung).
class AlertNotice {
  const AlertNotice({
    required this.type,
    required this.level,
    required this.placeId,
    required this.placeName,
    required this.start,
    required this.end,
    required this.createdAt,
    required this.title,
    required this.body,
    this.updated = false,
    this.read = false,
  });

  final AlertType type;
  final AlertLevel level;
  final String placeId;
  final String placeName;
  final DateTime start;
  final DateTime end;

  /// Luc tao (gio TP.HCM).
  final DateTime createdAt;
  final String title;
  final String body;

  /// Thong bao cap nhat (du bao thay doi dang ke: muc do tang).
  final bool updated;
  final bool read;

  AlertNotice markRead() => AlertNotice(
    type: type,
    level: level,
    placeId: placeId,
    placeName: placeName,
    start: start,
    end: end,
    createdAt: createdAt,
    title: title,
    body: body,
    updated: updated,
    read: true,
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'level': level.name,
    'placeId': placeId,
    'placeName': placeName,
    'start': HcmTime.toIso(start),
    'end': HcmTime.toIso(end),
    'createdAt': HcmTime.toIso(createdAt),
    'title': title,
    'body': body,
    'updated': updated,
    'read': read,
  };

  /// null neu du lieu hong.
  static AlertNotice? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final type = AlertType.values.where((t) => t.name == j['type']);
    final level = AlertLevel.values.where((l) => l.name == j['level']);
    final start = HcmTime.tryParse(j['start'] as String?);
    final end = HcmTime.tryParse(j['end'] as String?);
    final created = HcmTime.tryParse(j['createdAt'] as String?);
    if (type.isEmpty ||
        level.isEmpty ||
        start == null ||
        end == null ||
        created == null ||
        j['placeId'] is! String) {
      return null;
    }
    return AlertNotice(
      type: type.first,
      level: level.first,
      placeId: j['placeId'] as String,
      placeName: j['placeName'] is String ? j['placeName'] as String : '',
      start: start,
      end: end,
      createdAt: created,
      title: j['title'] is String ? j['title'] as String : '',
      body: j['body'] is String ? j['body'] as String : '',
      updated: j['updated'] == true,
      read: j['read'] == true,
    );
  }
}

/// Ket qua [planNotices]: thong bao moi + so canh bao bi giu do gio yen lang.
class NoticePlan {
  const NoticePlan(this.notices, this.held);
  final List<AlertNotice> notices;
  final int held;
}

/// Chong spam: chi tao thong bao khi
///   - muc >= [AlertSettings.minNotifyLevel];
///   - chua co thong bao cung loai + dia diem co khung gio giao nhau, HOAC co
///     nhung muc do moi cao hon (du bao xau di dang ke -> "Cập nhật");
///   - khong trong gio yen lang (tru muc Nguy hiem).
/// Gio "thuc te" va du bao duoc ghi ro trong noi dung.
NoticePlan planNotices(
  List<AlertEvent> events, {
  required List<AlertNotice> history,
  required AlertSettings settings,
  required DateTime nowHcm,
  required String placeName,
}) {
  final out = <AlertNotice>[];
  var held = 0;
  final quiet = settings.inQuietHours(nowHcm);
  for (final e in events) {
    if (!(e.level >= settings.minNotifyLevel)) continue;
    final prior = [
      for (final n in [...history, ...out])
        if (n.type == e.type &&
            n.placeId == e.placeId &&
            e.overlaps(n.start, n.end))
          n,
    ];
    final updated = prior.isNotEmpty;
    if (updated && prior.any((n) => n.level >= e.level)) continue;
    if (quiet && e.level != AlertLevel.danger) {
      held++;
      continue;
    }
    out.add(
      AlertNotice(
        type: e.type,
        level: e.level,
        placeId: e.placeId,
        placeName: placeName,
        start: e.start,
        end: e.end,
        createdAt: nowHcm,
        title:
            '${updated ? 'Cập nhật: ' : ''}${e.level.label} '
            '${e.type.label.toLowerCase()} · ${alertRange(e.start, e.end)}',
        body: '$placeName · ${e.detail}',
        updated: updated,
      ),
    );
  }
  return NoticePlan(out, held);
}

/// Khoa chong trung / gop cua mot thong bao: loai | dia diem | gio bat dau.
String noticeKey(AlertNotice n) =>
    '${n.type.name}|${n.placeId}|${HcmTime.toIso(n.start)}';

/// Gop hai ban luu (vd. app dang mo va tac vu nen) theo [noticeKey]: giu muc
/// cao nhat (bang nhau -> ban moi hon), `read` = OR hai ben. Thu tu: theo lan
/// xuat hien dau tien ([a] truoc).
List<AlertNotice> mergeNotices(
  Iterable<AlertNotice> a,
  Iterable<AlertNotice> b,
) {
  final byKey = <String, AlertNotice>{};
  for (final n in [...a, ...b]) {
    final k = noticeKey(n);
    final o = byKey[k];
    if (o == null) {
      byKey[k] = n;
      continue;
    }
    final keep =
        n.level > o.level ||
            (n.level == o.level && n.createdAt.isAfter(o.createdAt))
        ? n
        : o;
    byKey[k] = (n.read || o.read) && !keep.read ? keep.markRead() : keep;
  }
  return byKey.values.toList();
}
