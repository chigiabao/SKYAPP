import '../hcm_time.dart';
import 'ai_forecast.dart';
import 'current_weather.dart';
import 'daily_forecast.dart';
import 'hourly_forecast.dart';
import 'weather_helpers.dart';

// Complete weather data wrapper
class WeatherData {
  final CurrentWeather current;
  final List<HourlyForecast> hourlyForecast;
  final List<DailyForecast> dailyForecast;
  final AIForecast? aiForecast; // null = chua co du bao AI
  final String? forecastError;

  /// Chi tiet 503 cua AI 1/3/6h (`ai_error` trong /weather/bundle); chi dung
  /// de chon cau giai thich co dinh, khong hien nguyen van.
  final String? aiError;

  const WeatherData({
    required this.current,
    required this.hourlyForecast,
    required this.dailyForecast,
    this.aiForecast,
    this.forecastError,
    this.aiError,
  });

  /// Parse tu goi JSON tong hop {current, hourly, daily, ai} (cung la dinh dang cache).
  factory WeatherData.fromJson(Map<String, dynamic> json) {
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
      current: CurrentWeather.fromJson(json['current'] as Map<String, dynamic>),
      hourlyForecast: _parseList(json['hourly'], HourlyForecast.fromJson),
      dailyForecast: _parseList(json['daily'], DailyForecast.fromJson),
      aiForecast: aiForecast,
      forecastError: json['forecast_error'] is String
          ? json['forecast_error'] as String
          : null,
      aiError: json['ai_error'] is String ? json['ai_error'] as String : null,
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
      forecastError: forecastError,
      aiError: aiError,
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
      dataAgeHours: toDouble(json['data_age_hours']),
    );
  }
}
