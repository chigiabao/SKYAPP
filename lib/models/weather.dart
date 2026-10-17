import 'package:flutter/material.dart';

import 'data_source.dart';
import 'hcm_time.dart';

export 'data_source.dart';
export 'hcm_time.dart';

// Weather condition enum with icons
enum WeatherCondition {
  sunny,
  partlyCloudy,
  cloudy,
  drizzle,
  rainy,
  showers,
  thunderstorm,
  foggy,
  windy,
}

/// Map WMO weather code (Open-Meteo) sang WeatherCondition.
/// null hoac ma khong ho tro -> cloudy (trung tinh).
WeatherCondition conditionFromWmo(int? code) {
  if (code == null) return WeatherCondition.cloudy;
  if (code == 0) return WeatherCondition.sunny;
  if (code == 1 || code == 2) return WeatherCondition.partlyCloudy;
  if (code == 3) return WeatherCondition.cloudy;
  if (code == 45 || code == 48) return WeatherCondition.foggy;
  if (code >= 51 && code <= 57) return WeatherCondition.drizzle;
  if (code >= 61 && code <= 67) return WeatherCondition.rainy;
  if (code >= 80 && code <= 82) return WeatherCondition.showers;
  if (code >= 95 && code <= 99) return WeatherCondition.thunderstorm;
  return WeatherCondition.cloudy;
}

extension WeatherConditionExtension on WeatherCondition {
  String get description {
    switch (this) {
      case WeatherCondition.sunny:
        return 'Trời quang';
      case WeatherCondition.partlyCloudy:
        return 'Có mây';
      case WeatherCondition.cloudy:
        return 'Nhiều mây';
      case WeatherCondition.drizzle:
        return 'Mưa phùn';
      case WeatherCondition.rainy:
        return 'Có mưa';
      case WeatherCondition.showers:
        return 'Mưa rào';
      case WeatherCondition.thunderstorm:
        return 'Dông bão';
      case WeatherCondition.foggy:
        return 'Sương mù';
      case WeatherCondition.windy:
        return 'Gió lớn';
    }
  }

  IconData get icon {
    switch (this) {
      case WeatherCondition.sunny:
        return Icons.wb_sunny_rounded;
      case WeatherCondition.partlyCloudy:
        return Icons.wb_cloudy_rounded;
      case WeatherCondition.cloudy:
        return Icons.cloud_rounded;
      case WeatherCondition.drizzle:
        return Icons.grain_rounded;
      case WeatherCondition.rainy:
        return Icons.water_drop_rounded;
      case WeatherCondition.showers:
        return Icons.umbrella_rounded;
      case WeatherCondition.thunderstorm:
        return Icons.thunderstorm_rounded;
      case WeatherCondition.foggy:
        return Icons.foggy;
      case WeatherCondition.windy:
        return Icons.air_rounded;
    }
  }

  Color get color {
    switch (this) {
      case WeatherCondition.sunny:
        return const Color(0xFFFFB74D);
      case WeatherCondition.partlyCloudy:
        return const Color(0xFF90CAF9);
      case WeatherCondition.cloudy:
        return const Color(0xFF90A4AE);
      case WeatherCondition.drizzle:
        return const Color(0xFF81D4FA);
      case WeatherCondition.rainy:
        return const Color(0xFF4FC3F7);
      case WeatherCondition.showers:
        return const Color(0xFF29B6F6);
      case WeatherCondition.thunderstorm:
        return const Color(0xFF7E57C2);
      case WeatherCondition.foggy:
        return const Color(0xFFBDBDBD);
      case WeatherCondition.windy:
        return const Color(0xFF80DEEA);
    }
  }
}

// --- JSON helpers (cac truong tu backend co the null) ---

double? _toDouble(dynamic v) => v is num ? v.toDouble() : null;

int? _toInt(dynamic v) => v is num ? v.round() : null;

double _requireDouble(Map<String, dynamic> json, String key) {
  final v = _toDouble(json[key]);
  if (v == null) {
    throw FormatException('Thiếu trường bắt buộc "$key"');
  }
  return v;
}

/// Xac suat 0-1: uu tien [probKey] (0-1), neu khong co thi [percentKey] / 100.
double? _probability(
  Map<String, dynamic> json,
  String probKey,
  String percentKey,
) {
  final p = _toDouble(json[probKey]);
  if (p != null) return p.clamp(0.0, 1.0).toDouble();
  final percent = _toDouble(json[percentKey]);
  if (percent != null) return (percent / 100).clamp(0.0, 1.0).toDouble();
  return null;
}

int? _percent(double? probability) =>
    probability == null ? null : (probability * 100).round().clamp(0, 100);

/// Timestamp -> gio dong ho TP.HCM (xem [HcmTime]).
DateTime _requireDate(Map<String, dynamic> json, String key) {
  final v = json[key];
  final parsed = v is String ? HcmTime.tryParse(v) : null;
  if (parsed == null) {
    throw FormatException('Trường "$key" không hợp lệ: $v');
  }
  return parsed;
}

// Current weather data model (GET /weather/current)
class CurrentWeather {
  final String locationName;
  final double temperature;
  final double? feelsLike;
  final WeatherCondition condition;
  final int? humidity;
  final double? windSpeed; // km/h
  final double? windGusts; // km/h (wind_gusts)
  final double? windDirection; // do, 0 = Bac (wind_direction)
  final int? cloudCover; // % (cloud_cover)
  final double? precipitationMm; // mm trong gio (precipitation)
  final double? pressure; // hPa (pressure_msl)
  final double? visibilityKm;
  final int? precipitationProbability; // %

  /// Nguon so lieu (backend moi gui "observed"); null = backend cu.
  final DataSource? source;

  // Tuy chon (backend moi, co the null): chi so UV, AQI (thang US), bui min.
  final double? uvIndex;
  final int? usAqi;
  final double? pm25; // ug/m3 (pm2_5)
  final double? pm10; // ug/m3

  /// Ma thoi tiet WMO goc (weather_code); null = backend khong gui.
  final int? weatherCode;

  /// Diem suong (°C, dew_point) - tuy chon.
  final double? dewPoint;

  /// Timestamp cua du lieu (gio TP.HCM, xem [HcmTime]), khong phai gio tai.
  final DateTime lastUpdated;

  const CurrentWeather({
    required this.locationName,
    required this.temperature,
    required this.condition,
    required this.lastUpdated,
    this.feelsLike,
    this.humidity,
    this.windSpeed,
    this.windGusts,
    this.windDirection,
    this.cloudCover,
    this.precipitationMm,
    this.pressure,
    this.visibilityKm,
    this.precipitationProbability,
    this.source,
    this.uvIndex,
    this.usAqi,
    this.pm25,
    this.pm10,
    this.weatherCode,
    this.dewPoint,
  });

  factory CurrentWeather.fromJson(
    Map<String, dynamic> json, {
    required String locationName,
  }) {
    final visibilityM = _toDouble(json['visibility']);
    return CurrentWeather(
      locationName: locationName,
      temperature: _requireDouble(json, 'temperature'),
      feelsLike: _toDouble(json['apparent_temperature']),
      condition: conditionFromWmo(_toInt(json['weather_code'])),
      humidity: _toInt(json['humidity']),
      windSpeed: _toDouble(json['wind_speed']),
      windGusts: _toDouble(json['wind_gusts']),
      windDirection: _toDouble(json['wind_direction']),
      cloudCover: _toInt(json['cloud_cover']),
      precipitationMm: _toDouble(json['precipitation']),
      pressure:
          _toDouble(json['pressure_msl']) ??
          _toDouble(json['surface_pressure']),
      visibilityKm: visibilityM == null ? null : visibilityM / 1000,
      precipitationProbability: _percent(
        _probability(json, 'rain_probability', 'precipitation_probability'),
      ),
      lastUpdated: _requireDate(json, 'timestamp'),
      source: parseDataSource(json['source']),
      uvIndex: _toDouble(json['uv_index']),
      usAqi: _toInt(json['us_aqi']),
      pm25: _toDouble(json['pm2_5']),
      pm10: _toDouble(json['pm10']),
      weatherCode: _toInt(json['weather_code']),
      dewPoint: _toDouble(json['dew_point']),
    );
  }

  // Convert temperature based on unit
  double getTemperature(bool isCelsius) {
    if (isCelsius) return temperature;
    return (temperature * 9 / 5) + 32;
  }
}

// Hourly model (GET /weather/hourly). Nguon tung muc: [source].
class HourlyForecast {
  final DateTime time; // gio TP.HCM, xem HcmTime
  final double temperature;
  final WeatherCondition condition;

  /// Xac suat mua 0-1 (rain_probability, hoac precipitation_probability/100).
  /// null = backend khong gui.
  final double? rainProbability;

  /// Luong mua trung vi (mm) - tuy chon, backend moi.
  final double? precipitationMedian;

  final double? windSpeed; // km/h (wind_speed)
  final double? windGusts; // km/h (wind_gusts)
  final double? windDirection; // do, 0 = Bac (wind_direction)
  final double? uvIndex; // tuy chon
  final int? usAqi; // tuy chon

  /// Luong mua trong gio (mm, truong `precipitation`) - co nghia nhat voi
  /// gio "thuc te".
  final double? precipitationMm;

  /// observed / forecast / climatology; null = backend cu (khong gui).
  final DataSource? source;

  /// Ma thoi tiet WMO goc (weather_code); null = backend khong gui.
  final int? weatherCode;

  /// Do am tuong doi, % (humidity); null = backend khong gui.
  final double? humidity;

  /// Nhiet do cam giac, °C (apparent_temperature); null = khong co.
  final double? apparentTemperature;

  /// [precipitation]: ten cu, xac suat mua theo % (giu cho code goi cu);
  /// chi dung khi khong truyen [rainProbability].
  const HourlyForecast({
    required this.time,
    required this.temperature,
    required this.condition,
    double? rainProbability,
    int? precipitation,
    this.precipitationMedian,
    this.windSpeed,
    this.windGusts,
    this.windDirection,
    this.source,
    this.uvIndex,
    this.usAqi,
    this.precipitationMm,
    this.weatherCode,
    this.humidity,
    this.apparentTemperature,
  }) : rainProbability =
           rainProbability ??
           (precipitation == null ? null : precipitation / 100);

  /// Xac suat mua, % (0-100); 0 neu khong co du lieu.
  int get rainPercent => _percent(rainProbability) ?? 0;

  /// Ten cu (giu tuong thich voi widget): xac suat mua %, KHONG phai mm.
  /// Dung [rainPercent] cho code moi.
  int get precipitation => rainPercent;

  factory HourlyForecast.fromJson(Map<String, dynamic> json) {
    return HourlyForecast(
      time: _requireDate(json, 'timestamp'),
      temperature: _requireDouble(json, 'temperature'),
      condition: conditionFromWmo(_toInt(json['weather_code'])),
      rainProbability: _probability(
        json,
        'rain_probability',
        'precipitation_probability',
      ),
      precipitationMedian: _toDouble(json['precipitation_median']),
      windSpeed: _toDouble(json['wind_speed']),
      windGusts: _toDouble(json['wind_gusts']),
      windDirection: _toDouble(json['wind_direction']),
      source: parseDataSource(json['source']),
      uvIndex: _toDouble(json['uv_index']),
      usAqi: _toInt(json['us_aqi']),
      precipitationMm: _toDouble(json['precipitation']),
      weatherCode: _toInt(json['weather_code']),
      humidity: _toDouble(json['humidity']),
      apparentTemperature: _toDouble(json['apparent_temperature']),
    );
  }

  /// Gio "thuc te": xac suat mua chi la 1/0, nen hien luong mua (mm).
  bool get isObserved => source == DataSource.observed;

  double getTemperature(bool isCelsius) {
    if (isCelsius) return temperature;
    return (temperature * 9 / 5) + 32;
  }
}

// Daily model (GET /weather/daily). Nguon tung muc: [source].
class DailyForecast {
  final DateTime date; // 00:00 gio TP.HCM, xem HcmTime
  final double tempMin;
  final double tempMax;
  final WeatherCondition condition;
  final double precipitationMm; // tong luong mua trong ngay, mm
  final int? humidity;
  final double? windSpeed; // km/h (max)
  final double? windGusts; // km/h (wind_gusts_max)
  final double? uvIndexMax; // tuy chon
  final int? usAqiMax; // tuy chon

  /// Xac suat ngay co mua 0-1 - tuy chon. Y nghia theo [source]:
  /// forecast -> xac suat mua theo gio lon nhat; observed -> 1.0/0.0 (co mua
  /// >= 1 mm hay khong); climatology -> ti le so nam co mua.
  final double? rainDayProbability;

  /// observed / forecast / climatology; null = backend cu (khong gui).
  final DataSource? source;

  /// Luong mua trung vi trong ngay (mm) - tuy chon, backend moi.
  final double? precipitationMedian;

  /// Ma thoi tiet WMO goc (weather_code); null = backend khong gui.
  final int? weatherCode;

  const DailyForecast({
    required this.date,
    required this.tempMin,
    required this.tempMax,
    required this.condition,
    required this.precipitationMm,
    this.humidity,
    this.windSpeed,
    this.windGusts,
    this.rainDayProbability,
    this.precipitationMedian,
    this.source,
    this.uvIndexMax,
    this.usAqiMax,
    this.weatherCode,
  });

  /// Xac suat ngay co mua, % (0-100); null neu backend khong gui.
  int? get rainDayPercent => _percent(rainDayProbability);

  /// Ngay "thuc te": [rainDayProbability] la 1.0/0.0 (co mua >= 1 mm hay
  /// khong), nen hien "Có mưa"/"Không mưa" thay vi %.
  bool get isObserved => source == DataSource.observed;

  /// "Có mưa" / "Không mưa" cho ngay thuc te; null neu khong ap dung.
  String? get observedRainText {
    if (!isObserved || rainDayProbability == null) return null;
    return rainDayProbability! >= 0.5 ? 'Có mưa' : 'Không mưa';
  }

  factory DailyForecast.fromJson(Map<String, dynamic> json) {
    return DailyForecast(
      date: _requireDate(json, 'date'),
      tempMin: _requireDouble(json, 'temperature_min'),
      tempMax: _requireDouble(json, 'temperature_max'),
      condition: conditionFromWmo(_toInt(json['weather_code'])),
      precipitationMm: _toDouble(json['precipitation_total']) ?? 0,
      humidity: _toInt(json['humidity_avg']),
      windSpeed: _toDouble(json['wind_speed_max']),
      windGusts: _toDouble(json['wind_gusts_max']),
      uvIndexMax: _toDouble(json['uv_index_max']),
      usAqiMax: _toInt(json['us_aqi_max']),
      rainDayProbability: _toDouble(json['rain_day_probability'])
          ?.clamp(0.0, 1.0)
          .toDouble(),
      precipitationMedian: _toDouble(json['precipitation_median']),
      source: parseDataSource(json['source']),
      weatherCode: _toInt(json['weather_code']),
    );
  }

  double getTempMin(bool isCelsius) {
    if (isCelsius) return tempMin;
    return (tempMin * 9 / 5) + 32;
  }

  double getTempMax(bool isCelsius) {
    if (isCelsius) return tempMax;
    return (tempMax * 9 / 5) + 32;
  }
}

// AI prediction cho mot moc thoi gian (1h/3h/6h)
class AIPrediction {
  final String timeLabel; // "1h", "3h", "6h"
  final double temperature;
  final double rainProbability; // 0-1

  /// Thoi diem muc tieu (gio TP.HCM). Backend moi gui `target_time`; neu
  /// thieu thi tinh = issued_at + so gio cua moc. null neu khong suy ra duoc.
  final DateTime? targetTime;

  /// Khoang p10-p90 nhiet do (do C); null neu backend cu khong gui.
  final double? temperatureP10;
  final double? temperatureP90;

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
    this.humidity,
    this.windSpeed,
    this.windGusts,
    this.precipitationMm,
    this.uncertaintyNote,
  });

  /// Co khoang hop le (p10 <= p90).
  bool get hasInterval =>
      temperatureP10 != null &&
      temperatureP90 != null &&
      temperatureP10! <= temperatureP90!;

  /// "1h" -> 1, "6h" -> 6; null neu khong dung dinh dang.
  static int? horizonHours(String label) =>
      int.tryParse(label.toLowerCase().replaceAll('h', ''));

  int get rainPercent => (rainProbability * 100).round().clamp(0, 100);

  double getTemperature(bool isCelsius) {
    if (isCelsius) return temperature;
    return (temperature * 9 / 5) + 32;
  }
}

// GET /weather/ai-forecast
class AIForecast {
  static const List<String> horizons = ['1h', '3h', '6h'];

  final DateTime issuedAt; // gio TP.HCM, xem HcmTime
  final List<AIPrediction> predictions;
  final String modelVersion;

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
    final issuedAt = _requireDate(json, 'issued_at');
    final predictions = <AIPrediction>[];
    for (final label in horizons) {
      final p = raw[label];
      if (p is! Map) continue;
      final temp = _toDouble(p['temperature']);
      if (temp == null) continue;
      final target = p['target_time'];
      final hours = AIPrediction.horizonHours(label);
      predictions.add(
        AIPrediction(
          timeLabel: label,
          temperature: temp,
          rainProbability: _toDouble(p['rain_probability']) ?? 0,
          targetTime:
              (target is String ? HcmTime.tryParse(target) : null) ??
              (hours == null ? null : issuedAt.add(Duration(hours: hours))),
          temperatureP10: _toDouble(p['temperature_p10']),
          temperatureP90: _toDouble(p['temperature_p90']),
          humidity: _toDouble(p['humidity']),
          windSpeed: _toDouble(p['wind_speed']),
          windGusts: _toDouble(p['wind_gusts']),
          precipitationMm: _toDouble(p['precipitation_mm']),
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

  /// Ty le thuc te roi vao khoang p10-p90 tren tap kiem tra (0-1) theo moc.
  final Map<String, double> intervalCoverage;

  /// Do phu danh nghia cua khoang (vd 0,8); null neu khong co.
  final double? intervalNominalCoverage;

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
      final m = _toDouble(json['temperature_mae_$h']);
      if (m != null) mae[h] = m;
      final f = _toDouble(json['rain_f1_$h']);
      if (f != null) f1[h] = f;
    }
    final targetMae = <String, Map<String, double>>{};
    for (final t in extraTargets) {
      final m = <String, double>{};
      for (final h in AIForecast.horizons) {
        final v = _toDouble(json['${t}_mae_$h']);
        if (v != null) m[h] = v;
      }
      if (m.isNotEmpty) targetMae[t] = m;
    }
    final cov = <String, double>{};
    for (final h in AIForecast.horizons) {
      final v = _toDouble(json['temperature_interval_coverage_$h']);
      if (v != null) cov[h] = v;
    }
    final beats = json['beats_baselines'];
    return AIEvaluation(
      targetMae: targetMae,
      intervalCoverage: cov,
      intervalNominalCoverage: _toDouble(json['interval_nominal_coverage']),
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

  int? get predictedRainPercent => _percent(predictedRainProbability);

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
      predictedTemperature: _toDouble(json['predicted_temperature']),
      predictedRainProbability: _toDouble(json['predicted_rain_probability'])
          ?.clamp(0.0, 1.0)
          .toDouble(),
      actualTemperature: _toDouble(json['actual_temperature']),
      actualPrecipitation: _toDouble(json['actual_precipitation']),
      actualRain: rain is bool ? rain : null,
      absErrorTemperature: _toDouble(json['abs_error_temperature']),
    );
  }
}

// GET /weather/ai-verify
class AIVerification {
  final DateTime issuedAt; // gio TP.HCM
  final String modelVersion;
  final List<AIVerificationItem> horizons;

  /// Danh gia mo hinh tai o luoi cua dia diem; null = chua co.
  final AIEvaluation? evaluation;

  const AIVerification({
    required this.issuedAt,
    required this.modelVersion,
    required this.horizons,
    this.evaluation,
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
      issuedAt: _requireDate(json, 'issued_at'),
      modelVersion: json['model_version']?.toString() ?? '',
      horizons: items,
      evaluation: AIEvaluation.tryParse(json['evaluation']),
    );
  }
}

// Complete weather data wrapper
class WeatherData {
  final CurrentWeather current;
  final List<HourlyForecast> hourlyForecast;
  final List<DailyForecast> dailyForecast;
  final AIForecast? aiForecast; // null = chua co du bao AI

  const WeatherData({
    required this.current,
    required this.hourlyForecast,
    required this.dailyForecast,
    this.aiForecast,
  });

  /// Parse tu goi JSON tong hop {current, hourly, daily, ai} (cung la dinh dang cache).
  factory WeatherData.fromJson(
    Map<String, dynamic> json, {
    required String locationName,
  }) {
    final ai = json['ai'];
    AIForecast? aiForecast;
    if (ai is Map<String, dynamic>) {
      try {
        aiForecast = AIForecast.fromJson(ai);
      } on FormatException {
        aiForecast = null;
      }
    }
    return WeatherData(
      current: CurrentWeather.fromJson(
        json['current'] as Map<String, dynamic>,
        locationName: locationName,
      ),
      hourlyForecast: _parseList(json['hourly'], HourlyForecast.fromJson),
      dailyForecast: _parseList(json['daily'], DailyForecast.fromJson),
      aiForecast: aiForecast,
    );
  }

  /// Bo cac gio/ngay da qua so voi [nowHcm] (gio TP.HCM). Giu gio hien tai
  /// va ngay hom nay. Dung khi hien thi du lieu cache.
  WeatherData withoutPastItems(DateTime nowHcm) {
    final hourStart = HcmTime.startOfHour(nowHcm);
    final dayStart = HcmTime.startOfDay(nowHcm);
    return WeatherData(
      current: current,
      hourlyForecast: hourlyForecast
          .where((h) => !h.time.isBefore(hourStart))
          .toList(),
      dailyForecast: dailyForecast
          .where((d) => !HcmTime.startOfDay(d.date).isBefore(dayStart))
          .toList(),
      aiForecast: aiForecast,
    );
  }

  /// Bo qua phan tu loi (vd temperature null) thay vi lam hong ca danh sach.
  static List<T> _parseList<T>(
    dynamic raw,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (raw is! List) return [];
    final result = <T>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      try {
        result.add(parse(item));
      } on FormatException {
        // skip
      }
    }
    return result;
  }
}

// GET /health
class BackendHealth {
  final String status;
  final String? database;

  /// Moc du lieu moi nhat trong DB (gio TP.HCM) - backend moi, co the null.
  final DateTime? latestTimestamp;

  /// Do tre du lieu (gio) do backend tinh - backend moi, co the null.
  final double? dataAgeHours;

  const BackendHealth({
    required this.status,
    this.database,
    this.latestTimestamp,
    this.dataAgeHours,
  });

  bool get isHealthy => status == 'healthy';

  factory BackendHealth.fromJson(Map<String, dynamic> json) {
    final latest = json['latest_timestamp'];
    return BackendHealth(
      status: json['status']?.toString() ?? 'unknown',
      database: json['database']?.toString(),
      latestTimestamp: latest is String ? HcmTime.tryParse(latest) : null,
      dataAgeHours: _toDouble(json['data_age_hours']),
    );
  }
}
