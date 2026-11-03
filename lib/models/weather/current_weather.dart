import '../data_source.dart';
import '../hcm_time.dart';
import 'weather_condition.dart';
import 'weather_helpers.dart';

class CurrentFieldSource {
  const CurrentFieldSource({required this.source, required this.timestamp});

  final String source;
  final DateTime timestamp;

  static Map<String, CurrentFieldSource> parse(dynamic value) {
    if (value is! Map) return const {};
    final result = <String, CurrentFieldSource>{};
    for (final entry in value.entries) {
      final item = entry.value;
      if (entry.key is! String || item is! Map) continue;
      final source = item['source'];
      final time = item['timestamp'];
      final parsed = time is String ? HcmTime.tryParse(time) : null;
      if (source is! String || source.isEmpty || parsed == null) continue;
      result[entry.key as String] = CurrentFieldSource(
        source: source,
        timestamp: parsed,
      );
    }
    return Map.unmodifiable(result);
  }
}

// Current weather data model (GET /weather/current)
class CurrentWeather {
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
  final Map<String, CurrentFieldSource> fieldSources;

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
    this.fieldSources = const {},
    this.uvIndex,
    this.usAqi,
    this.pm25,
    this.pm10,
    this.weatherCode,
    this.dewPoint,
  });

  factory CurrentWeather.fromJson(Map<String, dynamic> json) {
    final visibilityM = toDouble(json['visibility']);
    return CurrentWeather(
      temperature: requireDouble(json, 'temperature'),
      feelsLike: toDouble(json['apparent_temperature']),
      condition: conditionFromWmo(toInt(json['weather_code'])),
      humidity: toInt(json['humidity']),
      windSpeed: toDouble(json['wind_speed']),
      windGusts: toDouble(json['wind_gusts']),
      windDirection: toDouble(json['wind_direction']),
      cloudCover: toInt(json['cloud_cover']),
      precipitationMm: toDouble(json['precipitation']),
      pressure:
          toDouble(json['pressure_msl']) ?? toDouble(json['surface_pressure']),
      visibilityKm: visibilityM == null ? null : visibilityM / 1000,
      precipitationProbability: toPercent(
        probability(json, 'rain_probability', 'precipitation_probability'),
      ),
      lastUpdated: requireDate(json, 'timestamp'),
      source: parseDataSource(json['source']),
      fieldSources: CurrentFieldSource.parse(json['field_sources']),
      uvIndex: toDouble(json['uv_index']),
      usAqi: toInt(json['us_aqi']),
      pm25: toDouble(json['pm2_5']),
      pm10: toDouble(json['pm10']),
      weatherCode: toInt(json['weather_code']),
      dewPoint: toDouble(json['dew_point']),
    );
  }
}
