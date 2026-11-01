import '../data_source.dart';
import 'weather_condition.dart';
import 'weather_helpers.dart';

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

  /// Khoang du bao AI dai han (chi gio `ai`): can duoi/tren theo muc
  /// [intervalLevel] (vd 0,8 = khoang 80%, la muc bat dinh, khong phai do
  /// chinh xac). null = moc nay khong co khoang (chua dat kiem chung).
  final double? temperatureP10;
  final double? temperatureP90;
  final double? humidityP10;
  final double? humidityP90;
  final double? windSpeedP10;
  final double? windSpeedP90;

  /// Can tren luong mua (mm, mot phia).
  final double? precipitationP90;
  final double? intervalLevel;

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
    this.temperatureP10,
    this.temperatureP90,
    this.humidityP10,
    this.humidityP90,
    this.windSpeedP10,
    this.windSpeedP90,
    this.precipitationP90,
    this.intervalLevel,
  }) : rainProbability =
           rainProbability ??
           (precipitation == null ? null : precipitation / 100);

  /// Xac suat mua, % (0-100); 0 neu khong co du lieu.
  int get rainPercent => toPercent(rainProbability) ?? 0;

  /// Ten cu (giu tuong thich voi widget): xac suat mua %, KHONG phai mm.
  /// Dung [rainPercent] cho code moi.
  int get precipitation => rainPercent;

  factory HourlyForecast.fromJson(Map<String, dynamic> json) {
    return HourlyForecast(
      time: requireDate(json, 'timestamp'),
      temperature: requireDouble(json, 'temperature'),
      condition: conditionFromWmo(toInt(json['weather_code'])),
      rainProbability: probability(
        json,
        'rain_probability',
        'precipitation_probability',
      ),
      precipitationMedian: toDouble(json['precipitation_median']),
      windSpeed: toDouble(json['wind_speed']),
      windGusts: toDouble(json['wind_gusts']),
      windDirection: toDouble(json['wind_direction']),
      source: parseDataSource(json['source']),
      uvIndex: toDouble(json['uv_index']),
      usAqi: toInt(json['us_aqi']),
      precipitationMm: toDouble(json['precipitation']),
      weatherCode: toInt(json['weather_code']),
      humidity: toDouble(json['humidity']),
      apparentTemperature: toDouble(json['apparent_temperature']),
      temperatureP10: toDouble(json['temperature_p10']),
      temperatureP90: toDouble(json['temperature_p90']),
      humidityP10: toDouble(json['humidity_p10']),
      humidityP90: toDouble(json['humidity_p90']),
      windSpeedP10: toDouble(json['wind_speed_p10']),
      windSpeedP90: toDouble(json['wind_speed_p90']),
      precipitationP90: toDouble(json['precipitation_p90']),
      intervalLevel: toDouble(json['interval_level']),
    );
  }

  /// Co khoang nhiet do hop le (p10 <= p90).
  bool get hasTemperatureInterval =>
      temperatureP10 != null &&
      temperatureP90 != null &&
      temperatureP10! <= temperatureP90!;

  /// Gio "thuc te": xac suat mua chi la 1/0, nen hien luong mua (mm).
  bool get isObserved => source == DataSource.observed;
}
