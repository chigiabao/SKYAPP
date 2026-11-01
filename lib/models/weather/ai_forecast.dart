import '../hcm_time.dart';
import 'weather_helpers.dart';

// AI prediction cho mot moc thoi gian (1h/3h/6h)
class AIPrediction {
  final String timeLabel; // "1h", "3h", "6h"
  final double temperature;
  final double rainProbability; // 0-1

  /// Thoi diem muc tieu (gio TP.HCM). Backend moi gui `target_time`; neu
  /// thieu thi tinh = issued_at + so gio cua moc. null neu khong suy ra duoc.
  final DateTime? targetTime;

  /// Khoang p10-p90 nhiet do (do C) - deprecated, dung [intervalLow] /
  /// [intervalHigh]; null neu backend khong gui.
  final double? temperatureP10;
  final double? temperatureP90;

  /// Khoang nhiet do (do C) theo muc [intervalLevel] (vd 0,9); null neu
  /// backend cu khong gui.
  final double? temperatureLow;
  final double? temperatureHigh;
  final double? intervalLevel;

  /// Muc tieu phu (null = khong co): do am %, gio / gio giat km/h, mua mm.
  final double? humidity;
  final double? windSpeed;
  final double? windGusts;
  final double? precipitationMm;

  /// Giai thich muc bat dinh (tieng Viet, tu backend).
  final String? uncertaintyNote;

  const AIPrediction({
    required this.timeLabel,
    required this.temperature,
    required this.rainProbability,
    this.targetTime,
    this.temperatureP10,
    this.temperatureP90,
    this.temperatureLow,
    this.temperatureHigh,
    this.intervalLevel,
    this.humidity,
    this.windSpeed,
    this.windGusts,
    this.precipitationMm,
    this.uncertaintyNote,
  });

  bool get _hasLowHigh => temperatureLow != null && temperatureHigh != null;

  /// Can duoi / tren khoang: uu tien low/high, thieu thi lui ve p10/p90.
  double? get intervalLow => _hasLowHigh ? temperatureLow : temperatureP10;
  double? get intervalHigh => _hasLowHigh ? temperatureHigh : temperatureP90;

  /// Muc tin cay cua khoang (0-1): interval_level; khoang p10/p90 = 0,8.
  double? get effectiveIntervalLevel => _hasLowHigh
      ? intervalLevel
      : (temperatureP10 != null && temperatureP90 != null ? 0.8 : null);

  /// Co khoang hop le (low <= high).
  bool get hasInterval =>
      intervalLow != null &&
      intervalHigh != null &&
      intervalLow! <= intervalHigh!;

  /// "1h" -> 1, "6h" -> 6; null neu khong dung dinh dang.
  static int? horizonHours(String label) =>
      int.tryParse(label.toLowerCase().replaceAll('h', ''));

  int get rainPercent => (rainProbability * 100).round().clamp(0, 100);
}

// GET /weather/ai-forecast
class AIForecast {
  static const List<String> horizons = ['1h', '3h', '6h'];

  final DateTime issuedAt; // gio TP.HCM, xem HcmTime
  final List<AIPrediction> predictions;
  final String modelVersion;
  final String? forecastMode;

  /// Danh gia mo hinh tai o luoi cua dia diem; null = chua co danh gia.
  final AIEvaluation? evaluation;

  /// Muc tieu backend bat (`enabled_targets`); null = backend cu, hien moi
  /// truong co du lieu.
  final List<String>? enabledTargets;

  const AIForecast({
    required this.issuedAt,
    required this.predictions,
    required this.modelVersion,
    this.evaluation,
    this.enabledTargets,
    this.forecastMode,
  });

  /// Muc tieu [target] ("humidity", "temperature_interval", ...) co duoc bat.
  /// Thieu o goc thi dung `evaluation.enabled_targets`.
  bool isEnabled(String target) {
    final t = enabledTargets ?? evaluation?.enabledTargets;
    return t == null || t.contains(target);
  }

  factory AIForecast.fromJson(Map<String, dynamic> json) {
    final raw = json['predictions'];
    if (raw is! Map) {
      throw const FormatException('Thiếu trường "predictions"');
    }
    final issuedAt = requireDate(json, 'issued_at');
    final predictions = <AIPrediction>[];
    for (final label in horizons) {
      final p = raw[label];
      if (p is! Map) continue;
      final temp = toDouble(p['temperature']);
      if (temp == null) continue;
      final target = p['target_time'];
      final hours = AIPrediction.horizonHours(label);
      predictions.add(
        AIPrediction(
          timeLabel: label,
          temperature: temp,
          rainProbability: toDouble(p['rain_probability']) ?? 0,
          targetTime:
              (target is String ? HcmTime.tryParse(target) : null) ??
              (hours == null ? null : issuedAt.add(Duration(hours: hours))),
          temperatureP10: toDouble(p['temperature_p10']),
          temperatureP90: toDouble(p['temperature_p90']),
          temperatureLow: toDouble(p['temperature_low']),
          temperatureHigh: toDouble(p['temperature_high']),
          intervalLevel: toDouble(p['interval_level']),
          humidity: toDouble(p['humidity']),
          windSpeed: toDouble(p['wind_speed']),
          windGusts: toDouble(p['wind_gusts']),
          precipitationMm: toDouble(p['precipitation_mm']),
          uncertaintyNote: _nonEmpty(p['uncertainty_note']),
        ),
      );
    }
    return AIForecast(
      issuedAt: issuedAt,
      predictions: predictions,
      modelVersion: json['model_version']?.toString() ?? '',
      evaluation: AIEvaluation.tryParse(json['evaluation']),
      enabledTargets: _stringList(json['enabled_targets']),
      forecastMode: _nonEmpty(json['forecast_mode']),
    );
  }

  static List<String>? _stringList(dynamic v) =>
      v is List ? [for (final e in v) e.toString()] : null;

  static String? _nonEmpty(dynamic v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }
}

/// Ket qua danh gia mo hinh AI tren tap kiem tra tai mot o luoi
/// (truong `evaluation` cua /weather/ai-forecast va /weather/ai-verify).
class AIEvaluation {
  const AIEvaluation({
    this.cellId,
    this.temperatureMae = const {},
    this.rainF1 = const {},
    this.beatsBaselines,
    this.testPeriod,
    this.targetMae = const {},
    this.intervalCoverage = const {},
    this.intervalNominalCoverage,
    this.intervalWidth = const {},
    this.enabledTargets,
  });

  /// `enabled_targets` trong danh gia; null = khong co (backend cu).
  final List<String>? enabledTargets;

  bool isEnabled(String target) =>
      enabledTargets == null || enabledTargets!.contains(target);

  /// Muc tieu phu co MAE rieng (khoa trong [targetMae]).
  static const List<String> extraTargets = [
    'humidity',
    'wind_speed',
    'wind_gusts',
    'precipitation_mm',
  ];

  final String? cellId;

  /// MAE muc tieu phu: target -> (moc -> MAE, don vi goc %, km/h, mm).
  final Map<String, Map<String, double>> targetMae;

  /// Ty le thuc te roi vao khoang nhiet do tren tap kiem tra (0-1) theo moc.
  final Map<String, double> intervalCoverage;

  /// Do phu danh nghia cua khoang (`interval_level`, cu:
  /// `interval_nominal_coverage`, vd 0,9); null neu khong co.
  final double? intervalNominalCoverage;

  /// Do rong trung binh cua khoang (do C) theo moc; rong neu khong co.
  final Map<String, double> intervalWidth;

  /// MAE nhiet do (do C) theo moc "1h" / "3h" / "6h".
  final Map<String, double> temperatureMae;

  /// F1 du doan mua (0-1) theo moc.
  final Map<String, double> rainF1;

  /// Mo hinh tot hon cac mo hinh co so; null neu backend khong noi.
  final bool? beatsBaselines;

  /// "2025-01-01..2026-10-10".
  final String? testPeriod;

  /// Moc dau tien co MAE (uu tien 1h).
  String? get primaryHorizon {
    for (final h in AIForecast.horizons) {
      if (temperatureMae.containsKey(h)) return h;
    }
    return null;
  }

  /// "2025-01-01..2026-10-10" -> "01/2025 – 10/2026"; null neu khong doc duoc.
  String? get testPeriodText {
    final p = testPeriod;
    if (p == null) return null;
    final parts = p.split('..');
    if (parts.length != 2) return p;
    final a = DateTime.tryParse(parts[0].trim());
    final b = DateTime.tryParse(parts[1].trim());
    if (a == null || b == null) return p;
    String f(DateTime d) => '${d.month.toString().padLeft(2, '0')}/${d.year}';
    return '${f(a)} – ${f(b)}';
  }

  /// null neu khong phai object.
  static AIEvaluation? tryParse(dynamic json) {
    if (json is! Map) return null;
    final mae = <String, double>{};
    final f1 = <String, double>{};
    for (final h in AIForecast.horizons) {
      final m = toDouble(json['temperature_mae_$h']);
      if (m != null) mae[h] = m;
      final f = toDouble(json['rain_f1_$h']);
      if (f != null) f1[h] = f;
    }
    final targetMae = <String, Map<String, double>>{};
    for (final t in extraTargets) {
      final m = <String, double>{};
      for (final h in AIForecast.horizons) {
        final v = toDouble(json['${t}_mae_$h']);
        if (v != null) m[h] = v;
      }
      if (m.isNotEmpty) targetMae[t] = m;
    }
    final cov = <String, double>{};
    final width = <String, double>{};
    for (final h in AIForecast.horizons) {
      final v = toDouble(json['temperature_interval_coverage_$h']);
      if (v != null) cov[h] = v;
      final w = toDouble(json['temperature_interval_width_$h']);
      if (w != null) width[h] = w;
    }
    final beats = json['beats_baselines'];
    return AIEvaluation(
      targetMae: targetMae,
      intervalCoverage: cov,
      intervalNominalCoverage:
          toDouble(json['interval_level']) ??
          toDouble(json['interval_nominal_coverage']),
      intervalWidth: width,
      enabledTargets: AIForecast._stringList(json['enabled_targets']),
      cellId: json['cell_id']?.toString(),
      temperatureMae: mae,
      rainF1: f1,
      beatsBaselines: beats is bool ? beats : null,
      testPeriod: json['test_period']?.toString(),
    );
  }
}

/// Mot moc kiem chung (GET /weather/ai-verify -> horizons[]).
/// Cac truong "actual" la du lieu phan tich cua mo hinh, khong phai tram do;
/// null = chua co (moc chua toi hoac chua nap du lieu).
class AIVerificationItem {
  final String horizon; // "1h" | "3h" | "6h"
  final DateTime? targetTime; // gio TP.HCM
  final double? predictedTemperature;
  final double? predictedRainProbability; // 0-1
  final double? actualTemperature;
  final double? actualPrecipitation; // mm
  final bool? actualRain;
  final double? absErrorTemperature;

  const AIVerificationItem({
    required this.horizon,
    this.targetTime,
    this.predictedTemperature,
    this.predictedRainProbability,
    this.actualTemperature,
    this.actualPrecipitation,
    this.actualRain,
    this.absErrorTemperature,
  });

  bool get hasActual => actualTemperature != null || actualRain != null;

  int? get predictedRainPercent => toPercent(predictedRainProbability);

  /// Sai so tuyet doi: uu tien gia tri backend, neu thieu thi tu tinh.
  double? get temperatureError {
    if (absErrorTemperature != null) return absErrorTemperature;
    final p = predictedTemperature;
    final a = actualTemperature;
    return p == null || a == null ? null : (p - a).abs();
  }

  factory AIVerificationItem.fromJson(Map<String, dynamic> json) {
    final target = json['target_time'];
    final rain = json['actual_rain'];
    return AIVerificationItem(
      horizon: json['horizon']?.toString() ?? '',
      targetTime: target is String ? HcmTime.tryParse(target) : null,
      predictedTemperature: toDouble(json['predicted_temperature']),
      predictedRainProbability: toDouble(json['predicted_rain_probability'])
          ?.clamp(0.0, 1.0)
          .toDouble(),
      actualTemperature: toDouble(json['actual_temperature']),
      actualPrecipitation: toDouble(json['actual_precipitation']),
      actualRain: rain is bool ? rain : null,
      absErrorTemperature: toDouble(json['abs_error_temperature']),
    );
  }
}

// GET /weather/ai-verify
class AIVerification {
  final DateTime issuedAt; // gio TP.HCM
  final String modelVersion;
  final List<AIVerificationItem> horizons;
  final String verificationMode;
  final String? forecastSource;
  final String? actualSource;
  final String? unavailableReason;
  final DateTime? selectionCutoff;
  final DateTime? archivedAt;

  String get modeLabel => switch (verificationMode) {
    'archived' => 'Dự báo đã lưu',
    'retrospective' => 'Mô phỏng hồi cứu',
    'unavailable' => 'Chưa có dự báo để kiểm chứng',
    _ => 'Nguồn dự báo chưa xác định',
  };

  /// Danh gia mo hinh tai o luoi cua dia diem; null = chua co.
  final AIEvaluation? evaluation;

  const AIVerification({
    required this.issuedAt,
    required this.modelVersion,
    required this.horizons,
    this.evaluation,
    this.verificationMode = 'unspecified',
    this.forecastSource,
    this.actualSource,
    this.unavailableReason,
    this.selectionCutoff,
    this.archivedAt,
  });

  factory AIVerification.fromJson(Map<String, dynamic> json) {
    final raw = json['horizons'];
    final items = <AIVerificationItem>[];
    if (raw is List) {
      for (final h in raw) {
        if (h is Map<String, dynamic>) {
          items.add(AIVerificationItem.fromJson(h));
        }
      }
    }
    return AIVerification(
      issuedAt: requireDate(json, 'issued_at'),
      modelVersion: json['model_version']?.toString() ?? '',
      horizons: items,
      evaluation: AIEvaluation.tryParse(json['evaluation']),
      verificationMode: json['verification_mode']?.toString() ?? 'unspecified',
      forecastSource: json['forecast_source']?.toString(),
      actualSource: json['actual_source']?.toString(),
      unavailableReason: json['unavailable_reason']?.toString(),
      selectionCutoff: json['selection_cutoff'] is String
          ? HcmTime.tryParse(json['selection_cutoff'] as String)
          : null,
      archivedAt: json['archived_at'] is String
          ? HcmTime.tryParse(json['archived_at'] as String)
          : null,
    );
  }
}
