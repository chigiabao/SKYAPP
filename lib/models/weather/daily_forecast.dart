import '../data_source.dart';
import 'weather_condition.dart';
import 'weather_helpers.dart';

/// Do tin cay cua mot ngay du bao (truong `confidence` cua /weather/daily):
/// AI thang trung binh nhieu nam ro (high), nhinh chut (medium) hay gan bang /
/// thua (low). Backend cu khong gui -> null.
enum ForecastConfidence { high, medium, low }

ForecastConfidence? parseForecastConfidence(dynamic value) {
  if (value is! String) return null;
  switch (value.trim().toLowerCase()) {
    case 'high':
      return ForecastConfidence.high;
    case 'medium':
      return ForecastConfidence.medium;
    case 'low':
      return ForecastConfidence.low;
  }
  return null;
}

// Daily model (GET /weather/daily). Nguon tung muc: [source].
class DailyForecast {
  final DateTime date; // 00:00 gio TP.HCM, xem HcmTime
  final double tempMin;
  final double tempMax;
  final WeatherCondition condition;
  final double? precipitationMm; // null = chua co tong luong mua ca ngay
  final int? humidity;
  final double? windSpeed; // km/h (max)
  final double? windGusts; // km/h (wind_gusts_max)
  final double? uvIndexMax; // tuy chon
  final int? usAqiMax; // tuy chon

  /// Xac suat ngay co mua 0-1 - tuy chon. Y nghia theo [source]:
  /// forecast / ai -> xac suat mua theo gio lon nhat; observed -> 1.0/0.0 (co mua
  /// >= 1 mm hay khong); climatology -> ti le so nam co mua.
  final double? rainDayProbability;

  /// observed / forecast / climatology; null = backend cu (khong gui).
  final DataSource? source;

  /// Luong mua trung vi trong ngay (mm) - tuy chon, backend moi.
  final double? precipitationMedian;

  /// Ma thoi tiet WMO goc (weather_code); null = backend khong gui.
  final int? weatherCode;

  /// Do tin cay theo tam du bao; null = backend cu (khong gui).
  final ForecastConfidence? confidence;

  /// Ghi chu ngan (tieng Viet) ve ky nang du bao cua ngay nay; tuy chon.
  final String? skillNote;

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
    this.confidence,
    this.skillNote,
  });

  /// Ngay "xu huong": gan voi trung binh nhieu nam, khong nen doc nhu du bao.
  bool get isLowConfidence => confidence == ForecastConfidence.low;

  /// Ma WMO de ve icon: ngay xu huong khong ve mua/dong cu the (ma >= 51)
  /// ma dung icon chung "nhieu may"; % mua hien rieng. null = khong co ma.
  int? get displayWeatherCode {
    final code = weatherCode;
    return code != null && isLowConfidence && code >= 51 ? 3 : code;
  }

  /// Xac suat ngay co mua, % (0-100); null neu backend khong gui.
  int? get rainDayPercent => toPercent(rainDayProbability);

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
      date: requireDate(json, 'date'),
      tempMin: requireDouble(json, 'temperature_min'),
      tempMax: requireDouble(json, 'temperature_max'),
      condition: conditionFromWmo(toInt(json['weather_code'])),
      precipitationMm: toDouble(json['precipitation_total']),
      humidity: toInt(json['humidity_avg']),
      windSpeed: toDouble(json['wind_speed_max']),
      windGusts: toDouble(json['wind_gusts_max']),
      uvIndexMax: toDouble(json['uv_index_max']),
      usAqiMax: toInt(json['us_aqi_max']),
      rainDayProbability: toDouble(json['rain_day_probability'])
          ?.clamp(0.0, 1.0)
          .toDouble(),
      precipitationMedian: toDouble(json['precipitation_median']),
      source: parseDataSource(json['source']),
      weatherCode: toInt(json['weather_code']),
      confidence: parseForecastConfidence(json['confidence']),
      skillNote:
          json['skill_note'] is String &&
              (json['skill_note'] as String).trim().isNotEmpty
          ? (json['skill_note'] as String).trim()
          : null,
    );
  }
}
