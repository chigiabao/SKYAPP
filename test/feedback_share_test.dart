import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';

import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/feedback_screen.dart';
import 'package:sky_weather_app/services/feedback_service.dart';
import 'package:sky_weather_app/services/share_service.dart';
import 'package:sky_weather_app/utils/theme.dart';

// 15:00 17/10/2026 gio TP.HCM. Du lieu gia CHI dung trong test.
final _now = DateTime.utc(2026, 10, 17, 15);

List<HourlyForecast> _hours() => [
  for (var i = 0; i < 6; i++)
    HourlyForecast(
      time: _now.add(Duration(hours: i)),
      temperature: 31.0 - i,
      condition: WeatherCondition.showers,
      rainProbability: [0.3, 0.7, 0.5, 0.9, 0.1, 0.0][i],
      source: DataSource.forecast,
    ),
];

http.Response _created() => http.Response(
  jsonEncode({
    'id': 7,
    'created_at': '2026-10-17T15:00:00+07:00',
    'kind': 'wrong_forecast',
    'cell_id': 'c1',
    'verified': false,
  }),
  201,
);

const _gpsKeys = ['lat', 'lon', 'latitude', 'longitude', 'gps', 'coords'];

void _expectNoGps(Object? j) {
  if (j is Map) {
    for (final e in j.entries) {
      expect(_gpsKeys.contains(e.key), isFalse, reason: 'key ${e.key}');
      _expectNoGps(e.value);
    }
  } else if (j is List) {
    j.forEach(_expectNoGps);
  }
}

FeedbackDraft _draft() => FeedbackDraft(
  kind: FeedbackKind.wrongForecast,
  message: 'Đang mưa to',
  locationId: 'phuong-ben-thanh',
  raining: true,
  feel: TemperatureFeel.cool,
  snapshot: forecastSnapshot(
    locationId: 'phuong-ben-thanh',
    nowHcm: _now,
    hours: _hours(),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('FeedbackService', () {
    test('201 -> receipt, payload dung schema, khong GPS', () async {
      late Map<String, dynamic> sent;
      final s = FeedbackService(
        baseUrl: 'http://x',
        platform: 'test',
        client: MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.toString(), 'http://x/feedback');
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return _created();
        }),
      );
      await s.saveDraft(_draft());
      final r = await s.submit(_draft());
      expect(r.id, 7);
      expect(r.verified, isFalse);
      expect(sent['kind'], 'wrong_forecast');
      expect(sent['observed'], {'raining': true, 'temperature_feel': 'cool'});
      expect(sent['app_version'], kAppVersion);
      expect(sent['platform'], 'test');
      final snap = sent['forecast_snapshot'] as Map;
      expect(snap.keys.toSet(), {
        'location_id',
        'time',
        'temperature',
        'rain_probability',
        'source',
      });
      expect(snap['rain_probability'], 0.3);
      expect(snap['source'], 'forecast');
      _expectNoGps(sent);
      expect(await s.loadDraft(), isNull, reason: 'gui xong xoa nhap');
    });

    test('429 -> rateLimited, khong luu nhap', () async {
      final s = FeedbackService(
        baseUrl: 'http://x',
        client: MockClient((_) async => http.Response('{"detail":"x"}', 429)),
      );
      await expectLater(
        s.submit(_draft()),
        throwsA(
          isA<FeedbackException>()
              .having((e) => e.kind, 'kind', FeedbackErrorKind.rateLimited)
              .having((e) => e.message, 'msg', contains('thử lại sau')),
        ),
      );
      expect(await s.loadDraft(), isNull);
    });

    test('loi mang -> luu nhap de thu lai', () async {
      final s = FeedbackService(
        baseUrl: 'http://x',
        client: MockClient((_) async => throw const SocketException('off')),
      );
      await expectLater(
        s.submit(_draft()),
        throwsA(
          isA<FeedbackException>()
              .having((e) => e.kind, 'kind', FeedbackErrorKind.network)
              .having((e) => e.draftSaved, 'saved', isTrue),
        ),
      );
      final d = await s.loadDraft();
      expect(d?.kind, FeedbackKind.wrongForecast);
      expect(d?.message, 'Đang mưa to');
      expect(d?.raining, isTrue);
      expect(d?.feel, TemperatureFeel.cool);
    });

    test('loai khac khong gui observed; message cat 1000', () {
      final p = FeedbackDraft(
        kind: FeedbackKind.bug,
        message: 'a' * 1200,
        raining: true,
      ).toPayload(platform: 'test');
      expect(p.containsKey('observed'), isFalse);
      expect((p['message'] as String).length, 1000);
      _expectNoGps(p);
    });
  });

  group('Van ban chia se', () {
    test('tom tat thoi tiet theo mau', () {
      expect(
        weatherShareText(
          placeName: 'Phường Bến Thành',
          at: _now,
          tempText: '31°',
          condition: 'Mưa rào',
          rainPercent3h: 70,
        ),
        'Phường Bến Thành, 15:00 17/10: 31°, mưa rào, khả năng mưa 3 giờ '
        'tới 70%. – Sky Weather (dữ liệu mô hình Open-Meteo)',
      );
    });

    test('tu du lieu theo gio: max mua 3 gio toi', () {
      expect(rainNext3h(_hours(), _now), 70);
      expect(
        forecastShareText(
          placeName: 'Phường Bến Thành',
          nowHcm: _now.add(const Duration(minutes: 20)),
          hours: _hours(),
          formatTempValue: (c) => c.round().toString(),
        ),
        startsWith(
          'Phường Bến Thành, 15:00 17/10: 31°, mưa rào, khả năng '
          'mưa 3 giờ tới 70%.',
        ),
      );
      expect(
        forecastShareText(
          placeName: 'X',
          nowHcm: _now,
          hours: const [],
          formatTempValue: (c) => '$c',
        ),
        isNull,
      );
    });

    test('goi y khung gio hoat dong', () {
      final t = activityShareText(
        placeName: 'Phường Bến Thành',
        activities: const [Activity.running],
        hours: _hours(),
        nowHcm: _now,
      );
      expect(t, startsWith('Gợi ý khung giờ hoạt động · Phường Bến Thành:'));
      expect(t, contains('• Chạy bộ: '));
      expect(t, endsWith(kShareSignature));
    });
  });

  group('FeedbackScreen', () {
    Future<List<Map<String, dynamic>>> pump(
      WidgetTester tester, {
      FeedbackKind? kind,
      int status = 201,
    }) async {
      final sent = <Map<String, dynamic>>[];
      final service = FeedbackService(
        baseUrl: 'http://x',
        platform: 'test',
        client: MockClient((req) async {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return status == 201 ? _created() : http.Response('{}', status);
        }),
      );
      final provider = WeatherProvider(
        initialSettings: const AppSettings(),
        clock: () => _now,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(400, 900),
                disableAnimations: true,
              ),
              child: FeedbackScreen(
                initialKind: kind,
                locationId: 'phuong-ben-thanh',
                snapshot: forecastSnapshot(
                  locationId: 'phuong-ben-thanh',
                  nowHcm: _now,
                  hours: _hours(),
                ),
                service: service,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return sent;
    }

    testWidgets('du bao sai: chip, bo dem, canh bao, gui', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final sent = await pump(tester, kind: FeedbackKind.wrongForecast);

      expect(find.text('Ở chỗ bạn đang mưa không?'), findsOneWidget);
      expect(find.text('Cảm giác nhiệt'), findsOneWidget);
      expect(find.text(kFeedbackDisclaimer), findsOneWidget);
      expect(find.text('0/1000'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Mưa to');
      await tester.pump();
      expect(find.text('6/1000'), findsOneWidget);

      await tester.tap(find.text('Có'));
      await tester.tap(find.text('Mát'));
      await tester.pump();
      await tester.tap(find.text('Gửi'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(sent, hasLength(1));
      expect(sent.single['kind'], 'wrong_forecast');
      expect(sent.single['observed'], {
        'raining': true,
        'temperature_feel': 'cool',
      });
      _expectNoGps(sent.single);
    });

    testWidgets('bao loi: an chip; 429 bao thu lai sau', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pump(tester, status: 429);

      expect(find.text('Ở chỗ bạn đang mưa không?'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Nút bị lỗi');
      await tester.pump();
      await tester.tap(find.text('Gửi'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('thử lại sau'), findsWidgets);
    });
  });
}
