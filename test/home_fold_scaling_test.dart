import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/ui/weather/widgets/collapsing_header.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_navigation.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_overview.dart';
import 'package:sky_weather_app/ui/weather/widgets/hourly_strip.dart';
import 'package:sky_weather_app/ui/weather/widgets/rain_timeline_card.dart';
import 'package:sky_weather_app/utils/theme.dart';

final _now = DateTime.utc(2026, 10, 21, 12);

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

/// Synthetic UI fixtures only; no network, persistence, or live readings.
class _Weather extends WeatherProvider {
  _Weather({this.stale = false, this.missing = false})
    : super(initialSettings: const AppSettings());

  final bool stale;
  final bool missing;

  @override
  DateTime get nowHcm => _now;

  @override
  bool get isStale => stale;

  @override
  bool get isFromCache => stale;

  @override
  DateTime? get cachedAt =>
      stale ? _now.subtract(const Duration(hours: 3)) : null;

  @override
  WeatherData get weatherData => WeatherData(
    current: CurrentWeather(
      temperature: 27,
      condition: WeatherCondition.partlyCloudy,
      feelsLike: missing ? null : 33,
      humidity: missing ? null : 78,
      windSpeed: missing ? null : 9,
      lastUpdated: stale ? _now.subtract(const Duration(hours: 3)) : _now,
      source: DataSource.forecast,
    ),
    hourlyForecast: missing
        ? const []
        : [
            for (var i = 0; i < 24; i++)
              HourlyForecast(
                time: _now.add(Duration(hours: i)),
                temperature: 27,
                condition: WeatherCondition.cloudy,
                rainProbability: 0.4,
                precipitationMm: 0,
                source: DataSource.forecast,
              ),
          ],
    dailyForecast: missing
        ? const []
        : [
            for (var i = 0; i < 7; i++)
              DailyForecast(
                date: _now.add(Duration(days: i)),
                tempMin: 24,
                tempMax: 32,
                condition: WeatherCondition.cloudy,
                precipitationMm: 0,
                source: DataSource.forecast,
              ),
          ],
  );

  @override
  CurrentWeather get currentWeather => weatherData.current;

  @override
  List<HourlyForecast> get hourlyForecast => weatherData.hourlyForecast;

  @override
  List<DailyForecast> get dailyForecast => weatherData.dailyForecast;

  @override
  Future<void> initialize() async {}
}

Future<void> _pump(
  WidgetTester tester,
  Size size,
  double scale, {
  bool stale = false,
  bool missing = false,
  bool light = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final weather = _Weather(stale: stale, missing: missing);
  final locations = _Locations();
  addTearDown(weather.dispose);
  addTearDown(locations.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: weather,
      child: MaterialApp(
        theme: light ? AppTheme.lightTheme : AppTheme.darkTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: const EdgeInsets.only(top: 24, bottom: 24),
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: HomeScreen(locations: locations),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Finder get _scrollable => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _scan(WidgetTester tester, {bool forecast = false}) async {
  final position = tester.state<ScrollableState>(_scrollable).position;
  var sawHourly = false;
  var sawDaily = false;
  var sawRain = false;
  for (var i = 0; i < 40; i++) {
    expect(tester.takeException(), isNull);
    sawHourly |= find.byType(HourlyStrip).evaluate().isNotEmpty;
    sawDaily |= find.byType(DailyForecastCard).evaluate().isNotEmpty;
    sawRain |= find.byType(RainTimelineCard).evaluate().isNotEmpty;
    if (position.pixels >= position.maxScrollExtent) {
      if (forecast) {
        expect(sawHourly, isTrue);
        expect(sawDaily, isTrue);
        expect(sawRain, isTrue);
      }
      return;
    }
    position.jumpTo(
      (position.pixels + 300).clamp(0.0, position.maxScrollExtent).toDouble(),
    );
    await tester.pump();
  }
  fail('Home content should be reachable within 40 scroll steps');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Real bundled font metrics are necessary for fold-position assertions.
    final fonts = FontLoader('Inter');
    for (final weight in [
      'ExtraLight',
      'Light',
      'Regular',
      'Medium',
      'SemiBold',
    ]) {
      fonts.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await fonts.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [
    const Size(320, 667),
    const Size(390, 844),
    const Size(1440, 960),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Home fold, scrolling and conditions $size x$scale', (
        tester,
      ) async {
        await _pump(tester, size, scale);
        expect(tester.takeException(), isNull);
        final overview = find.byType(HomeWeatherOverview);
        final hourly = find.byType(HourlyStrip);
        final navigation = find.byType(HomeNavigation);
        if (scale == 1) {
          expect(find.byType(RainTimelineCard), findsOneWidget);
        }
        expect(
          find.ancestor(of: overview, matching: find.byType(GlassCard)),
          findsNothing,
        );
        if (size.width >= 900) {
          expect(
            tester.getRect(hourly).left,
            greaterThan(tester.getRect(overview).right),
          );
          expect(tester.getRect(hourly).top, lessThan(220));
          // The daily section now begins in the first desktop viewport.
          if (scale == 1) {
            expect(
              tester.getRect(find.byType(DailyForecastCard)).top,
              lessThan(size.height),
            );
          }
        } else if (scale == 1) {
          expect(
            tester.getRect(hourly).top + 32,
            lessThan(tester.getRect(navigation).top),
            reason: 'Hourly heading must clear the fixed navigation, not just the viewport',
          );
        }
        for (final tooltip in [
          'Cài đặt',
          'Bản đồ',
          'Tôi sắp ra ngoài',
          'Danh sách địa điểm',
        ]) {
          final rect = tester.getRect(find.byTooltip(tooltip));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        final trip = find.widgetWithText(
          CupertinoButton,
          'Lên kế hoạch ra ngoài',
        );
        expect(tester.getSize(trip).height, greaterThanOrEqualTo(48));
        expect(tester.hasRunningAnimations, isFalse);
        await _scan(tester, forecast: true);
        final position = tester.state<ScrollableState>(_scrollable).position;
        position.jumpTo(0);
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('Điều kiện'),
          200,
          scrollable: _scrollable,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text('Điều kiện')),
          alignment: 0.2,
        );
        await tester.pump();
        await tester.tap(find.text('Điều kiện'));
        await tester.pump();
        expect(
          tester
              .widget<CupertinoSlidingSegmentedControl<bool>>(
                find.byType(CupertinoSlidingSegmentedControl<bool>),
              )
              .groupValue,
          isTrue,
        );
        await _scan(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Short overview saves at least 48 dp without smaller text x$scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Future<double> measure(double height) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(320, height),
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: HomeWeatherOverview(
                        info: const WeatherHeaderInfo(
                          city: 'Test',
                          detail: 'Test region',
                          temperature: '27°',
                          condition: 'Có mây',
                          highLow: 'Cao 32° · Thấp 24°',
                          today: 'Không mưa đến tối',
                          updated: 'Cập nhật 12:00',
                          sourceLabel: 'dự báo mô hình',
                        ),
                        onTrip: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(tester.widget<Text>(find.text('27°')).style?.fontSize, 96);
          expect(tester.widget<Text>(find.text('Có mây')).style?.fontSize, 20);
          final summary = tester.element(find.text('Không mưa đến tối'));
          expect(MediaQuery.textScalerOf(summary).scale(16), scale * 16);
          return tester.getSize(find.byType(HomeWeatherOverview)).height;
        }

        final spacious = await measure(844);
        final compact = await measure(667);
        expect(spacious - compact, greaterThanOrEqualTo(47.9));
        if (scale == 1) {
          expect(
            tester.getCenter(find.text('27°')).dy,
            closeTo(tester.getCenter(find.text('Có mây')).dy, 0.1),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final light in [false, true]) {
    testWidgets('200% missing and stale data remain explicit, light=$light', (
      tester,
    ) async {
      await _pump(
        tester,
        const Size(320, 667),
        2,
        stale: true,
        missing: true,
        light: light,
      );
      final overview = find.byType(HomeWeatherOverview);
      expect(
        find.descendant(of: overview, matching: find.text('Dữ liệu cũ')),
        findsOneWidget,
      );
      expect(find.textContaining('Đã lưu'), findsOneWidget);
      expect(find.textContaining('dự báo mô hình'), findsOneWidget);
      expect(find.text('Chưa có dự báo theo giờ'), findsOneWidget);
      expect(find.textContaining('Cao '), findsNothing);
      expect(find.textContaining('Cảm giác '), findsNothing);
      expect(find.byType(HourlyStrip), findsNothing);
      expect(find.byType(RainTimelineCard), findsNothing);
      await _scan(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    '320px alert keeps full text, scaled ticks and separate 48dp actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      var dismissed = 0;
      final weather = _Weather();
      addTearDown(weather.dispose);
      const title = 'Cảnh báo · Dông, sét và mưa lớn · 12:00–18:00';
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: weather,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 667),
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: RainTimelineCard(
                      title: title,
                      slots: [
                        for (var i = 0; i < 24; i++)
                          (
                            time: _now.add(Duration(hours: i)),
                            p: 0.9,
                            mm: 2.0,
                            thunder: true,
                          ),
                      ],
                      onOpen: () => opened++,
                      onDismiss: () => dismissed++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.text(title)).maxLines, isNull);
      expect(
        tester.widget<Text>(find.textContaining('tổng 48,0 mm')).maxLines,
        isNull,
      );
      expect(find.byType(FittedBox), findsNothing);
      final tick = tester.element(find.text('${_now.hour}h'));
      expect(MediaQuery.textScalerOf(tick).scale(12), 24);
      final close = find.byTooltip('Đóng cảnh báo');
      expect(tester.getSize(close), const Size(48, 48));
      await tester.tap(find.text(title));
      await tester.tap(close);
      expect((opened, dismissed), (1, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
