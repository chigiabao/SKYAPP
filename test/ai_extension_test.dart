import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/ai_forecast_card.dart';

/// JSON day du theo dang that cua backend (rut gon con 2 moc).
Map<String, dynamic> _fullJson({List<String>? enabled}) => {
  'issued_at': '2026-10-17T17:00:00+07:00',
  'model_version': 'lgbm-hcmc-global-v3-20261017',
  'enabled_targets':
      enabled ??
      [
        'temperature',
        'rain_probability',
        'temperature_interval',
        'humidity',
        'wind_speed',
        'wind_gusts',
        'precipitation_mm',
      ],
  'predictions': {
    '1h': {
      'temperature': 26.1,
      'rain_probability': 0.5388,
      'temperature_p10': 25.81,
      'temperature_p90': 26.58,
      'humidity': 93.0,
      'wind_speed': 4.0,
      'wind_gusts': 8.6,
      'precipitation_mm': 0.69,
      'uncertainty_note':
          'Nhiệt độ nhiều khả năng trong khoảng 25,8–26,6 °C (khoảng '
          'p10–p90). Kiểm chứng: thực tế rơi vào khoảng ~77% số lần. Đây là '
          'mức bất định, không phải điểm độ chính xác.',
      'target_time': '2026-10-17T18:00:00+07:00',
    },
    '3h': {
      'temperature': 26.45,
      'rain_probability': 0.2598,
      'temperature_p10': 25.18,
      'temperature_p90': 27.14,
      'humidity': 92.4,
      'wind_speed': 5.3,
      'wind_gusts': 10.1,
      'precipitation_mm': 0.4,
      'target_time': '2026-10-17T20:00:00+07:00',
    },
  },
  'evaluation': {
    'cell_id': 'om-10.7909-106.7109',
    'temperature_mae_1h': 0.355,
    'rain_f1_1h': 0.667,
    'beats_baselines': true,
    'test_period': '2025-01-01..2026-10-16',
    'temperature_interval_coverage_1h': 0.7713,
    'temperature_interval_coverage_3h': 0.75,
    'interval_nominal_coverage': 0.8,
    'humidity_mae_1h': 2.096,
    'wind_speed_mae_1h': 1.531,
    'wind_gusts_mae_3h': 3.148,
    'precipitation_mm_mae_1h': 0.257,
    'enabled_targets': ['temperature', 'humidity'],
  },
};

void main() {
  group('AIForecast parse truong mo rong', () {
    test('day du truong', () {
      final f = AIForecast.fromJson(_fullJson());
      final p = f.predictions.first;
      expect(p.temperatureP10, 25.81);
      expect(p.temperatureP90, 26.58);
      expect(p.hasInterval, isTrue);
      expect(p.humidity, 93.0);
      expect(p.windSpeed, 4.0);
      expect(p.windGusts, 8.6);
      expect(p.precipitationMm, 0.69);
      expect(p.uncertaintyNote, contains('~77%'));
      expect(f.predictions[1].uncertaintyNote, isNull);
      expect(f.enabledTargets, contains('temperature_interval'));
      expect(f.isEnabled('humidity'), isTrue);

      final e = f.evaluation!;
      expect(e.intervalCoverage['1h'], 0.7713);
      expect(e.intervalNominalCoverage, 0.8);
      expect(e.targetMae['humidity']!['1h'], 2.096);
      expect(e.targetMae['wind_gusts']!['3h'], 3.148);
      expect(e.targetMae['precipitation_mm']!['1h'], 0.257);
      expect(e.isEnabled('wind_speed'), isFalse);
      expect(intervalCoveragePercent(p, e), 77);
      expect(intervalCoveragePercent(f.predictions[1], e), 75);
    });

    test('thieu truong moi (backend cu) van chay', () {
      final f = AIForecast.fromJson({
        'issued_at': '2026-10-17T17:00:00+07:00',
        'model_version': 'lgbm-v2',
        'predictions': {
          '1h': {'temperature': 26.0, 'rain_probability': 0.3},
          '3h': {'temperature': 25.0},
        },
        'evaluation': {'temperature_mae_1h': 0.4},
      });
      expect(f.predictions, hasLength(2));
      final p = f.predictions.first;
      expect(p.temperatureP10, isNull);
      expect(p.hasInterval, isFalse);
      expect(p.humidity, isNull);
      expect(p.windSpeed, isNull);
      expect(p.windGusts, isNull);
      expect(p.precipitationMm, isNull);
      expect(p.uncertaintyNote, isNull);
      expect(f.enabledTargets, isNull);
      // Khong co danh sach -> coi nhu bat het.
      expect(f.isEnabled('humidity'), isTrue);
      final e = f.evaluation!;
      expect(e.targetMae, isEmpty);
      expect(e.intervalCoverage, isEmpty);
      expect(e.intervalNominalCoverage, isNull);
      expect(e.enabledTargets, isNull);
    });

    test('kieu sai bi bo qua, p10 > p90 khong tinh la khoang', () {
      final f = AIForecast.fromJson({
        'issued_at': '2026-10-17T17:00:00+07:00',
        'enabled_targets': 'temperature',
        'predictions': {
          '1h': {
            'temperature': 26.0,
            'temperature_p10': 27.0,
            'temperature_p90': 25.0,
            'humidity': '93',
            'uncertainty_note': '  ',
          },
        },
      });
      final p = f.predictions.single;
      expect(p.hasInterval, isFalse);
      expect(p.humidity, isNull);
      expect(p.uncertaintyNote, isNull);
      expect(f.enabledTargets, isNull);
    });
  });

  group('AIForecastCard', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pump(
      WidgetTester tester,
      AIForecast f, {
      double scale = 1.0,
    }) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final provider = WeatherProvider(
        apiService: ApiService(),
        initialSettings: const AppSettings(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 1400),
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: Scaffold(
                backgroundColor: Colors.black,
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: AIForecastCard(forecast: f),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('hien khoang p10-p90, giai thich va hang phu', (tester) async {
      // So + don vi noi bang khoang trang khong ngat dong.
      final nbsp = String.fromCharCode(0x00A0);
      await pump(tester, AIForecast.fromJson(_fullJson()));
      expect(find.text('26°'), findsNWidgets(2));
      expect(find.text('(26–27°)'), findsOneWidget);
      expect(find.textContaining('khoảng p10–p90'), findsOneWidget);
      expect(find.textContaining('~77%'), findsOneWidget);
      expect(
        find.textContaining('không phải điểm độ chính xác'),
        findsOneWidget,
      );
      expect(find.text('Ẩm 93%'), findsOneWidget);
      expect(find.text('Gió 4${nbsp}km/h'), findsOneWidget);
      expect(find.text('Giật 9${nbsp}km/h'), findsOneWidget);
      expect(find.text('Mưa 0,7${nbsp}mm'), findsOneWidget);
      expect(find.text('54%'), findsOneWidget);
      expect(find.byType(Tooltip), findsOneWidget);
      // Nut (i) dat chuan cham 48dp.
      final info = find.byIcon(Icons.info_outline_rounded);
      final box = tester.getSize(
        find.ancestor(of: info, matching: find.byType(SizedBox)).first,
      );
      expect(box.width, greaterThanOrEqualTo(48));
      expect(box.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an muc tieu khong nam trong enabled_targets', (tester) async {
      await pump(
        tester,
        AIForecast.fromJson(_fullJson(enabled: ['temperature', 'humidity'])),
      );
      expect(find.text('26°'), findsNWidgets(2));
      expect(find.text('Ẩm 93%'), findsOneWidget);
      expect(find.text('(26–27°)'), findsNothing);
      expect(find.textContaining('p10–p90'), findsNothing);
      expect(find.textContaining('Gió'), findsNothing);
      expect(find.textContaining('Giật'), findsNothing);
      expect(find.textContaining('Mưa 0'), findsNothing);
      expect(find.text('54%'), findsNothing);
      expect(find.textContaining('% = khả năng mưa'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('du lieu cu khong co truong moi van hien', (tester) async {
      await pump(
        tester,
        AIForecast.fromJson({
          'issued_at': '2026-10-17T17:00:00+07:00',
          'predictions': {
            '1h': {'temperature': 26.0, 'rain_probability': 0.3},
          },
        }),
      );
      expect(find.text('26°'), findsOneWidget);
      expect(find.text('30%'), findsOneWidget);
      expect(find.textContaining('p10–p90'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('textScale 2.0 khong tran', (tester) async {
      final f = AIForecast.fromJson(_fullJson());
      final withSix = AIForecast(
        issuedAt: f.issuedAt,
        modelVersion: f.modelVersion,
        enabledTargets: f.enabledTargets,
        evaluation: f.evaluation,
        predictions: [
          ...f.predictions,
          AIPrediction(
            timeLabel: '6h',
            temperature: 25.62,
            rainProbability: 0.2157,
            temperatureP10: 24.92,
            temperatureP90: 26.34,
            humidity: 96.6,
            windSpeed: 4.6,
            windGusts: 28.1,
            precipitationMm: 12.18,
          ),
        ],
      );
      await pump(tester, withSix, scale: 2.0);
      expect(find.text('(26–27°)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
