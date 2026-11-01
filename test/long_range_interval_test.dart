import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/screens/forecast/charts/hourly_temperature_chart.dart';

HourlyForecast _hour(int i, {bool interval = true}) => HourlyForecast.fromJson({
  'timestamp': '2026-10-22T${(10 + i).toString().padLeft(2, '0')}:00:00+07:00',
  'temperature': 28 + i * 0.1,
  'source': 'ai',
  if (interval) ...{
    'temperature_p10': 27.0,
    'temperature_p90': 30.0,
    'interval_level': 0.8,
  },
});

void main() {
  test('long-range AI hour parses calibrated range fields', () {
    final h = HourlyForecast.fromJson({
      'timestamp': '2026-10-22T10:00:00+07:00',
      'temperature': 28,
      'source': 'ai',
      'temperature_p10': 26.5,
      'temperature_p90': 29.5,
      'humidity_p10': 60,
      'humidity_p90': 85,
      'wind_speed_p10': 4,
      'wind_speed_p90': 12,
      'precipitation_p90': 1.2,
      'interval_level': 0.8,
    });
    expect(h.hasTemperatureInterval, isTrue);
    expect(h.temperatureP10, 26.5);
    expect(h.humidityP90, 85);
    expect(h.windSpeedP10, 4);
    expect(h.precipitationP90, 1.2);
    expect(h.intervalLevel, 0.8);
    final gated = HourlyForecast.fromJson({
      'timestamp': '2026-10-28T10:00:00+07:00',
      'temperature': 28,
      'source': 'ai',
      'temperature_p10': null,
      'temperature_p90': null,
    });
    expect(gated.hasTemperatureInterval, isFalse);
  });

  Future<String> chartLabel(
    WidgetTester tester,
    List<HourlyForecast> hours,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HourlyTemperatureChart(
            hours: hours,
            nowIndex: 0,
            units: const UnitPrefs(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = find.bySemanticsLabel(RegExp('Biểu đồ nhiệt độ'));
    final label = tester.getSemantics(node).label;
    semantics.dispose();
    return label;
  }

  testWidgets('hourly chart shows the 80% range as uncertainty, not accuracy', (
    tester,
  ) async {
    final label = await chartLabel(tester, [
      for (var i = 0; i < 6; i++) _hour(i),
    ]);
    expect(label, contains('Dải khoảng 80%'));
    expect(label, contains('không phải độ chính xác'));
    expect(label, isNot(contains('độ chính xác 80%')));
    expect(find.text('Dải khoảng 80% (mức bất định)'), findsOneWidget);
  });

  testWidgets('hourly chart without intervals draws no band', (tester) async {
    final label = await chartLabel(tester, [
      for (var i = 0; i < 6; i++) _hour(i, interval: false),
    ]);
    expect(label, isNot(contains('khoảng')));
    expect(find.textContaining('Dải'), findsNothing);
  });
}
