import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/widgets/hourly_strip.dart';
import 'package:sky_weather_app/utils/formatters.dart';
import 'package:sky_weather_app/utils/theme.dart';

/// Du lieu gia CHI dung trong test (khong goi mang).
class _FakeApi extends ApiService {
  final DateTime now;
  _FakeApi(this.now);

  @override
  Future<WeatherData> fetchWeatherData({DateTime? at}) async {
    final base = HcmTime.startOfHour(now);
    return WeatherData(
      current: CurrentWeather(
        locationName: 'TP. Hồ Chí Minh',
        temperature: 26.2,
        feelsLike: 32.6,
        condition: WeatherCondition.cloudy,
        lastUpdated: base,
        humidity: 93,
        windSpeed: 11.8,
        windGusts: 27.6,
        windDirection: 135,
        cloudCover: 91,
        precipitationMm: 0.4,
        pressure: 1011.3,
        visibilityKm: 16.96,
      ),
      hourlyForecast: [
        for (var i = 0; i < 12; i++)
          HourlyForecast(
            time: base.add(Duration(hours: i)),
            temperature: 25.7,
            condition: WeatherCondition.rainy,
            rainProbability: 1.0,
          ),
      ],
      dailyForecast: [
        for (var i = 0; i < 7; i++)
          DailyForecast(
            date: base.add(Duration(days: i)),
            tempMin: 24,
            tempMax: 30.4,
            condition: WeatherCondition.showers,
            precipitationMm: i == 0 ? 0.4 : 113.5,
            precipitationMedian: i == 0 ? 0.4 : 12.6,
            rainDayProbability: i.isEven ? 1.0 : null,
          ),
      ],
      aiForecast: AIForecast(
        issuedAt: base,
        modelVersion: 'lgbm-test',
        predictions: const [
          AIPrediction(timeLabel: '1h', temperature: 26, rainProbability: 0.11),
          AIPrediction(timeLabel: '3h', temperature: 25, rainProbability: 1.0),
          AIPrediction(timeLabel: '6h', temperature: 25, rainProbability: 0.16),
        ],
      ),
    );
  }
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required double scale,
  required ThemeData theme,
}) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final now = HcmTime.now();
  final provider = WeatherProvider(
    apiService: _FakeApi(now),
    initialSettings: const AppSettings(),
  );

  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 740),
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: const HomeScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in [1.0, 1.3, 1.6, 2.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'Home khong tran layout o textScale $scale (${dark ? 'toi' : 'sang'})',
        (tester) async {
          await _pumpHome(
            tester,
            scale: scale,
            theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          );
          expect(find.text('TP. Hồ Chí Minh'), findsOneWidget);

          // Cuon qua toan bo trang; ghi nhan cac the da hien.
          final seen = <String>{};
          for (final conditions in [false, true]) {
            if (conditions) {
              final scrollable = find
                  .descendant(
                    of: find.byType(CustomScrollView),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              tester.state<ScrollableState>(scrollable).position.jumpTo(0);
              await tester.pump();
              await tester.scrollUntilVisible(
                find.text('Điều kiện'),
                200,
                scrollable: scrollable,
              );
              await tester.pump();
              await Scrollable.ensureVisible(
                tester.element(find.text('Điều kiện')),
                alignment: 0.2,
              );
              await tester.pump();
              await tester.tap(find.text('Điều kiện'));
              await tester.pump();
              expect(
                tester
                    .widget<SegmentedButton<bool>>(
                      find.byType(SegmentedButton<bool>),
                    )
                    .selected,
                {true},
              );
            }
            for (var i = 0; i < 10; i++) {
              for (final t in ['THEO GIỜ', 'DỰ BÁO 7 NGÀY', 'CHỈ SỐ UV']) {
                if (find.text(t).evaluate().isNotEmpty) seen.add(t);
              }
              await tester.drag(
                find.byType(CustomScrollView),
                const Offset(0, -300),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
            }
          }
          expect(seen, containsAll(['THEO GIỜ', 'DỰ BÁO 7 NGÀY', 'CHỈ SỐ UV']));
          // Bat ky RenderFlex overflow nao se nem FlutterError -> takeException.
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Danh dau "Bây giờ" cho o gio hien tai', (tester) async {
    await _pumpHome(tester, scale: 1.0, theme: AppTheme.lightTheme);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(HourlyStrip),
        matching: find.text('Bây giờ'),
      ),
      findsOneWidget,
    );
  });

  test('Dinh dang luong mua', () {
    expect(WeatherFormat.rainMm(0), '0 mm');
    expect(WeatherFormat.rainMm(0.4), '0,4 mm');
    expect(WeatherFormat.rainMm(0.96), '1 mm');
    expect(WeatherFormat.rainMm(13.49), '13 mm');
    expect(WeatherFormat.rainMm(0.01), '< 0,1 mm');
    expect(WeatherFormat.compass(101), 'Đông');
    expect(WeatherFormat.compass(135), 'Đông Nam');
    expect(WeatherFormat.compass(350), 'Bắc');
  });
}
