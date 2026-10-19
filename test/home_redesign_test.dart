import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/ui/weather/widgets/bottom_pill_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/collapsing_header.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_navigation.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_overview.dart';

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

class _UnavailableWeather extends WeatherProvider {
  _UnavailableWeather() : super(initialSettings: const AppSettings());

  int refreshes = 0;

  @override
  WeatherData get weatherData => WeatherData(
    current: CurrentWeather(
      locationName: 'Home',
      temperature: 28,
      condition: WeatherCondition.cloudy,
      lastUpdated: DateTime.utc(2026, 10, 19, 9),
    ),
    hourlyForecast: const [],
    dailyForecast: const [],
    forecastError: 'Model input is stale',
  );

  @override
  CurrentWeather get currentWeather => weatherData.current;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> refreshWeatherData() async {
    refreshes++;
  }
}

class _ExperimentalWeather extends _UnavailableWeather {
  @override
  WeatherData get weatherData => WeatherData(
    current: super.weatherData.current,
    hourlyForecast: [
      HourlyForecast(
        time: DateTime.utc(2026, 10, 19, 9),
        temperature: 28,
        condition: WeatherCondition.cloudy,
        source: DataSource.ai,
      ),
    ],
    dailyForecast: const [],
  );

  @override
  List<HourlyForecast> get hourlyForecast => weatherData.hourlyForecast;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in [1.0, 2.0]) {
    testWidgets('phone navigation reflows without shrinking text x$scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      var maps = 0;
      var trips = 0;
      var places = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 740),
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: BottomPillBar(
                    pageCount: 12,
                    currentPage: 3,
                    onHome: () {},
                    onMap: () => maps++,
                    onLocations: () => places++,
                    onTrip: () => trips++,
                    tripRainPercent: 70,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(FittedBox), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Hôm nay')),
        matchesSemantics(
          label: 'Hôm nay',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
      for (final tooltip in [
        'Bản đồ',
        'Tôi sắp ra ngoài',
        'Danh sách địa điểm',
      ]) {
        final button = find.byTooltip(tooltip);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        await tester.tap(button);
      }
      expect((maps, trips, places), (1, 1, 1));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(BottomPillBar)).height,
        lessThanOrEqualTo(
          BottomPillBar.heightFor(288, TextScaler.linear(scale)),
        ),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });
  }

  testWidgets('summary wraps at 200 percent and never invents missing values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var opened = 0;
    final weather = _UnavailableWeather();
    addTearDown(weather.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: HomeWeatherOverview(
                    info: const WeatherHeaderInfo(
                      city: 'Home',
                      detail: 'Saved place',
                      temperature: '28°',
                      condition: 'Nhiều mây',
                      updated: 'Cập nhật 09:00',
                      isStale: true,
                      sourceLabel: 'Nguồn: Mô hình',
                    ),
                    onTrip: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Chưa có dự báo theo giờ'), findsOneWidget);
    expect(find.text('Dữ liệu cũ'), findsOneWidget);
    expect(find.textContaining('Cao '), findsNothing);
    await tester.ensureVisible(find.text('Lên kế hoạch ra ngoài'));
    await tester.tap(find.text('Lên kế hoạch ra ngoài'));
    expect(opened, 1);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('Home exposes unavailable model and refresh at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weather = _UnavailableWeather();
      final locations = _Locations();
      addTearDown(weather.dispose);
      addTearDown(locations.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: weather,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                disableAnimations: true,
              ),
              child: HomeScreen(locations: locations),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Dự báo mô hình không sẵn sàng.'),
        findsOneWidget,
      );
      expect(find.textContaining('Model input is stale'), findsOneWidget);
      await tester.tap(find.text('Làm mới'));
      expect(weather.refreshes, 1);
      expect(
        tester.widget<HomeNavigation>(find.byType(HomeNavigation)).vertical,
        width >= 1100,
      );
      await tester.ensureVisible(find.text('Điều kiện'));
      await tester.pump();
      await Scrollable.ensureVisible(
        tester.element(find.text('Điều kiện')),
        alignment: 0.2,
      );
      await tester.pump();
      await tester.tap(find.text('Điều kiện'));
      await tester.pump();
      expect(find.byKey(const ValueKey('metric-wind')), findsOneWidget);
      // The warning is not hidden by switching the information view.
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pump();
      expect(find.textContaining('Model input is stale'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('AI forecast carries a visible experimental limitation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final weather = _ExperimentalWeather();
    final locations = _Locations();
    addTearDown(weather.dispose);
    addTearDown(locations.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: weather,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 900),
              disableAnimations: true,
            ),
            child: HomeScreen(locations: locations),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('AI thử nghiệm'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('AI thử nghiệm'), findsOneWidget);
    expect(
      find.text('Dự báo xa còn sai số; không phải cảnh báo chính thức.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
