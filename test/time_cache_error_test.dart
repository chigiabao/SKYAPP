import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';

// Gio TP.HCM 2026-10-15 21:30 = 14:30 UTC
final _fakeNow = DateTime.utc(2026, 10, 15, 14, 30);
DateTime _clock() => _fakeNow;

Map<String, dynamic> _current(String ts) => {
  'timestamp': ts,
  'temperature': 27.0,
  'weather_code': 3,
  'wind_gusts': 12.1,
  'wind_direction': 221.0,
  'cloud_cover': 96.4,
  'precipitation': 0.2,
  'rain_probability': null,
};

Map<String, dynamic> _bundle({
  String currentTs = '2026-10-15T21:00:00+07:00',
}) => {
  'current': _current(currentTs),
  'hourly': [
    for (final h in [19, 20, 21, 22, 23])
      {
        'timestamp': '2026-10-15T$h:00:00+07:00',
        'temperature': 26.0,
        'weather_code': 3,
        'rain_probability': 0.35,
        'precipitation_median': 0.4,
      },
  ],
  'daily': [
    for (final d in [14, 15, 16])
      {
        'date': '2026-10-$d',
        'temperature_min': 24.0,
        'temperature_max': 31.0,
        'weather_code': 3,
        'rain_day_probability': 0.8,
        'precipitation_median': 5.5,
      },
  ],
  'ai': null,
};

http.Client _okClient(Map<String, dynamic> bundle) => MockClient((req) async {
  final body = switch (req.url.path) {
    '/weather/current' => bundle['current'],
    '/weather/hourly' => bundle['hourly'],
    '/weather/daily' => bundle['daily'],
    _ => null,
  };
  return body == null
      ? http.Response('{"detail":"Not Found"}', 404)
      : http.Response(jsonEncode(body), 200);
});

void main() {
  group('HcmTime.tryParse', () {
    test('naive, +07:00 and Z give the same HCMC wall clock', () {
      final naive = HcmTime.tryParse('2026-10-10T23:00:00')!;
      final offset = HcmTime.tryParse('2026-10-10T23:00:00+07:00')!;
      final zulu = HcmTime.tryParse('2026-10-10T16:00:00Z')!;
      expect(naive, offset);
      expect(offset, zulu);
      expect(naive.hour, 23);
      expect(naive.day, 10);
    });

    test('other offsets are converted to HCMC time', () {
      final t = HcmTime.tryParse('2026-10-10T18:00:00+02:00')!;
      expect(t.hour, 23);
    });

    test('date-only and fractional seconds', () {
      expect(HcmTime.tryParse('2026-10-15'), DateTime.utc(2026, 10, 15));
      expect(HcmTime.tryParse('2026-10-15T20:25:30.418316')!.minute, 25);
      expect(HcmTime.tryParse('not a date'), isNull);
      expect(HcmTime.tryParse(null), isNull);
    });

    test('now/instant round trip ignores device time zone', () {
      final wall = HcmTime.now(_clock);
      expect(wall.hour, 21);
      expect(HcmTime.toInstant(wall), _fakeNow);
      expect(HcmTime.now(() => _fakeNow.toLocal()), wall);
    });
  });

  group('Model fields (new backend contract)', () {
    test('hourly prefers rain_probability, falls back to percent', () {
      final a = HourlyForecast.fromJson({
        'timestamp': '2026-10-15T21:00:00+07:00',
        'temperature': 26,
        'rain_probability': 0.35,
        'precipitation_probability': 90,
        'precipitation_median': 0.4,
      });
      expect(a.rainProbability, 0.35);
      expect(a.rainPercent, 35);
      expect(a.precipitation, 35); // ten cu
      expect(a.precipitationMedian, 0.4);

      final b = HourlyForecast.fromJson({
        'timestamp': '2026-10-15T21:00:00',
        'temperature': 26,
        'precipitation_probability': 41.5,
      });
      expect(b.rainProbability, closeTo(0.415, 1e-9));
      expect(b.rainPercent, 42);
      expect(b.precipitationMedian, isNull);
    });

    test('daily rain_day_probability and current extra fields', () {
      final data = WeatherData.fromJson(_bundle(), locationName: 'HCM');
      final d = data.dailyForecast.first;
      expect(d.rainDayProbability, 0.8);
      expect(d.rainDayPercent, 80);
      expect(d.precipitationMedian, 5.5);
      final c = data.current;
      expect(c.windGusts, 12.1);
      expect(c.windDirection, 221.0);
      expect(c.cloudCover, 96);
      expect(c.precipitationMm, 0.2);
    });

    test('health with and without new fields', () {
      final h = BackendHealth.fromJson({
        'status': 'healthy',
        'latest_timestamp': '2026-10-10T23:00:00+07:00',
        'data_age_hours': 118.5,
      });
      expect(h.isHealthy, isTrue);
      expect(h.latestTimestamp, DateTime.utc(2026, 10, 10, 23));
      expect(h.dataAgeHours, 118.5);
      final old = BackendHealth.fromJson({'status': 'healthy'});
      expect(old.latestTimestamp, isNull);
    });
  });

  group('Stale detection (fake clock)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<WeatherProvider> load(String currentTs) async {
      final api = ApiService(
        client: _okClient(_bundle(currentTs: currentTs)),
        baseUrl: 'http://test',
        clock: _clock,
      );
      final p = WeatherProvider(
        apiService: api,
        clock: _clock,
        initialSettings: const AppSettings(),
      );
      await p.fetchWeatherData();
      return p;
    }

    test('fresh data within threshold is not stale', () async {
      final p = await load('2026-10-15T21:00:00+07:00'); // 30 phut truoc
      expect(p.isFromCache, isFalse);
      expect(p.isStale, isFalse);
    });

    test('naive timestamp is HCMC time, not device time', () async {
      final p = await load('2026-10-15T20:00:00'); // 1h30 truoc
      expect(p.isStale, isFalse);
    });

    test('old data is stale', () async {
      final p = await load('2026-10-15T17:00:00+07:00'); // 4h30 truoc
      expect(p.isStale, isTrue);
      final z = await load('2026-10-15T10:00:00Z'); // = 17:00 TP.HCM
      expect(z.isStale, isTrue);
    });
  });

  group('Cache v2', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round trip stores saved_at and drops past items', () async {
      final saveTime = DateTime.utc(2026, 10, 15, 12); // 19:00 TP.HCM
      await ApiService(
        client: _okClient(_bundle()),
        baseUrl: 'http://test',
        clock: () => saveTime,
      ).fetchWeatherData();

      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(
        prefs.getString(ApiService.cacheKey)!,
      ) as Map<String, dynamic>;
      expect(stored['saved_at'], saveTime.toIso8601String());
      expect(stored['payload'], isA<Map<String, dynamic>>());

      final offline = ApiService(
        client: MockClient((_) async => throw http.ClientException('down')),
        baseUrl: 'http://test',
        clock: _clock, // 21:30 TP.HCM
      );
      final result = await offline.fetchWithCacheFallback();
      expect(result.fromCache, isTrue);
      expect(result.savedAt, DateTime.utc(2026, 10, 15, 19));
      // 19h, 20h da qua; giu 21h (gio hien tai), 22h, 23h
      expect(result.data.hourlyForecast.map((h) => h.time.hour), [21, 22, 23]);
      // 14/10 da qua; giu hom nay 15/10 va 16/10
      expect(result.data.dailyForecast.map((d) => d.date.day), [15, 16]);
    });

    test('provider exposes isFromCache and cachedAt', () async {
      await ApiService(
        client: _okClient(_bundle()),
        baseUrl: 'http://test',
        clock: () => DateTime.utc(2026, 10, 15, 12),
      ).fetchWeatherData();
      final p = WeatherProvider(
        apiService: ApiService(
          client: MockClient((_) async => throw http.ClientException('down')),
          baseUrl: 'http://test',
          clock: _clock,
        ),
        clock: _clock,
        initialSettings: const AppSettings(),
      );
      await p.fetchWeatherData();
      expect(p.isFromCache, isTrue);
      expect(p.cachedAt, DateTime.utc(2026, 10, 15, 19));
      expect(p.isStale, isTrue);
      expect(p.error, contains('Đang hiển thị dữ liệu đã lưu'));
      expect(p.error, isNot(contains('ClientException')));
    });

    test('v1 cache is ignored', () async {
      SharedPreferences.setMockInitialValues({
        'weather_cache_v1': jsonEncode(_bundle()),
      });
      final offline = ApiService(
        client: MockClient((_) async => throw http.ClientException('down')),
        baseUrl: 'http://test',
      );
      expect(await offline.loadCachedResult(), isNull);
    });
  });

  group('Error mapping', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ApiException> errorFor(
      http.Client client, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final api = ApiService(
        client: client,
        baseUrl: 'http://test',
        timeout: timeout,
      );
      try {
        await api.fetchWeatherData();
      } on ApiException catch (e) {
        return e;
      }
      fail('expected ApiException');
    }

    test('network', () async {
      final e = await errorFor(
        MockClient(
          (_) async => throw http.ClientException('SocketException: x'),
        ),
      );
      expect(e.kind, ApiErrorKind.network);
      expect(e.message, isNot(contains('Socket')));
    });

    test('timeout', () async {
      final e = await errorFor(
        MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 10),
      );
      expect(e.kind, ApiErrorKind.timeout);
      expect(e.message, 'Máy chủ không phản hồi.');
    });

    test('5xx', () async {
      final e = await errorFor(
        MockClient((_) async => http.Response('Internal Server Error', 500)),
      );
      expect(e.kind, ApiErrorKind.server);
      expect(e.message, 'Máy chủ đang gặp lỗi.');
    });

    test('invalid data', () async {
      final notJson = await errorFor(
        MockClient((_) async => http.Response('<html>', 200)),
      );
      expect(notJson.kind, ApiErrorKind.invalidData);
      final wrongShape = await errorFor(
        MockClient((_) async => http.Response('[]', 200)),
      );
      expect(wrongShape.kind, ApiErrorKind.invalidData);
      expect(wrongShape.message, 'Dữ liệu từ máy chủ không hợp lệ.');
    });
  });

  group('AppSettings', () {
    test('migrates legacy isDarkMode and reads themeMode', () async {
      SharedPreferences.setMockInitialValues({'isDarkMode': true});
      expect(
        AppSettings.fromPrefs(await SharedPreferences.getInstance()).themeMode,
        ThemeMode.dark,
      );
      SharedPreferences.setMockInitialValues({
        'themeMode': 'system',
        'isCelsius': false,
      });
      final s = AppSettings.fromPrefs(await SharedPreferences.getInstance());
      expect(s.themeMode, ThemeMode.system);
      expect(s.isCelsius, isFalse);
    });

    test('provider persists theme mode', () async {
      SharedPreferences.setMockInitialValues({});
      final p = WeatherProvider(initialSettings: const AppSettings());
      p.setThemeMode(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('themeMode'), 'dark');
    });
  });
}
