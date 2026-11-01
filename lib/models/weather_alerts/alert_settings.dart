part of '../weather_alerts.dart';

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
    this.places = const {},
  });

  /// Cai dat rieng theo dia diem (id -> ghi de). Khong co -> dung chung.
  final Map<String, PlaceAlertOverride> places;

  PlaceAlertOverride placeOverride(String id) =>
      places[id] ?? const PlaceAlertOverride();

  /// Dat (hoac xoa khi la mac dinh) cai dat rieng cua [id].
  AlertSettings withPlace(String id, PlaceAlertOverride o) =>
      copyWith(places: {...places, id: o}..removeWhere((_, v) => v.isDefault));

  /// Cai dat hieu luc cho [id]: nguong rieng ghi de nguong chung.
  AlertSettings forPlace(String id) {
    final o = places[id];
    if (o == null) return this;
    var s = this;
    for (final e in o.thresholds.entries) {
      s = s.withThreshold(e.key, e.value);
    }
    return s;
  }

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
    Map<String, PlaceAlertOverride>? places,
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
    places: places ?? this.places,
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
    if (places.isNotEmpty)
      'places': {for (final e in places.entries) e.key: e.value.toJson()},
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
      places: {
        if (j['places'] is Map)
          for (final e in (j['places'] as Map).entries)
            if (e.key is String && e.value is Map)
              e.key as String: PlaceAlertOverride.fromJson(
                Map<String, dynamic>.from(e.value as Map),
              ),
      },
    );
  }
}

/// Cai dat canh bao rieng cho mot dia diem: bat/tat ca dia diem va nguong
/// rieng (don vi goc cua [AlertType.unit]: km/h, mm/h...).
class PlaceAlertOverride {
  const PlaceAlertOverride({this.enabled = true, this.thresholds = const {}});

  final bool enabled;
  final Map<AlertType, double> thresholds;

  bool get isDefault => enabled && thresholds.isEmpty;

  PlaceAlertOverride copyWith({
    bool? enabled,
    Map<AlertType, double>? thresholds,
  }) => PlaceAlertOverride(
    enabled: enabled ?? this.enabled,
    thresholds: thresholds ?? this.thresholds,
  );

  /// Dat nguong rieng; null -> bo (dung nguong chung).
  PlaceAlertOverride withThreshold(AlertType t, double? v) => copyWith(
    thresholds: {...thresholds}
      ..remove(t)
      ..addAll({t: ?v}),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'thresholds': {for (final e in thresholds.entries) e.key.name: e.value},
  };

  factory PlaceAlertOverride.fromJson(Map<String, dynamic> j) {
    final raw = j['thresholds'];
    return PlaceAlertOverride(
      enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      thresholds: {
        if (raw is Map)
          for (final t in AlertType.values)
            if (raw[t.name] is num && (raw[t.name] as num).isFinite)
              t: (raw[t.name] as num).toDouble(),
      },
    );
  }
}

/// Mot gio thoa dieu kien: gia tri do va muc do.
