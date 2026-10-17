import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/services/api_service.dart';

// Fixture lay tu backend that (curl /weather/current, /hourly, /daily) ngay 15/10/2026.
const _currentJson = '''
{"timestamp":"2026-10-10T23:00:00","temperature":26.2,"humidity":93.0,"dew_point":24.9,
"apparent_temperature":32.6,"precipitation_probability":15.0,"precipitation":0.0,"rain":0.0,
"weather_code":3,"visibility":16960.0,"cloud_cover":91.0,"surface_pressure":1010.6,
"pressure_msl":1011.3,"wind_speed":1.8,"wind_direction":101.0,"wind_gusts":7.6}
''';

const _hourlyJson = '''
[{"timestamp":"2026-10-15T20:25:30.418316","temperature":26.0,"humidity":89.8,"dew_point":24.2,
"apparent_temperature":31.1,"precipitation_probability":41.5,"precipitation":1.01,"rain":1.01,
"weather_code":3,"visibility":25464.0,"cloud_cover":98.0,"surface_pressure":1008.2,
"pressure_msl":1008.9,"wind_speed":7.1,"wind_direction":224.0,"wind_gusts":12.1},
{"timestamp":"2026-10-15T21:25:30.418316","temperature":null,"weather_code":null}]
''';

const _dailyJson = '''
[{"date":"2026-10-15","temperature_min":24.0,"temperature_max":30.4,"temperature_avg":26.6,
"humidity_avg":86.5,"precipitation_total":13.49,"weather_code":3,"wind_speed_max":14.4,
"cloud_cover_avg":88.8}]
''';

const _aiJson = '''
{"issued_at":"2026-10-15T20:00:00","model_version":"v1",
"predictions":{"1h":{"temperature":27.1,"rain_probability":0.42},
"3h":{"temperature":26.0,"rain_probability":0.6},"6h":{"temperature":25.2,"rain_probability":0.1}}}
''';

http.Client _client({bool aiAvailable = false, bool down = false}) {
  return MockClient((request) async {
    if (down) throw http.ClientException('connection refused');
    switch (request.url.path) {
      case '/weather/current':
        return http.Response(_currentJson, 200);
      case '/weather/hourly':
        return http.Response(_hourlyJson, 200);
      case '/weather/daily':
        return http.Response(_dailyJson, 200);
      case '/weather/ai-forecast':
        return aiAvailable
            ? http.Response(_aiJson, 200)
            : http.Response('{"detail":"Not Found"}', 404);
    }
    return http.Response('', 404);
  });
}

void main() {
  group('WMO mapping', () {
    test('maps code ranges to conditions', () {
      expect(conditionFromWmo(0), WeatherCondition.sunny);
      expect(conditionFromWmo(1), WeatherCondition.partlyCloudy);
      expect(conditionFromWmo(2), WeatherCondition.partlyCloudy);
      expect(conditionFromWmo(3), WeatherCondition.cloudy);
      expect(conditionFromWmo(45), WeatherCondition.foggy);
      expect(conditionFromWmo(48), WeatherCondition.foggy);
      expect(conditionFromWmo(51), WeatherCondition.drizzle);
      expect(conditionFromWmo(57), WeatherCondition.drizzle);
      expect(conditionFromWmo(61), WeatherCondition.rainy);
      expect(conditionFromWmo(67), WeatherCondition.rainy);
      expect(conditionFromWmo(80), WeatherCondition.showers);
      expect(conditionFromWmo(82), WeatherCondition.showers);
      expect(conditionFromWmo(95), WeatherCondition.thunderstorm);
      expect(conditionFromWmo(99), WeatherCondition.thunderstorm);
      expect(conditionFromWmo(null), WeatherCondition.cloudy);
    });

    test('Vietnamese labels', () {
      expect(WeatherCondition.sunny.description, 'Trời quang');
      expect(WeatherCondition.drizzle.description, 'Mưa phùn');
      expect(WeatherCondition.showers.description, 'Mưa rào');
      expect(WeatherCondition.thunderstorm.description, 'Dông bão');
    });
  });

  group('JSON parsing', () {
    test('current weather', () {
      final c = CurrentWeather.fromJson(
        jsonDecode(_currentJson) as Map<String, dynamic>,
        locationName: 'HCM',
      );
      expect(c.temperature, 26.2);
      expect(c.feelsLike, 32.6);
      expect(c.humidity, 93);
      expect(c.windSpeed, 1.8);
      expect(c.pressure, 1011.3);
      expect(c.visibilityKm, closeTo(16.96, 1e-9));
      expect(c.condition, WeatherCondition.cloudy);
      expect(c.lastUpdated, DateTime.utc(2026, 10, 10, 23));
    });

    test('current weather tolerates null optional fields', () {
      final c = CurrentWeather.fromJson({
        'timestamp': '2026-10-10T23:00:00',
        'temperature': 26,
        'humidity': null,
      }, locationName: 'HCM');
      expect(c.humidity, isNull);
      expect(c.pressure, isNull);
      expect(c.feelsLike, isNull);
    });

    test('hourly skips entries with null temperature', () {
      final data = WeatherData.fromJson({
        'current': jsonDecode(_currentJson),
        'hourly': jsonDecode(_hourlyJson),
        'daily': jsonDecode(_dailyJson),
        'ai': null,
      }, locationName: 'HCM');
      expect(data.hourlyForecast, hasLength(1));
      expect(data.hourlyForecast.first.precipitation, 42); // 41.5 -> 42 %
      expect(data.dailyForecast.single.precipitationMm, 13.49);
      expect(data.dailyForecast.single.humidity, 87);
      expect(data.aiForecast, isNull);
    });

    test('AI forecast', () {
      final ai = AIForecast.fromJson(
        jsonDecode(_aiJson) as Map<String, dynamic>,
      );
      expect(ai.modelVersion, 'v1');
      expect(ai.predictions.map((p) => p.timeLabel), ['1h', '3h', '6h']);
      expect(ai.predictions.first.temperature, 27.1);
      expect(ai.predictions.first.rainPercent, 42);
    });
  });

  group('ApiService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('AI endpoint 404 -> aiForecast null, rest loads', () async {
      final api = ApiService(client: _client(), baseUrl: 'http://test');
      final data = await api.fetchWeatherData();
      expect(data.aiForecast, isNull);
      expect(data.current.temperature, 26.2);
    });

    test('AI endpoint available', () async {
      final api = ApiService(
        client: _client(aiAvailable: true),
        baseUrl: 'http://test',
      );
      final data = await api.fetchWeatherData();
      expect(data.aiForecast?.predictions, hasLength(3));
    });

    test('offline falls back to cache, else throws', () async {
      final offline = ApiService(
        client: _client(down: true),
        baseUrl: 'http://test',
      );
      await expectLater(
        offline.fetchWithCacheFallback(),
        throwsA(isA<ApiException>()),
      );

      await ApiService(
        client: _client(),
        baseUrl: 'http://test',
      ).fetchWeatherData();
      final result = await offline.fetchWithCacheFallback();
      expect(result.fromCache, isTrue);
      expect(result.data.current.lastUpdated, DateTime.utc(2026, 10, 10, 23));
    });
  });
}
