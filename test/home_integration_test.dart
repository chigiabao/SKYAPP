import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/ui/weather/widgets/bottom_pill_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_overview.dart';
import 'package:sky_weather_app/ui/weather/widgets/hourly_strip.dart';
import 'package:sky_weather_app/ui/weather/widgets/rain_timeline_card.dart';

class _Weather extends WeatherProvider {
  _Weather() : super(initialSettings: const AppSettings());

  @override
  DateTime get nowHcm => DateTime.utc(2026, 10, 19, 9);

  @override
  CurrentWeather get currentWeather => CurrentWeather(
    locationName: 'Home',
    temperature: 28,
    condition: WeatherCondition.cloudy,
    lastUpdated: nowHcm,
  );

  @override
  List<HourlyForecast> get hourlyForecast => [
    for (var i = 0; i < 24; i++)
      HourlyForecast(
        time: nowHcm.add(Duration(hours: i)),
        temperature: 28,
        condition: WeatherCondition.cloudy,
        rainProbability: i >= 3 && i < 8 ? 0.9 : 0.05,
      ),
  ];

  @override
  List<DailyForecast> get dailyForecast => [
    for (var i = 0; i < 7; i++)
      DailyForecast(
        date: HcmTime.startOfDay(nowHcm).add(Duration(days: i)),
        tempMin: 24,
        tempMax: 30,
        condition: WeatherCondition.cloudy,
        precipitationMm: 0,
      ),
  ];

  @override
  Future<void> initialize() async {}
}

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

class _RevalidatingApi extends ApiService {
  static final now = DateTime.utc(2026, 10, 19, 9);
  final response = Completer<WeatherData>();
  late final cached = data(storm: true);

  WeatherData data({required bool storm}) => WeatherData(
    current: CurrentWeather(
      locationName: 'Home',
      temperature: 28,
      condition: WeatherCondition.cloudy,
      lastUpdated: now,
    ),
    hourlyForecast: [
      for (var i = 0; i < 24; i++)
        HourlyForecast(
          time: now.add(Duration(hours: i)),
          temperature: 28,
          condition: storm
              ? WeatherCondition.thunderstorm
              : WeatherCondition.cloudy,
          weatherCode: storm ? 95 : 3,
          rainProbability: storm ? 0.9 : 0,
        ),
    ],
    dailyForecast: const [],
  );

  @override
  Future<WeatherResult?> loadCachedResultFor(String locationId) async =>
      WeatherResult(cached, fromCache: true, savedAt: now);

  @override
  Future<WeatherData> fetchWeatherDataFor(String locationId, {DateTime? at}) =>
      response.future;
}

Future<void> _pumpHome(
  WidgetTester tester,
  double width, {
  WeatherProvider? weatherProvider,
  PlannerProvider? planner,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final weather = weatherProvider ?? _Weather();
  final locations = _Locations();
  addTearDown(weather.dispose);
  addTearDown(locations.dispose);
  if (planner != null) addTearDown(planner.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: weather),
        if (planner != null)
          ChangeNotifierProvider<PlannerProvider>.value(value: planner),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 900), disableAnimations: true),
          child: HomeScreen(locations: locations),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final outcome in ['clear', 'storm', 'offline']) {
    testWidgets('cached storm defers notices until revalidation: $outcome', (
      tester,
    ) async {
      final api = _RevalidatingApi();
      final weather = WeatherProvider(
        apiService: api,
        initialSettings: const AppSettings(),
        clock: () => DateTime.utc(2026, 10, 19, 2),
      );
      final planner = PlannerProvider();
      await planner.load();
      await _pumpHome(tester, 360, weatherProvider: weather, planner: planner);
      await planner.flush();
      expect(weather.isFromCache, isTrue);
      expect(weather.isRefreshing, isTrue);
      expect(planner.history, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PlannerProvider.historyKey), isNull);
      expect(prefs.getString(PlannerProvider.ledgerKey), isNull);

      if (outcome == 'offline') {
        api.response.completeError(ApiException(ApiErrorKind.network));
      } else {
        api.response.complete(
          outcome == 'storm' ? api.cached : api.data(storm: false),
        );
      }
      await tester.pump();
      await planner.flush();
      await tester.pump();
      expect(weather.isRefreshing, isFalse);
      expect(weather.isFromCache, outcome == 'offline');
      if (outcome == 'offline') expect(weather.isStale, isTrue);
      final expected = outcome == 'clear' ? isEmpty : isNotEmpty;
      expect(planner.history, expected);
      await prefs.reload();
      expect(
        jsonDecode(prefs.getString(PlannerProvider.historyKey) ?? '[]'),
        expected,
      );
      expect(
        jsonDecode(prefs.getString(PlannerProvider.ledgerKey) ?? '[]'),
        expected,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('floating bar retains an independent backdrop while scrolling', (
    tester,
  ) async {
    await _pumpHome(tester, 360);
    BackdropKey? backdropFor(Type type) => tester
        .renderObject<RenderBackdropFilter>(
          find
              .descendant(
                of: find.byType(type),
                matching: find.byType(BackdropFilter),
              )
              .first,
        )
        .backdropKey;
    final barKey = backdropFor(BottomPillBar);
    expect(barKey, isNotNull);
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    for (final offset in [500.0, 700.0]) {
      position.jumpTo(offset);
      await tester.pump();
      final cardKey = backdropFor(HourlyStrip);
      expect(cardKey, isNotNull);
      expect(backdropFor(BottomPillBar), same(barKey));
      expect(cardKey, isNot(same(barKey)));
      expect(tester.takeException(), isNull);
    }
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('daily follows hourly in the same column at $width', (
      tester,
    ) async {
      await _pumpHome(tester, width);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(500);
      await tester.pump();
      final hourly = tester.getRect(find.byType(HourlyStrip));
      final daily = tester.getRect(find.byType(DailyForecastCard));
      expect(daily.top, greaterThanOrEqualTo(hourly.bottom));
      expect(daily.left, closeTo(hourly.left, 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home wires rain guidance and keeps the sun off settings', (
    tester,
  ) async {
    await _pumpHome(tester, 360);
    final hero = tester.widget<HomeWeatherOverview>(
      find.byType(HomeWeatherOverview),
    );
    expect(hero.info.today, contains('mang áo mưa khi về'));
    expect(hero.info.todayRain, isTrue);
    final background = tester.widget<WeatherBackground>(
      find.byType(WeatherBackground),
    );
    expect(
      background.celestial!.discRect.overlaps(
        tester.getRect(find.byTooltip('Cài đặt')),
      ),
      isFalse,
    );
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scroll.position.jumpTo(200);
    await tester.pump();
    expect(find.byType(RainTimelineCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps scroll position and navigation pinned', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpHome(tester, 360);
    final view = find.byType(CustomScrollView);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: view, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(
      tester.widget<SliverAppBar>(find.byType(SliverAppBar)).pinned,
      isTrue,
    );
    final settingsBefore = tester.getRect(find.byTooltip('Cài đặt'));
    final offset = position.viewportDimension * 0.15;
    position.jumpTo(offset);
    await tester.pump();
    ScrollEndNotification(
      metrics: position,
      context: tester.element(view),
    ).dispatch(tester.element(view));
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, closeTo(offset, 0.01));
    expect(tester.getRect(find.byTooltip('Cài đặt')), settingsBefore);
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
    expect(tester.takeException(), isNull);
  });
}
