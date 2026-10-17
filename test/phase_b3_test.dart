// Phase B3: nguon so lieu, gio theo gio, AI target_time / kiem chung, che do
// xem lai. Dong ho co dinh + backend gia (MockClient), khong goi mang.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/ai_verify_screen.dart';
import 'package:sky_weather_app/screens/forecast/forecast_format.dart';
import 'package:sky_weather_app/screens/forecast/forecast_source.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/widgets/replay_banner.dart';

// 21:30 15/10/2026 tai TP.HCM (= 14:30 UTC)
final _fakeNow = DateTime.utc(2026, 10, 15, 14, 30);
DateTime _clock() => _fakeNow;
final _replayAt = DateTime.utc(2026, 10, 7, 12); // gio TP.HCM

String _iso(DateTime hcm) => HcmTime.toIso(hcm);

/// Backend gia theo hop dong B2: ton trong `at`, gio dau "observed", con lai
/// "forecast"; ngay "forecast". Du lieu CHI dung trong test.
class _FakeBackend {
  _FakeBackend({this.rejectAt = false, this.ignoreAt = false});

  final bool rejectAt; // backend tra 400 cho `at`
  final bool ignoreAt; // backend cu: bo qua `at`
  final requests = <Uri>[];

  http.Client get client => MockClient((req) async {
    requests.add(req.url);
    final atRaw = req.url.queryParameters['at'];
    if (atRaw != null && rejectAt) {
      return http.Response('{"detail":"bad at"}', 400);
    }
    final at = (atRaw != null && !ignoreAt)
        ? HcmTime.tryParse(atRaw)!
        : HcmTime.startOfHour(HcmTime.now(_clock));
    final base = HcmTime.startOfHour(at);
    final Object? body = switch (req.url.path) {
      '/weather/current' => {
        'timestamp': _iso(base),
        'temperature': 30.0,
        'weather_code': 61,
        'source': 'observed',
      },
      '/weather/hourly' => [
        for (var i = 0; i < 24; i++)
          {
            'timestamp': _iso(base.add(Duration(hours: i))),
            'temperature': 28.0,
            'weather_code': 61,
            'rain_probability': i == 0 ? 1.0 : 0.4,
            'precipitation': i == 0 ? 3.2 : 0.0,
            'wind_speed': 6.0 + i,
            'wind_gusts': 15.0 + i,
            'wind_direction': 200.0,
            'source': i == 0 ? 'observed' : 'forecast',
          },
      ],
      '/weather/daily' => [
        for (var i = 0; i < 7; i++)
          {
            'date': _iso(HcmTime.startOfDay(base).add(Duration(days: i))),
            'temperature_min': 24.0,
            'temperature_max': 31.0,
            'weather_code': 61,
            'wind_speed_max': 14.0,
            'wind_gusts_max': 30.0,
            'rain_day_probability': 0.7,
            'source': 'forecast',
          },
      ],
      '/weather/ai-forecast' => {
        'issued_at': _iso(base),
        'model_version': 'lgbm-test',
        'predictions': {
          '1h': {
            'temperature': 27.0,
            'rain_probability': 0.4,
            'target_time': _iso(base.add(const Duration(hours: 1))),
          },
          '3h': {'temperature': 26.0, 'rain_probability': 0.5},
          '6h': {'temperature': 25.0, 'rain_probability': 0.1},
        },
      },
      _ => null,
    };
    return body == null
        ? http.Response('{"detail":"Not Found"}', 404)
        : http.Response(jsonEncode(body), 200);
  });
}

WeatherProvider _provider(_FakeBackend backend, {bool replay = false}) =>
    WeatherProvider(
      apiService: ApiService(
        client: backend.client,
        baseUrl: 'http://test',
        clock: _clock,
      ),
      clock: _clock,
      initialSettings: AppSettings(
        replayEnabled: replay,
        replayAt: replay ? _replayAt : null,
      ),
    );

const _verifyFull = {
  'issued_at': '2026-10-07T12:00:00+07:00',
  'model_version': 'lgbm-test',
  'horizons': [
    {
      'horizon': '1h',
      'target_time': '2026-10-07T13:00:00+07:00',
      'predicted_temperature': 32.1,
      'predicted_rain_probability': 0.0756,
      'actual_temperature': 32.3,
      'actual_precipitation': 0.1,
      'actual_rain': true,
      'abs_error_temperature': 0.2,
    },
    {
      'horizon': '3h',
      'target_time': '2026-10-07T15:00:00+07:00',
      'predicted_temperature': 30.7,
      'predicted_rain_probability': 0.6,
      'actual_temperature': 31.8,
      'actual_precipitation': 0.0,
      'actual_rain': false,
      'abs_error_temperature': 1.1,
    },
  ],
};

const _verifyPartial = {
  'issued_at': '2026-10-15T21:00:00+07:00',
  'model_version': 'lgbm-test',
  'horizons': [
    {
      'horizon': '1h',
      'target_time': '2026-10-15T22:00:00+07:00',
      'predicted_temperature': 26.0,
      'predicted_rain_probability': 0.3,
      'actual_temperature': null,
      'actual_precipitation': null,
      'actual_rain': null,
      'abs_error_temperature': null,
    },
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Source parsing + labels', () {
    test('parseDataSource', () {
      expect(parseDataSource('observed'), DataSource.observed);
      expect(parseDataSource('forecast'), DataSource.forecast);
      expect(parseDataSource('climatology'), DataSource.climatology);
      expect(parseDataSource('other'), isNull);
      expect(parseDataSource(null), isNull);
    });

    test('pure sources use the full label', () {
      final f = SourceSummary.of([DataSource.forecast, DataSource.forecast]);
      expect(f.isMixed, isFalse);
      expect(f.label, 'Dự báo mô hình (Open-Meteo)');
      expect(f.marks(DataSource.forecast), isFalse);
      expect(
        SourceSummary.of([DataSource.observed]).label,
        'Thực tế (dữ liệu mô hình phân tích)',
      );
      // Backend cu (khong co source) -> trung binh nhieu nam
      final old = SourceSummary.of([null, null]);
      expect(old.label, 'Trung bình nhiều năm');
      expect(ForecastSource.fromItems([null]).label, 'Trung bình nhiều năm');
    });

    test('mixed sources: list label, mark non-forecast items', () {
      final m = SourceSummary.of([
        DataSource.forecast,
        DataSource.observed,
        DataSource.climatology,
      ]);
      expect(m.isMixed, isTrue);
      expect(m.label, 'Nhiều nguồn: Thực tế + Dự báo + Thống kê');
      expect(m.marks(DataSource.observed), isTrue);
      expect(m.marks(DataSource.climatology), isTrue);
      expect(m.marks(DataSource.forecast), isFalse);
      expect(
        ForecastSource.fromItems([DataSource.forecast, DataSource.observed])
            .isMixed,
        isTrue,
      );
    });

    test('items parse source, current too', () {
      final h = HourlyForecast.fromJson({
        'timestamp': '2026-10-07T12:00:00+07:00',
        'temperature': 32,
        'source': 'observed',
      });
      expect(h.source, DataSource.observed);
      expect(h.isObserved, isTrue);
      final c = CurrentWeather.fromJson({
        'timestamp': '2026-10-07T12:00:00+07:00',
        'temperature': 32,
        'source': 'observed',
        'uv_index': 7.5,
        'us_aqi': 61,
      }, locationName: 'HCM');
      expect(c.source, DataSource.observed);
      expect(c.uvIndex, 7.5);
      expect(c.usAqi, 61);
    });
  });

  group('Wind + AI parsing', () {
    test('hourly wind and daily gusts', () {
      final h = HourlyForecast.fromJson({
        'timestamp': '2026-10-15T21:00:00+07:00',
        'temperature': 25.7,
        'wind_speed': 6.2,
        'wind_gusts': 10.9,
        'wind_direction': 196.0,
        'precipitation': 0.18,
      });
      expect(h.windSpeed, 6.2);
      expect(h.windGusts, 10.9);
      expect(h.windDirection, 196.0);
      expect(h.precipitationMm, 0.18);
      final old = HourlyForecast.fromJson({
        'timestamp': '2026-10-15T21:00:00',
        'temperature': 25.7,
      });
      expect(old.windSpeed, isNull);
      expect(old.source, isNull);

      final d = DailyForecast.fromJson({
        'date': '2026-10-07',
        'temperature_min': 24.3,
        'temperature_max': 32.1,
        'wind_speed_max': 10.4,
        'wind_gusts_max': 22.9,
        'rain_day_probability': 1.0,
        'source': 'observed',
      });
      expect(d.windGusts, 22.9);
      expect(d.observedRainText, 'Có mưa');
    });

    test('AI target_time, with fallback issued_at + horizon', () {
      final ai = AIForecast.fromJson({
        'issued_at': '2026-10-15T21:00:00+07:00',
        'predictions': {
          '1h': {
            'temperature': 25,
            'rain_probability': 0.1,
            'target_time': '2026-10-15T22:00:00+07:00',
          },
          '3h': {'temperature': 25, 'rain_probability': 0.1},
        },
      });
      expect(ai.predictions[0].targetTime, DateTime.utc(2026, 10, 15, 22));
      expect(ai.predictions[1].targetTime, DateTime.utc(2026, 10, 16, 0));
      final now = DateTime.utc(2026, 10, 15, 21);
      expect(
        ForecastFormat.targetTime(DateTime.utc(2026, 10, 15, 23), now),
        '23:00',
      );
      expect(
        ForecastFormat.targetTime(DateTime.utc(2026, 10, 16), now),
        '00:00 · T6',
      );
    });

    test('AI verification: full and partially null', () {
      final full = AIVerification.fromJson(
        jsonDecode(jsonEncode(_verifyFull)) as Map<String, dynamic>,
      );
      expect(full.horizons, hasLength(2));
      expect(full.horizons.first.actualRain, isTrue);
      expect(full.horizons.first.temperatureError, 0.2);
      expect(full.horizons.first.predictedRainPercent, 8);
      final partial = AIVerification.fromJson(
        jsonDecode(jsonEncode(_verifyPartial)) as Map<String, dynamic>,
      );
      final h = partial.horizons.single;
      expect(h.hasActual, isFalse);
      expect(h.temperatureError, isNull);
      expect(h.actualRain, isNull);
    });
  });

  group('Replay mode', () {
    test('passes at on every call, moves nowHcm, no cache write', () async {
      final backend = _FakeBackend();
      final p = _provider(backend, replay: true);
      await p.fetchWeatherData();
      expect(p.isReplay, isTrue);
      expect(p.nowHcm, _replayAt);
      expect(p.realNowHcm, DateTime.utc(2026, 10, 15, 21, 30));
      expect(p.isStale, isFalse);
      expect(backend.requests, hasLength(4));
      for (final u in backend.requests) {
        expect(u.queryParameters['at'], '2026-10-07T12:00:00+07:00');
      }
      expect(p.currentWeather!.lastUpdated, _replayAt);
      expect(
        p.aiForecast!.predictions.first.targetTime,
        DateTime.utc(2026, 10, 7, 13),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ApiService.cacheKey), isNull);

      // Thoat -> du lieu truc tiep ngay, khong con `at`, co ghi cache
      backend.requests.clear();
      await p.exitReplay();
      expect(p.isReplay, isFalse);
      expect(p.nowHcm, DateTime.utc(2026, 10, 15, 21, 30));
      expect(backend.requests, hasLength(4));
      expect(
        backend.requests.every((u) => !u.queryParameters.containsKey('at')),
        isTrue,
      );
      expect(prefs.getString(ApiService.cacheKey), isNotNull);
      expect(prefs.getBool(AppSettings.replayEnabledKey), isFalse);
    });

    test('startReplay persists, rounds to hour and clamps', () async {
      final p = _provider(_FakeBackend());
      await p.startReplay(DateTime.utc(2026, 10, 7, 12, 45));
      expect(p.replayAt, _replayAt);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppSettings.replayEnabledKey), isTrue);
      expect(
        prefs.getString(AppSettings.replayAtKey),
        '2026-10-07T12:00:00+07:00',
      );
      final restored = AppSettings.fromPrefs(prefs);
      expect(restored.replayEnabled, isTrue);
      expect(restored.replayAt, _replayAt);
      expect(p.clampReplay(DateTime.utc(2010)), WeatherProvider.replayMin);
      expect(p.clampReplay(DateTime.utc(2030)), DateTime.utc(2026, 10, 15, 21));
    });

    test('400 for at -> friendly notice, back to live, no crash', () async {
      final p = _provider(_FakeBackend(rejectAt: true), replay: true);
      await p.fetchWeatherData();
      expect(p.isReplay, isFalse);
      expect(p.notice, contains('chưa hỗ trợ xem lại'));
      expect(p.error, isNull);
      expect(p.currentWeather, isNotNull); // du lieu truc tiep
    });

    test('old backend ignoring at -> detected, back to live', () async {
      final p = _provider(_FakeBackend(ignoreAt: true), replay: true);
      await p.fetchWeatherData();
      expect(p.isReplay, isFalse);
      expect(p.notice, isNotNull);
    });
  });

  group('Widgets', () {
    Future<WeatherProvider> pumpApp(
      WidgetTester tester,
      Widget home, {
      bool replay = true,
      http.Client? verifyClient,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final backend = _FakeBackend();
      final p = WeatherProvider(
        apiService: ApiService(
          client: verifyClient ?? backend.client,
          baseUrl: 'http://test',
          clock: _clock,
        ),
        clock: _clock,
        initialSettings: AppSettings(
          replayEnabled: replay,
          replayAt: replay ? _replayAt : null,
        ),
      );
      if (verifyClient == null) await p.fetchWeatherData();
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: p,
          child: MaterialApp(
            // Nen canh dong chay lien tuc -> tat chuyen dong de pumpAndSettle
            // dung duoc (nen tinh, giong nguoi dung bat "Giảm chuyển động").
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: ReplayBannerHost(child: child!),
            ),
            home: home,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return p;
    }

    testWidgets('banner visible in replay, Thoát returns to live', (
      tester,
    ) async {
      final p = await pumpApp(tester, const HomeScreen());
      expect(
        find.text('ĐANG XEM LẠI: 12:00 Thứ 4, 07/10/2026'),
        findsOneWidget,
      );
      // O gio dau tien (thuc te) duoc ghi "Thực tế", la "Bây giờ", hien mm
      // Tieu de the kinh viet hoa; cuon trong CustomScrollView (khong phai
      // PageView dia diem).
      final hourly = find.text('THEO GIỜ');
      await tester.scrollUntilVisible(
        hourly,
        300,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
      await tester.pump();
      expect(find.text('Bây giờ'), findsWidgets);
      expect(find.text('Thực tế'), findsWidgets);
      expect(find.text('3 mm'), findsWidgets);
      // Chu thich nguon mot dong + nut (i) giai thich.
      expect(find.textContaining('(phân tích mô hình)'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Thoát'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(p.isReplay, isFalse);
      expect(find.textContaining('ĐANG XEM LẠI'), findsNothing);
    });

    testWidgets('AI verify: full data shows forecast vs actual', (
      tester,
    ) async {
      final client = MockClient((req) async {
        expect(req.url.path, '/weather/ai-verify');
        expect(req.url.queryParameters['at'], '2026-10-07T12:00:00+07:00');
        return http.Response(jsonEncode(_verifyFull), 200);
      });
      await pumpApp(tester, const AIVerifyScreen(), verifyClient: client);
      await tester.pumpAndSettle();
      expect(find.text('Có mưa (0,1 mm)'), findsOneWidget);
      expect(find.text('Không mưa (0 mm)'), findsOneWidget);
      expect(find.text('Sai số nhiệt độ: 0,2°C'), findsOneWidget);
      // The danh gia o luoi day ghi chu xuong duoi: cuon toi.
      final note = find.textContaining('không phải số đo từ trạm');
      await tester.scrollUntilVisible(
        note,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(note, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AI verify: MAE muc tieu moi + do phu p10-p90', (tester) async {
      final body = jsonDecode(jsonEncode(_verifyFull)) as Map<String, dynamic>;
      body['evaluation'] = {
        'temperature_mae_1h': 0.355,
        'beats_baselines': true,
        'humidity_mae_1h': 2.096,
        'wind_speed_mae_1h': 1.531,
        'precipitation_mm_mae_1h': 0.257,
        'wind_gusts_mae_1h': 3.1,
        'temperature_interval_coverage_1h': 0.7713,
        'temperature_interval_coverage_3h': 0.75,
        'interval_nominal_coverage': 0.8,
        // wind_gusts tat -> an.
        'enabled_targets': [
          'temperature',
          'temperature_interval',
          'humidity',
          'wind_speed',
          'precipitation_mm',
        ],
      };
      final client = MockClient(
        (req) async => http.Response(jsonEncode(body), 200),
      );
      await pumpApp(tester, const AIVerifyScreen(), verifyClient: client);
      await tester.pumpAndSettle();
      expect(find.text('Sai số độ ẩm: ±2,1% (1h)'), findsOneWidget);
      expect(find.text('Sai số gió: ±1,5 km/h (1h)'), findsOneWidget);
      expect(find.text('Sai số lượng mưa: ±0,26 mm (1h)'), findsOneWidget);
      expect(find.textContaining('gió giật'), findsNothing);
      expect(
        find.textContaining(
          'nhiệt độ 80% phủ 77% (1h) · 75% (3h) trên tập kiểm tra',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('mục tiêu 80%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AI verify: muc tieu theo interval_level 90%', (tester) async {
      final body = jsonDecode(jsonEncode(_verifyFull)) as Map<String, dynamic>;
      body['evaluation'] = {
        'temperature_mae_1h': 0.355,
        'beats_baselines': true,
        'humidity_mae_1h': 2.096,
        'wind_speed_mae_1h': 1.531,
        'precipitation_mm_mae_1h': 0.257,
        'wind_gusts_mae_1h': 3.1,
        'temperature_interval_coverage_1h': 0.7713,
        'temperature_interval_coverage_3h': 0.75,
        'interval_level': 0.9,
        // wind_gusts tat -> an.
        'enabled_targets': [
          'temperature',
          'temperature_interval',
          'humidity',
          'wind_speed',
          'precipitation_mm',
        ],
      };
      final client = MockClient(
        (req) async => http.Response(jsonEncode(body), 200),
      );
      await pumpApp(tester, const AIVerifyScreen(), verifyClient: client);
      await tester.pumpAndSettle();
      expect(find.text('Sai số độ ẩm: ±2,1% (1h)'), findsOneWidget);
      expect(find.text('Sai số gió: ±1,5 km/h (1h)'), findsOneWidget);
      expect(find.text('Sai số lượng mưa: ±0,26 mm (1h)'), findsOneWidget);
      expect(find.textContaining('gió giật'), findsNothing);
      expect(
        find.textContaining(
          'nhiệt độ 90% phủ 77% (1h) · 75% (3h) trên tập kiểm tra',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('mục tiêu 90%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AI verify: target not yet available', (tester) async {
      final client = MockClient(
        (req) async => http.Response(jsonEncode(_verifyPartial), 200),
      );
      await pumpApp(
        tester,
        const AIVerifyScreen(),
        replay: false,
        verifyClient: client,
      );
      await tester.pumpAndSettle();
      expect(find.text('Chưa tới giờ'), findsOneWidget);
      expect(find.textContaining('chưa tới — chưa có số liệu'), findsOneWidget);
      expect(find.textContaining('Chế độ xem lại'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AI verify: 404 -> friendly message', (tester) async {
      final client = MockClient(
        (req) async => http.Response('{"detail":"Not Found"}', 404),
      );
      await pumpApp(
        tester,
        const AIVerifyScreen(),
        replay: false,
        verifyClient: client,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('chưa hỗ trợ kiểm chứng'), findsOneWidget);
      expect(find.text('Thử lại'), findsOneWidget);
    });
  });
}
