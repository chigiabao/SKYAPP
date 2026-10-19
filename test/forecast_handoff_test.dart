import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/ai_verify_screen.dart';
import 'package:sky_weather_app/screens/forecast/forecast_charts.dart';

final _issuedAt = DateTime.utc(2026, 10, 17, 17);

AIVerification _verification({bool incomplete = false}) => AIVerification(
  issuedAt: _issuedAt,
  modelVersion: 'handoff-v1',
  horizons: [
    for (var i = 0; i < 3; i++)
      AIVerificationItem(
        horizon: AIForecast.horizons[i],
        predictedTemperature: 26,
        actualTemperature: incomplete || i == 1 ? null : 27,
        absErrorTemperature: incomplete ? 1 : null,
      ),
  ],
);

AIForecast _intervals({String version = 'handoff-v1', bool enabled = true}) =>
    AIForecast(
      issuedAt: _issuedAt,
      modelVersion: version,
      enabledTargets: ['temperature', if (enabled) 'temperature_interval'],
      predictions: [
        for (final h in AIForecast.horizons)
          AIPrediction(
            timeLabel: h,
            temperature: 26,
            rainProbability: 0.2,
            temperatureLow: 25,
            temperatureHigh: 27,
            intervalLevel: 0.9,
          ),
      ],
    );

class _VerifyProvider extends WeatherProvider {
  _VerifyProvider(this.result) : super(initialSettings: const AppSettings());

  final AIVerification result;
  int calls = 0;

  @override
  Future<AIVerification> fetchAIVerification() async {
    calls++;
    return result;
  }
}

Future<void> _pump(
  WidgetTester tester,
  _VerifyProvider provider,
  Future<AIForecast?> Function(DateTime) loader,
) async {
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AIVerifyScreen(intervalLoader: loader),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('verification reloads when the selected place changes', (
    tester,
  ) async {
    final p = _VerifyProvider(_verification());
    var intervalCalls = 0;
    await _pump(tester, p, (_) async {
      intervalCalls++;
      return _intervals();
    });
    expect(p.calls, 1);
    expect(intervalCalls, 1);
    p.setLocation('another-place', fetch: false);
    await tester.pumpAndSettle();
    expect(p.calls, 2);
    expect(intervalCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry reloads intervals even for the same issue time', (
    tester,
  ) async {
    var calls = 0;
    await _pump(tester, _VerifyProvider(_verification()), (_) async {
      calls++;
      return calls == 1 ? null : _intervals();
    });
    expect(find.text('Dải khoảng 90%'), findsNothing);
    await tester.tap(find.byTooltip('Tải lại'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Dải khoảng 90%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final forecast in [
    _intervals(version: 'another-model'),
    _intervals(enabled: false),
  ]) {
    testWidgets('ineligible interval band: ${forecast.modelVersion}, '
        '${forecast.enabledTargets}', (tester) async {
      await _pump(
        tester,
        _VerifyProvider(_verification()),
        (_) async => forecast,
      );
      expect(find.text('Dải khoảng 90%'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a new issue request does not show retained interval data', (
    tester,
  ) async {
    var calls = 0;
    final pending = Completer<AIForecast?>();
    await _pump(tester, _VerifyProvider(_verification()), (_) {
      calls++;
      return calls == 1 ? Future.value(_intervals()) : pending.future;
    });
    expect(find.text('Dải khoảng 90%'), findsOneWidget);
    await tester.tap(find.byTooltip('Tải lại'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Dải khoảng 90%'), findsNothing);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('backend error without actual temperature does not crash', (
    tester,
  ) async {
    await _pump(
      tester,
      _VerifyProvider(_verification(incomplete: true)),
      (_) async => null,
    );
    expect(
      find.text('Chưa có số liệu thực tế để so với dự báo AI.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing actual temperatures break the verification line', (
    tester,
  ) async {
    await _pump(
      tester,
      _VerifyProvider(_verification()),
      (_) async => _intervals(),
    );
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(find.textContaining('Mốc 6h: AI dự báo'), findsOneWidget);
    expect(chart.data.lineBarsData.last.spots[1].isNull(), isTrue);
    expect(chart.duration, Duration.zero);
    expect(find.byType(ChartReveal), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
