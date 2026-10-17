import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

/// Du lieu gia CHI dung trong test (khong goi mang).
class _FakeApi extends ApiService {
  _FakeApi(this.now);
  final DateTime now;

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
        uvIndex: 5,
        usAqi: 60,
        pm25: 15,
      ),
      hourlyForecast: [
        for (var i = 0; i < 24; i++)
          HourlyForecast(
            time: base.add(Duration(hours: i)),
            temperature: 27,
            condition: WeatherCondition.cloudy,
            rainProbability: 0.2,
            windGusts: 20,
          ),
      ],
      dailyForecast: [
        for (var i = 0; i < 7; i++)
          DailyForecast(
            date: base.add(Duration(days: i)),
            tempMin: 24,
            tempMax: 31,
            condition: WeatherCondition.cloudy,
            precipitationMm: 3,
          ),
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required PreferencesProvider prefs,
  double scale = 1.0,
  Size size = const Size(360, 740),
  PlannerProvider? planner,
  LocationProvider? locations,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final wp = WeatherProvider(
    apiService: _FakeApi(HcmTime.now()),
    initialSettings: const AppSettings(),
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: wp),
        ChangeNotifierProvider<PreferencesProvider>.value(value: prefs),
        if (planner != null)
          ChangeNotifierProvider<PlannerProvider>.value(value: planner),
        if (locations != null)
          ChangeNotifierProvider<LocationProvider>.value(value: locations),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: prefs.applyTo(
            MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
          ),
          child: AppSceneScope(child: child!),
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Cuon het danh sach, moi buoc kiem tra khong co loi tran bo cuc.
Future<void> _scrollAll(WidgetTester tester, Finder scrollable) async {
  for (var i = 0; i < 25; i++) {
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pump();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PreferencesProvider', () {
    test('export / import khu hoi + luu shared_preferences', () async {
      final p = PreferencesProvider();
      p.setUnits(const UnitPrefs(wind: WindUnit.beaufort));
      p.moveMetric(HomeMetric.pressure, -1);
      p.setMetricVisible(HomeMetric.uv, false);
      p.setTextScale(1.3);
      p.setHighContrast(true);
      p.setReduceMotion(true);
      final json = p.exportSettings();

      final q = PreferencesProvider();
      await q.importSettings(json);
      expect(q.units.wind, WindUnit.beaufort);
      expect(q.metricOrder, p.metricOrder);
      expect(q.isVisible(HomeMetric.uv), isFalse);
      expect(q.textScale, 1.3);
      expect(q.highContrast && q.reduceMotion, isTrue);

      // Doc lai tu bo nho.
      final r = PreferencesProvider();
      await r.load();
      expect(r.exportSettings(), q.exportSettings());
    });

    test('du lieu sai -> mac dinh; thu tu thieu duoc bo sung', () async {
      final p = PreferencesProvider();
      await p.importSettings({
        'metricOrder': ['sun', 'sun', 'khong-co', 'wind'],
        'textScale': 7,
        'units': 'x',
      });
      expect(p.metricOrder.take(2), [HomeMetric.sun, HomeMetric.wind]);
      expect(p.metricOrder.toSet(), HomeMetric.values.toSet());
      expect(p.textScale, 1.0);
      expect(p.units, const UnitPrefs());
    });

    test('nut len/xuong va keo tha', () {
      final p = PreferencesProvider();
      p.moveMetric(HomeMetric.aqi, -1); // da o dau -> khong doi
      expect(p.metricOrder.first, HomeMetric.aqi);
      p.moveMetric(HomeMetric.aqi, 1);
      expect(p.metricOrder.take(2), [HomeMetric.feelsLike, HomeMetric.aqi]);
      p.reorderMetric(p.metricOrder.indexOf(HomeMetric.sun), 0);
      expect(p.metricOrder.first, HomeMetric.sun);
    });

    test('co chu: nhan voi he thong va co tran', () {
      final p = PreferencesProvider()..setTextScale(1.3);
      final mq = p.applyTo(
        const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      );
      expect(mq.textScaler.scale(10), closeTo(26, 0.01));
      final big = p.applyTo(
        const MediaQueryData(textScaler: TextScaler.linear(3.0)),
      );
      expect(big.textScaler.scale(10), 30);
    });
  });

  group('Canh bao theo dia diem', () {
    final now = DateTime.utc(2026, 10, 16, 12, 20);
    final hours = [
      for (var i = 0; i < 6; i++)
        HourlyForecast(
          time: DateTime.utc(2026, 10, 16, 12 + i),
          temperature: 28,
          condition: WeatherCondition.cloudy,
          rainProbability: 0.1,
          windGusts: 40,
          source: DataSource.forecast,
        ),
    ];
    bool hasWind(AlertSettings s, String id) => evaluateAlerts(
      hours,
      nowHcm: now,
      placeId: id,
      settings: s,
    ).any((e) => e.type == AlertType.wind);

    test('nguong rieng chi ap dung cho dia diem do', () {
      const base = AlertSettings(); // gio giat 50 km/h
      expect(hasWind(base, 'a'), isFalse);
      final s = base.withPlace(
        'a',
        const PlaceAlertOverride().withThreshold(AlertType.wind, 30),
      );
      expect(hasWind(s, 'a'), isTrue);
      expect(hasWind(s, 'b'), isFalse);
    });

    test('tat canh bao cho dia diem', () {
      final s = const AlertSettings(windGust: 30)
          .withPlace('a', const PlaceAlertOverride(enabled: false));
      expect(
        evaluateAlerts(hours, nowHcm: now, placeId: 'a', settings: s),
        isEmpty,
      );
      expect(hasWind(s, 'b'), isTrue);
    });

    test('JSON khu hoi; mac dinh thi khong luu', () {
      final s = const AlertSettings()
          .withPlace('a', const PlaceAlertOverride(enabled: false))
          .withPlace(
            'b',
            const PlaceAlertOverride().withThreshold(AlertType.heavyRain, 5),
          )
          .withPlace('c', const PlaceAlertOverride());
      final back = AlertSettings.fromJson(s.toJson());
      expect(back.places.keys, unorderedEquals(['a', 'b']));
      expect(back.placeOverride('a').enabled, isFalse);
      expect(back.forPlace('b').heavyRainMm, 5);
      expect(back.forPlace('c').heavyRainMm, 10);
    });
  });

  group('Home', () {
    testWidgets('the chi so theo thu tu uu tien, an muc da tat', (
      tester,
    ) async {
      final prefs = PreferencesProvider();
      await prefs.importSettings({
        'metricOrder': ['pressure', 'wind', 'sun', 'humidity'],
        'hiddenMetrics': ['uv', 'cloud'],
        'units': {'wind': 'ms', 'pressure': 'mmhg'},
      });
      await _pump(
        tester,
        const HomeScreen(),
        prefs: prefs,
        size: const Size(400, 6000),
      );
      Offset at(HomeMetric m) =>
          tester.getTopLeft(find.byKey(ValueKey('metric-${m.name}')));
      final pressure = at(HomeMetric.pressure);
      final wind = at(HomeMetric.wind);
      final sun = at(HomeMetric.sun);
      final humidity = at(HomeMetric.humidity);
      // Ap suat + gio cung hang (trai -> phai), mat troi ca hang ben duoi.
      expect(pressure.dy, wind.dy);
      expect(pressure.dx, lessThan(wind.dx));
      expect(sun.dy, greaterThan(wind.dy));
      expect(humidity.dy, greaterThan(sun.dy));
      expect(find.byKey(const ValueKey('metric-uv')), findsNothing);
      expect(find.byKey(const ValueKey('metric-cloud')), findsNothing);
      // Don vi da chon.
      expect(find.textContaining('mmHg', findRichText: true), findsWidgets);
      expect(find.textContaining('m/s', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.3, 2.0]) {
      testWidgets('Home khong tran o textScale $scale (tuong phan cao)', (
        tester,
      ) async {
        final prefs = PreferencesProvider()..setHighContrast(true);
        await _pump(tester, const HomeScreen(), prefs: prefs, scale: scale);
        expect(find.text('TP. Hồ Chí Minh'), findsOneWidget);
        await _scrollAll(tester, find.byType(CustomScrollView));
      });
    }

    testWidgets('co chu trong app x2 he thong van khong tran', (tester) async {
      final prefs = PreferencesProvider()..setTextScale(1.3);
      await _pump(
        tester,
        const HomeScreen(),
        prefs: prefs,
        scale: 1.6, // 1.6 x 1.3 ~ 2.1
      );
      await _scrollAll(tester, find.byType(CustomScrollView));
    });
  });

  group('Settings', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Settings khong tran o textScale $scale', (tester) async {
        final prefs = PreferencesProvider();
        await _pump(
          tester,
          const SettingsScreen(),
          prefs: prefs,
          scale: scale,
          planner: PlannerProvider(),
          locations: LocationProvider(),
        );
        for (final t in [
          'GIAO DIỆN',
          'ĐƠN VỊ',
          'CHỈ SỐ TRÊN TRANG CHỦ',
          'ĐỊA ĐIỂM',
          'TRỢ NĂNG',
        ]) {
          await tester.scrollUntilVisible(
            find.text(t),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.takeException(), isNull);
        }
        // Muc cua agent tai khoan van con.
        await tester.scrollUntilVisible(
          find.text('Tài khoản và đồng bộ'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await _scrollAll(tester, find.byType(ListView).first);
      });
    }

    testWidgets('man rong 1280: noi dung toi da 640 va can giua', (
      tester,
    ) async {
      await _pump(
        tester,
        const SettingsScreen(),
        prefs: PreferencesProvider(),
        size: const Size(1280, 900),
      );
      final r = tester.getRect(find.byType(Card).first);
      expect(r.width, lessThanOrEqualTo(640));
      expect(r.center.dx, closeTo(640, 1));
    });

    testWidgets('doi don vi gio + nut xuong doi thu tu', (tester) async {
      final prefs = PreferencesProvider();
      await _pump(
        tester,
        const SettingsScreen(),
        prefs: prefs,
        size: const Size(400, 3000),
      );
      await tester.tap(find.text('Cấp Beaufort'));
      await tester.pump();
      expect(prefs.units.wind, WindUnit.beaufort);

      await tester.ensureVisible(find.byTooltip('Đưa Gió xuống'));
      await tester.tap(find.byTooltip('Đưa Gió xuống'));
      await tester.pump();
      final order = prefs.metricOrder;
      expect(
        order.indexOf(HomeMetric.wind),
        order.indexOf(HomeMetric.humidity) + 1,
      );

      // Cham >= 48 dp cho nut len/xuong.
      final size = tester.getSize(find.byTooltip('Đưa Gió lên'));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });
  });
}
