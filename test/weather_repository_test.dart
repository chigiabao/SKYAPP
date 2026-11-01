import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';

import 'support/fake_weather_repository.dart';

// Du lieu gia CHI dung trong test (khong phai so lieu that).
final DateTime _now = DateTime.utc(2026, 10, 21, 5);

WeatherData _data() => WeatherData(
  current: CurrentWeather(
    temperature: 28,
    condition: WeatherCondition.cloudy,
    lastUpdated: HcmTime.now(() => _now),
  ),
  hourlyForecast: const [],
  dailyForecast: const [],
);

http.Response _json(Object o, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(o)),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _bundle(String id) => {
  'location_id': id,
  'current': {
    'timestamp': '2026-10-21T12:00:00',
    'temperature': 28.0,
    'weather_code': 3,
  },
  'hourly': [
    {'timestamp': '2026-10-21T12:00:00', 'temperature': 28.0},
  ],
  'daily': [
    {
      'date': '2026-10-21',
      'temperature_min': 24.0,
      'temperature_max': 31.0,
      'weather_code': 3,
    },
  ],
  'ai_forecast': null,
};

/// Nem [errors] lan luot roi tra du lieu.
FakeWeatherRepository _failing(List<Object> errors) {
  var i = 0;
  return FakeWeatherRepository(
    onFetch: (_, _) async {
      if (i < errors.length) throw errors[i++];
      return _data();
    },
  );
}

WeatherProvider _provider(FakeWeatherRepository api) => WeatherProvider(
  apiService: api,
  initialSettings: const AppSettings(),
  clock: () => _now,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('foreground retry (fake clock)', () {
    testWidgets('transient errors retry after 1 s then 3 s', (tester) async {
      final api = _failing([
        ApiException(ApiErrorKind.network),
        ApiException(ApiErrorKind.server, statusCode: 503),
      ]);
      final p = _provider(api);
      addTearDown(p.dispose);
      final done = p.fetchWeatherData();
      await tester.pump();
      expect(api.fetches, hasLength(1));
      await tester.pump(const Duration(milliseconds: 999));
      expect(api.fetches, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(api.fetches, hasLength(2));
      await tester.pump(const Duration(milliseconds: 2999));
      expect(api.fetches, hasLength(2));
      expect(p.isLoading, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      await done;
      expect(api.fetches, hasLength(3));
      expect(p.error, isNull);
      expect(p.currentWeather?.temperature, 28);
    });

    testWidgets('gives up after 2 retries and keeps the error', (tester) async {
      final api = FakeWeatherRepository(); // luon loi mang
      final p = _provider(api);
      addTearDown(p.dispose);
      final done = p.fetchWeatherData();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(api.fetches, hasLength(3));
      expect(p.errorKind, ApiErrorKind.network);
      await tester.pump(const Duration(seconds: 10));
      expect(api.fetches, hasLength(3));
    });

    testWidgets('dispose during the wait stops retrying', (tester) async {
      final api = FakeWeatherRepository();
      final p = _provider(api);
      final done = p.fetchWeatherData();
      await tester.pump();
      expect(api.fetches, hasLength(1));
      p.dispose();
      await tester.pump(const Duration(seconds: 5));
      await done;
      expect(api.fetches, hasLength(1));
    });

    testWidgets('a timeout is not retried (one slow bundle is enough)', (
      tester,
    ) async {
      final api = _failing([ApiException(ApiErrorKind.timeout)]);
      final p = _provider(api);
      addTearDown(p.dispose);
      await p.fetchWeatherData();
      expect(api.fetches, hasLength(1));
      expect(p.errorKind, ApiErrorKind.timeout);
      expect(p.isLoading, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(api.fetches, hasLength(1));
    });

    test('non-transient errors are not retried', () async {
      for (final e in [
        ApiException(ApiErrorKind.notFound, statusCode: 404),
        ApiException(ApiErrorKind.invalidData),
        ApiException(ApiErrorKind.server, statusCode: 418),
      ]) {
        final api = _failing([e]);
        final p = _provider(api);
        await p.fetchWeatherData();
        expect(api.fetches, hasLength(1), reason: '$e');
        expect(p.errorKind, e.kind);
        p.dispose();
      }
    });
  });

  group('shared repository ownership', () {
    test('providers do not close an injected repository', () {
      final api = FakeWeatherRepository();
      _provider(api).dispose();
      LocationProvider(apiService: api).dispose();
      expect(api.closed, isFalse);
    });
  });

  group('per-location cache eviction', () {
    test('removing a saved place evicts its cache', () async {
      final api = FakeWeatherRepository();
      final lp = LocationProvider(apiService: api, clock: () => _now);
      addTearDown(lp.dispose);
      lp.addSaved('p1');
      lp.addSaved('p2');
      lp.removeSavedAt(lp.saved.indexWhere((s) => s.locationId == 'p1'));
      lp.importSaved(const [SavedPlace(locationId: Place.defaultId)]);
      await Future<void>.delayed(Duration.zero);
      expect(api.evicted, ['p1', 'p2']);
    });

    test('ApiService.evictCache removes only that place', () async {
      SharedPreferences.setMockInitialValues({
        ApiService.cacheKey: 'default',
        ApiService.cacheKeyFor('p1'): 'p1',
        ApiService.cacheKeyFor('p2'): 'p2',
      });
      final api = ApiService(client: MockClient((_) async => _json({})));
      await api.evictCache('p1');
      await api.evictCache(Place.defaultId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        ApiService.cacheKey,
        ApiService.cacheKeyFor('p2'),
      });
    });

    test('a fetch still in flight when the place is evicted keeps no cache', () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<void>();
      final api = ApiService(
        baseUrl: 'http://test',
        clock: () => _now,
        client: MockClient((req) async {
          await gate.future;
          return _json(_bundle(req.url.queryParameters['location_id']!));
        }),
      );
      final pending = api.fetchWeatherDataFor('gone');
      await Future<void>.delayed(Duration.zero);
      await api.evictCache('gone');
      gate.complete();
      await pending;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(ApiService.cacheKeyFor('gone')), isFalse);
      // Tai lai sau khi xoa (vd. them lai dia diem) thi luu cache binh thuong.
      await api.fetchWeatherDataFor('gone');
      expect(prefs.containsKey(ApiService.cacheKeyFor('gone')), isTrue);
    });

    test('maxLocationCaches keeps the newest place caches', () async {
      var now = _now;
      final api = ApiService(
        baseUrl: 'http://test',
        clock: () => now,
        maxLocationCaches: 2,
        client: MockClient(
          (req) async =>
              _json(_bundle(req.url.queryParameters['location_id']!)),
        ),
      );
      for (final id in ['a', 'b', Place.defaultId, 'c', 'd']) {
        await api.fetchWeatherDataFor(id);
        now = now.add(const Duration(minutes: 1));
      }
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith(ApiService.cacheKey)).toSet(),
        {
          ApiService.cacheKey,
          ApiService.cacheKeyFor('c'),
          ApiService.cacheKeyFor('d'),
        },
      );
      expect(await api.loadCachedResultFor('d'), isNotNull);
    });
  });

  group('nearestLocation via _getJson', () {
    ApiService api(http.Response Function(http.Request) handler) => ApiService(
      baseUrl: 'http://test',
      client: MockClient((req) async => handler(req)),
    );

    test('200 returns the place and sends rounded coordinates', () async {
      Uri? seen;
      final place = await api((req) {
        seen = req.url;
        return _json({
          'id': 'p1',
          'name': 'Phường Một',
          'kind': 'phuong',
          'lat': 10.7,
          'lon': 106.6,
        });
      }).nearestLocation(10.123456, 106.654321);
      expect(place.id, 'p1');
      expect(seen?.path, '/locations/nearest');
      expect(seen?.queryParameters, {'lat': '10.12346', 'lon': '106.65432'});
    });

    test('404 with a detail is outside the area', () async {
      await expectLater(
        api((_) => _json({'detail': 'Ngoài TP.HCM'}, 404))
            .nearestLocation(11, 107),
        throwsA(
          isA<OutsideAreaException>().having(
            (e) => e.message,
            'message',
            'Ngoài TP.HCM',
          ),
        ),
      );
    });

    test('plain 404 / 500 stay ApiException', () async {
      await expectLater(
        api((_) => _json({'detail': 'Not Found'}, 404)).nearestLocation(1, 1),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.notFound,
          ),
        ),
      );
      await expectLater(
        api((_) => http.Response('boom', 500)).nearestLocation(1, 1),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.server)
              .having((e) => e.isTransient, 'transient', isTrue),
        ),
      );
    });
  });
}
