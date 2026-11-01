import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_overview.dart';

final _now = DateTime.utc(2026, 10, 21, 12, 20);

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

// Synthetic fixtures only. All asynchronous entry points remain offline.
class _Weather extends WeatherProvider {
  _Weather({
    this.stale = false,
    this.probability = 0.1,
    this.source = DataSource.forecast,
    this.count = 24,
    this.forecastError,
  }) : super(initialSettings: const AppSettings());

  final bool stale;
  final double? probability;
  final DataSource source;
  final int count;
  final String? forecastError;

  @override
  DateTime get nowHcm => _now;

  @override
  bool get isStale => stale;

  @override
  WeatherData get weatherData => WeatherData(
    current: CurrentWeather(
      temperature: 27,
      condition: WeatherCondition.cloudy,
      lastUpdated: stale ? _now.subtract(const Duration(hours: 4)) : _now,
      source: DataSource.observed,
    ),
    hourlyForecast: [
      for (var i = 0; i < count; i++)
        HourlyForecast(
          time: HcmTime.startOfHour(_now).add(Duration(hours: i)),
          temperature: 27,
          condition: WeatherCondition.cloudy,
          rainProbability: probability,
          source: source,
        ),
    ],
    dailyForecast: const [],
    forecastError: forecastError,
  );

  @override
  CurrentWeather get currentWeather => weatherData.current;

  @override
  List<HourlyForecast> get hourlyForecast => weatherData.hourlyForecast;

  @override
  Future<void> initialize() async {}
}

Future<void> _pump(WidgetTester tester, _Weather weather) async {
  tester.view.physicalSize = const Size(320, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(weather.dispose);
  final locations = _Locations();
  addTearDown(locations.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: weather,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: HomeScreen(locations: locations),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Home withholds dry assurance for missing, partial, climate and stale input',
    (tester) async {
      for (final weather in [
        _Weather(probability: null),
        _Weather(count: 1),
        _Weather(source: DataSource.climatology),
        _Weather(stale: true),
        _Weather(forecastError: 'Synthetic unavailable model'),
      ]) {
        await _pump(tester, weather);
        final info = tester
            .widget<HomeWeatherOverview>(find.byType(HomeWeatherOverview))
            .info;
        expect(
          info.today,
          weather.stale
              ? 'Dữ liệu cũ; chưa thể kết luận về mưa'
              : 'Chưa đủ dữ liệu để kết luận về mưa',
        );
        expect(info.todayRain, isFalse);
        expect(info.isStale, weather.stale);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('fresh complete Home retains a useful summary', (tester) async {
    await _pump(tester, _Weather());
    final info = tester
        .widget<HomeWeatherOverview>(find.byType(HomeWeatherOverview))
        .info;
    expect(info.today, 'Không mưa đến tối');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    '320px Windows Home fits 200% segment text with refresh present',
    (tester) async {
      await _pump(tester, _Weather());
      final control = find.byType(CupertinoSlidingSegmentedControl<bool>);
      final details = find.descendant(
        of: control,
        matching: find.text('Điều kiện'),
      );
      await tester.scrollUntilVisible(
        control,
        160,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 30,
      );
      expect(control, findsOneWidget);
      await Scrollable.ensureVisible(tester.element(details), alignment: 0.5);
      await tester.pump();
      expect(find.byTooltip('Làm mới thời tiết'), findsOneWidget);
      expect(tester.getSize(control).height, greaterThanOrEqualTo(48));

      for (final label in ['Dự báo', 'Điều kiện']) {
        final finder = find.descendant(of: control, matching: find.text(label));
        final element = tester.element(finder);
        final text = tester.widget<Text>(finder);
        expect(MediaQuery.textScalerOf(element).scale(15), 30);
        final bounds = tester.getRect(finder);
        final painter = TextPainter(
          text: TextSpan(
            text: text.data,
            style: DefaultTextStyle.of(element).style.merge(text.style),
          ),
          textDirection: Directionality.of(element),
          textScaler: text.textScaler ?? MediaQuery.textScalerOf(element),
        )..layout(maxWidth: bounds.width);
        // Detect silent paragraph clipping, not just RenderFlex exceptions.
        expect(bounds.height + 0.1, greaterThanOrEqualTo(painter.height));
        expect(
          tester.getRect(control).inflate(0.1).contains(bounds.topLeft),
          isTrue,
        );
        expect(
          tester.getRect(control).inflate(0.1).contains(bounds.bottomRight),
          isTrue,
        );
        painter.dispose();
      }

      expect(details.hitTestable(), findsOneWidget);
      await tester.tap(details);
      await tester.pump();
      expect(
        tester
            .widget<CupertinoSlidingSegmentedControl<bool>>(control)
            .groupValue,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
