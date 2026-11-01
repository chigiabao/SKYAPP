import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/ai_verify_screen.dart';
import 'package:sky_weather_app/widgets/ai_forecast_card.dart';

Map<String, dynamic> _payload(String mode) => {
  'issued_at': '2026-10-18T12:00:00+07:00',
  'model_version': mode == 'unavailable' ? '' : 'stored-v1',
  'verification_mode': mode,
  'forecast_source': mode == 'archived'
      ? 'ai_forecast_log'
      : mode == 'retrospective'
      ? 'current_model_replay'
      : null,
  'actual_source': 'open_meteo_analysis',
  if (mode == 'archived') 'archived_at': '2026-10-18T12:05:00+07:00',
  if (mode == 'retrospective') 'selection_cutoff': '2026-10-16T23:00:00+07:00',
  if (mode == 'unavailable') 'unavailable_reason': 'no_archived_forecast',
  'horizons': [
    if (mode != 'unavailable')
      {
        'horizon': '1h',
        'target_time': '2026-10-18T13:00:00+07:00',
        'predicted_temperature': 30.0,
        'predicted_rain_probability': 0.2,
        'actual_temperature': 31.0,
        'actual_rain': false,
      },
  ],
};

class _VerificationProvider extends WeatherProvider {
  _VerificationProvider(this.result)
    : super(initialSettings: const AppSettings());

  final AIVerification result;

  @override
  Future<AIVerification> fetchAIVerification() async => result;
}

Future<void> _pump(
  WidgetTester tester,
  AIVerification data, {
  Future<AIForecast?> Function(DateTime)? intervalLoader,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = _VerificationProvider(data);
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AIVerifyScreen(intervalLoader: intervalLoader),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'verification parses provenance and compatible missing-archive response',
    () {
      final archived = AIVerification.fromJson(_payload('archived'));
      expect(archived.modeLabel, 'Dự báo đã lưu');
      expect(archived.forecastSource, 'ai_forecast_log');
      expect(archived.actualSource, 'open_meteo_analysis');
      expect(archived.archivedAt, isNotNull);
      final replay = AIVerification.fromJson(_payload('retrospective'));
      expect(replay.modeLabel, 'Mô phỏng hồi cứu');
      expect(replay.selectionCutoff, isNotNull);
      final missing = AIVerification.fromJson(_payload('unavailable'));
      expect(missing.horizons, isEmpty);
      expect(missing.unavailableReason, 'no_archived_forecast');
      final legacy = Map<String, dynamic>.of(_payload('archived'))
        ..remove('verification_mode');
      expect(
        AIVerification.fromJson(legacy).modeLabel,
        'Nguồn dự báo chưa xác định',
      );
    },
  );

  test('forecast replay mode is retained', () {
    final forecast = AIForecast.fromJson({
      'issued_at': '2024-06-10T12:00:00+07:00',
      'model_version': 'current-model',
      'forecast_mode': 'retrospective',
      'predictions': <String, dynamic>{},
    });
    expect(forecast.forecastMode, 'retrospective');
  });

  test('compact replay forecast is labelled as retrospective', () {
    final provider = _VerificationProvider(
      AIVerification.fromJson(_payload('unavailable')),
    );
    addTearDown(provider.dispose);
    final forecast = AIForecast.fromJson({
      'issued_at': '2024-06-10T12:00:00+07:00',
      'model_version': 'current-model',
      'forecast_mode': 'retrospective',
      'predictions': {
        '1h': {'temperature': 30.0, 'rain_probability': 0.2},
      },
    });
    final text = AIForecastCard.compactText(
      forecast,
      provider,
      units: const UnitPrefs(),
    );
    expect(text, startsWith('AI hồi cứu:'));
    expect(text, isNot(contains('tới')));
  });

  for (final mode in ['archived', 'retrospective', 'unavailable']) {
    testWidgets('$mode never reloads an original band from the current model', (
      tester,
    ) async {
      var intervalCalls = 0;
      final data = AIVerification.fromJson(_payload(mode));
      await _pump(
        tester,
        data,
        intervalLoader: (_) async {
          intervalCalls++;
          return null;
        },
      );
      expect(intervalCalls, 0);
      if (mode != 'unavailable') {
        expect(find.textContaining(data.modeLabel), findsWidgets);
      }
      expect(find.textContaining('Bản dự báo phát hành'), findsNothing);
      // Cung nhan voi DataSource.observed.shortLabel; khong con "Thực tế".
      expect(find.textContaining('Thực tế'), findsNothing);
      if (mode != 'unavailable') {
        expect(find.text('Đã ghi nhận'), findsWidgets);
      }
      if (mode == 'retrospective') {
        expect(
          find.textContaining('không phải dự báo đã phát hành lúc đó'),
          findsOneWidget,
        );
      }
      if (mode == 'unavailable') {
        expect(
          find.text('Chưa có bản dự báo đã lưu để kiểm chứng.'),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('MAE is a mean error, never a plus-minus interval', (
    tester,
  ) async {
    final payload = _payload('retrospective')
      ..['evaluation'] = {
        'temperature_mae_1h': 0.4,
        'humidity_mae_1h': 2.1,
        'wind_speed_mae_1h': 1.5,
        'precipitation_mm_mae_1h': 0.26,
        'beats_baselines': true,
      };
    await _pump(tester, AIVerification.fromJson(payload));
    final detail = find.text('Chi tiết kỹ thuật');
    // Danh sach dung luoi (lazy): cuon toi khi muc duoc dung.
    await tester.scrollUntilVisible(
      detail,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(detail);
    await tester.pumpAndSettle();
    expect(find.textContaining('±'), findsNothing);
    expect(
      find.textContaining('MAE nhiệt độ tại ô lưới này: 0,4°C'),
      findsWidgets,
    );
    expect(find.text('MAE độ ẩm: 2,1 điểm % (1h)'), findsOneWidget);
    expect(find.text('MAE gió: 1,5 km/h (1h)'), findsOneWidget);
    expect(find.text('MAE lượng mưa: 0,26 mm (1h)'), findsOneWidget);
    expect(find.textContaining('không phải khoảng dự báo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('MAE delta converts to Fahrenheit without an interval sign', () {
    const units = UnitPrefs(temp: TempUnit.fahrenheit);
    final line = AIEvaluationLine.text(
      const AIEvaluation(temperatureMae: {'1h': 0.4}),
      units,
    );
    expect(line, contains('MAE'));
    expect(line, isNot(contains('±')));
    expect(line, contains(units.tempDeltaText(0.4)));
    expect(line, contains('0,7°F'));
  });
}
