import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/forecast/forecast_source.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';
import 'package:sky_weather_app/widgets/daily_item.dart';

void main() {
  test('self-trained source stays distinct from external forecasts', () {
    expect(parseDataSource('ai'), DataSource.ai);
    expect(parseDataSource('forecast'), DataSource.forecast);
    final source = ForecastSource.fromItems([DataSource.ai, DataSource.ai]);
    expect(source.isRealForecast, isTrue);
    expect(source.label, 'Dự báo AI Sky Weather');
    expect(source.label, isNot(contains('Open-Meteo')));
  });

  test('unavailable forecast survives parsing and cache trimming', () {
    final data = WeatherData.fromJson({
      'current': {'temperature': 29, 'timestamp': '2026-10-19T15:00:00+07:00'},
      'hourly': [],
      'daily': [],
      'forecast_error': 'Model chưa sẵn sàng',
    }, locationName: 'TP.HCM');
    expect(data.current.temperature, 29);
    expect(data.hourlyForecast, isEmpty);
    expect(data.dailyForecast, isEmpty);
    expect(data.forecastError, 'Model chưa sẵn sàng');
    expect(
      data.withoutPastItems(DateTime.utc(2026, 10, 19, 16)).forecastError,
      data.forecastError,
    );
  });

  test('AI hours preserve missing fields and true zeros', () {
    final hour = HourlyForecast.fromJson({
      'temperature': 28,
      'timestamp': '2026-10-19T16:00:00+07:00',
      'source': 'ai',
      'rain_probability': 0,
      'precipitation': 0,
    });
    expect(hour.source, DataSource.ai);
    expect(hour.rainProbability, 0);
    expect(hour.precipitationMm, 0);
    expect(hour.uvIndex, isNull);
    expect(hour.windGusts, isNull);
    expect(hour.apparentTemperature, isNull);
  });

  test('AI day without rainfall target never becomes zero rain', () {
    final day = DailyForecast.fromJson({
      'date': '2026-10-20',
      'temperature_min': 24,
      'temperature_max': 30,
      'source': 'ai',
      'rain_day_probability': null,
      'precipitation_total': null,
    });
    expect(day.precipitationMm, isNull);
    expect(day.rainDayProbability, isNull);
    expect(day.rainDayPercent, isNull);
  });

  for (final legacy in [false, true]) {
    testWidgets('AI daily null has no visible or spoken percentage '
        '(legacy: $legacy)', (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final provider = WeatherProvider();
      addTearDown(provider.dispose);
      final day = DailyForecast.fromJson({
        'date': '2026-10-20',
        'temperature_min': 24,
        'temperature_max': 30,
        'source': 'ai',
        'rain_day_probability': null,
        'precipitation_total': 12,
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: provider,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 740),
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: legacy
                    ? DailyItem(forecast: day, sourceTag: DataSource.ai)
                    : DailyForecastCard(days: [day]),
              ),
            ),
          ),
        ),
      );
      expect(dailyRainText(day), isNull);
      expect(find.textContaining('%'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('khả năng mưa|%')), findsNothing);
      expect(find.textContaining('AI'), findsWidgets);
      if (legacy) expect(find.text('12 mm'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
