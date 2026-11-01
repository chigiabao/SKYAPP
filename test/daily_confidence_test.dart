import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/forecast/forecast_widgets.dart';
import 'package:sky_weather_app/ui/weather/weather_icons.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';

DailyForecast _day(String date, String? confidence, {double? rain}) =>
    DailyForecast.fromJson({
      'date': date,
      'temperature_min': 24.2,
      'temperature_max': 30.2,
      'weather_code': 80,
      'source': 'ai',
      'rain_day_probability': rain,
      'confidence': ?confidence,
      if (confidence != null) 'skill_note': 'Gần với trung bình nhiều năm.',
    });

Widget _host(WeatherProvider provider, Widget child) =>
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            disableAnimations: true,
          ),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  test('parses confidence and skill_note', () {
    final d = _day('2026-10-21', 'low', rain: 0.5);
    expect(d.confidence, ForecastConfidence.low);
    expect(d.isLowConfidence, isTrue);
    expect(d.skillNote, 'Gần với trung bình nhiều năm.');
    expect(d.displayWeatherCode, 3); // khong ve mua rao / dong
    expect(_day('2026-10-19', 'HIGH').confidence, ForecastConfidence.high);
    expect(_day('2026-10-20', 'medium').displayWeatherCode, 80);
  });

  test('legacy payload without confidence fields stays unchanged', () {
    final d = _day('2026-10-21', null);
    expect(d.confidence, isNull);
    expect(d.skillNote, isNull);
    expect(d.isLowConfidence, isFalse);
    expect(d.displayWeatherCode, 80);
    final odd = DailyForecast.fromJson({
      'date': '2026-10-21',
      'temperature_min': 24,
      'temperature_max': 30,
      'confidence': 42,
      'skill_note': '  ',
    });
    expect(odd.confidence, isNull);
    expect(odd.skillNote, isNull);
    expect(odd.displayWeatherCode, isNull);
    expect(confidenceCaption([d, odd]), isNull);
  });

  test('caption follows the first low-confidence day', () {
    final days = [
      _day('2026-10-19', 'high'),
      _day('2026-10-20', 'medium'),
      _day('2026-10-21', 'low'),
    ];
    expect(
      confidenceCaption(days),
      'Dự báo AI Sky Weather · ngày 1–2 tin cậy hơn, từ ngày 3 gần với '
      'trung bình nhiều năm · không phải cảnh báo chính thức',
    );
    expect(dailyRainText(_day('2026-10-21', 'low', rain: 0.1)), '10%');
    // Co xac suat -> luon hien % (ke ca < 20 %), nhat quan moi ngay.
    expect(dailyRainText(_day('2026-10-21', 'high', rain: 0.1)), '10%');
  });

  testWidgets('low-confidence row is dimmed trend with range and generic '
      'icon', (tester) async {
    final semantics = tester.ensureSemantics();
    final provider = WeatherProvider();
    addTearDown(provider.dispose);
    final days = [
      _day('2026-10-19', 'high', rain: 1),
      _day('2026-10-20', 'medium', rain: 0.5),
      _day('2026-10-21', 'low', rain: 0.5),
    ];
    await tester.pumpWidget(
      _host(
        provider,
        DailyForecastCard(days: days, nowHcm: DateTime(2026, 10, 19, 12)),
      ),
    );
    expect(find.text('Xu hướng'), findsOneWidget);
    expect(find.byKey(const ValueKey('daily-trend-tag')), findsOneWidget);
    expect(find.text('~24–30°'), findsOneWidget);
    expect(find.text('50%'), findsNWidgets(2));
    expect(
      find.text(
        'Dự báo AI Sky Weather · ngày 1–2 tin cậy hơn, từ ngày 3 gần với '
        'trung bình nhiều năm · không phải cảnh báo chính thức',
      ),
      findsOneWidget,
    );
    final icons = tester
        .widgetList<WeatherIcon>(find.byType(WeatherIcon))
        .toList();
    expect(icons.last.scene, isNot(icons[1].scene));
    expect(
      find.ancestor(
        of: find.byWidget(icons.last),
        matching: find.byType(Opacity),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('độ tin cậy thấp')), findsOneWidget);

    await tester.tap(find.byTooltip('Giải thích độ tin cậy'));
    await tester.pumpAndSettle();
    expect(find.text('Độ tin cậy dự báo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('legacy days show no trend label, caption or info button', (
    tester,
  ) async {
    final provider = WeatherProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      _host(provider, DailyForecastCard(days: [_day('2026-10-21', null)])),
    );
    expect(find.text('Xu hướng'), findsNothing);
    expect(find.byTooltip('Giải thích độ tin cậy'), findsNothing);
    expect(find.textContaining('~'), findsNothing);
  });

  testWidgets('day tab notice shows for low confidence only', (tester) async {
    final provider = WeatherProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      _host(
        provider,
        Column(
          children: [
            DayConfidenceNotice(day: _day('2026-10-21', 'low')),
            DayConfidenceNotice(day: _day('2026-10-19', 'high')),
            DayConfidenceNotice(day: _day('2026-10-19', null)),
          ],
        ),
      ),
    );
    expect(find.textContaining('Độ tin cậy thấp'), findsOneWidget);
    expect(find.text('Vì sao?'), findsOneWidget);
  });
}
