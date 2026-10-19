import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';

/// Du lieu gia CHI dung trong test (dinh dang giong backend).
/// Gio that 15/10/2026 20:00 TP.HCM.
DateTime _clock() => DateTime.utc(2026, 10, 15, 13);

String _ts(int h) {
  final t = DateTime.utc(2026, 10, 15, 20).add(Duration(hours: h));
  return t.toIso8601String().substring(0, 19);
}

Map<String, dynamic> _current(double temp) => {
  'timestamp': _ts(0),
  'temperature': temp,
  'weather_code': 3,
};

List<Map<String, dynamic>> _hourly(int n) => [
  for (var i = 0; i < n; i++)
    {'timestamp': _ts(i), 'temperature': 27.0, 'weather_code': 3},
];

final List<Map<String, dynamic>> _daily = [
  {
    'date': '2026-10-15',
    'temperature_min': 24.0,
    'temperature_max': 31.0,
    'weather_code': 3,
  },
];

Map<String, dynamic> _bundle(double temp, String id) => {
  'location_id': id,
  'cell_id': 'c1',
  'generated_at': '2026-10-15T20:00:00+07:00',
  'current': _current(temp),
  'hourly': _hourly(48),
  'daily': _daily,
  'ai_forecast': null,
  'ai_error': 'not ready',
};

http.Response _json(Object o) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  200,
  headers: {'content-type': 'application/json'},
);

/// Backend moi: /weather/bundle; [gate] giu request den khi hoan tat.
MockClient _bundleClient(double temp, List<Uri> log, {Completer<void>? gate}) =>
    MockClient((req) async {
      log.add(req.url);
      if (gate != null) await gate.future;
      if (req.url.path == '/weather/bundle') {
        return _json(_bundle(temp, req.url.queryParameters['location_id']!));
      }
      return http.Response('{"detail":"Not Found"}', 404);
    });

WeatherProvider _provider(http.Client client, {DateTime? replayAt}) =>
    WeatherProvider(
      apiService: ApiService(
        client: client,
        baseUrl: 'http://test',
        clock: _clock,
      ),
      initialSettings: AppSettings(
        replayEnabled: replayAt != null,
        replayAt: replayAt,
      ),
      clock: _clock,
    );

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('48 gio theo gio, query bundle dung tham so', () async {
    expect(ApiConfig.hourlyHours, 48);
    final log = <Uri>[];
    final p = _provider(_bundleClient(30, log));
    await p.fetchWeatherData();
    expect(p.hourlyForecast, hasLength(48));
    expect(log, hasLength(1));
    expect(log.single.path, '/weather/bundle');
    expect(log.single.queryParameters, {
      'location_id': 'tsn',
      'hours': '48',
      'days': '7',
    });
    expect(p.aiForecast, isNull);
  });

  test('co cache: hien ngay (isRefreshing) roi cap nhat tu mang', () async {
    // Lan 1 ghi cache (20 do).
    await _provider(_bundleClient(20, [])).fetchWeatherData();

    final gate = Completer<void>();
    final p = _provider(_bundleClient(30, [], gate: gate));
    final done = p.fetchWeatherData();
    await _flush();
    expect(p.currentWeather!.temperature, 20);
    expect(p.isFromCache, isTrue);
    expect(p.isRefreshing, isTrue);
    expect(p.cachedAt, isNotNull);
    expect(p.isStale, isFalse);

    gate.complete();
    await done;
    expect(p.currentWeather!.temperature, 30);
    expect(p.isFromCache, isFalse);
    expect(p.isRefreshing, isFalse);
    expect(p.cachedAt, isNull);
  });

  test('loi mang khi dang hien cache: giu "Dữ liệu cũ"', () async {
    await _provider(_bundleClient(20, [])).fetchWeatherData();
    final p = _provider(
      MockClient((_) async => throw http.ClientException('down')),
    );
    await p.fetchWeatherData();
    expect(p.currentWeather!.temperature, 20);
    expect(p.isFromCache, isTrue);
    expect(p.isStale, isTrue);
    expect(p.error, contains('dữ liệu đã lưu'));
  });

  test('bundle 404 / 405 -> quay ve 4 API le (nho cho lan sau)', () async {
    for (final code in [404, 405]) {
      final log = <String>[];
      final api = ApiService(
        client: MockClient((req) async {
          log.add(req.url.path);
          switch (req.url.path) {
            case '/weather/current':
              return _json(_current(25));
            case '/weather/hourly':
              return _json(_hourly(48));
            case '/weather/daily':
              return _json(_daily);
          }
          return http.Response('{"detail":"Not Found"}', code);
        }),
        baseUrl: 'http://test',
        clock: _clock,
      );
      final data = await api.fetchWeatherData();
      expect(data.current.temperature, 25);
      expect(data.hourlyForecast, hasLength(48));
      expect(log.first, '/weather/bundle');
      expect(log.skip(1).toSet(), {
        '/weather/current',
        '/weather/hourly',
        '/weather/daily',
        '/weather/ai-forecast',
      });
      log.clear();
      await api.fetchWeatherData();
      expect(log, isNot(contains('/weather/bundle')));
    }
  });

  test('che do xem lai: khong doc, khong ghi cache', () async {
    await _provider(_bundleClient(20, [])).fetchWeatherData();
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(ApiService.cacheKey);

    final gate = Completer<void>();
    final log = <Uri>[];
    final p = _provider(
      _bundleClient(30, log, gate: gate),
      replayAt: DateTime.utc(2026, 10, 15, 20),
    );
    final done = p.fetchWeatherData();
    await _flush();
    expect(p.weatherData, isNull);
    expect(p.isRefreshing, isFalse);
    gate.complete();
    await done;
    expect(p.currentWeather!.temperature, 30);
    expect(p.isFromCache, isFalse);
    expect(log.single.queryParameters['at'], '2026-10-15T20:00:00+07:00');
    expect(prefs.getString(ApiService.cacheKey), before);
  });

  test('tai truoc trang ke ben; doi trang hien ngay, khong tai lai', () async {
    final log = <Uri>[];
    final p = _provider(_bundleClient(30, log))
      ..pageIds = () => ['a', 'tsn', 'b', 'c'];
    await p.fetchWeatherData();
    await _flush();
    final ids = log.map((u) => u.queryParameters['location_id']).toList();
    expect(ids, ['tsn', 'b', 'a']);

    log.clear();
    p.setLocation('b');
    expect(p.weatherData, isNotNull);
    expect(p.isLoading, isFalse);
    await _flush();
    // Chi tai truoc 'c' (tsn vua tai, con moi).
    expect(log.map((u) => u.queryParameters['location_id']), ['c']);
  });
}
