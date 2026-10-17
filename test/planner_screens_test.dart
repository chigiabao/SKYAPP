import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/activities_screen.dart';
import 'package:sky_weather_app/screens/alert_settings_screen.dart';
import 'package:sky_weather_app/screens/alerts_screen.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/planner_cards.dart';

final DateTime _now = DateTime.utc(2026, 10, 15, 14, 10);

/// Du lieu gia CHI dung trong test: dong 16:00-18:00, UV cao 14:00, con lai
/// kho rao, mat.
class _FakeApi extends ApiService {
  _FakeApi(this.nowHcm, {this.storm = true});

  final DateTime nowHcm;
  final bool storm;

  @override
  Future<WeatherData> fetchWeatherData({DateTime? at}) async {
    final base = HcmTime.startOfHour(at ?? nowHcm);
    return WeatherData(
      current: CurrentWeather(
        locationName: ApiConfig.locationName,
        temperature: 30,
        condition: WeatherCondition.cloudy,
        weatherCode: 3,
        lastUpdated: base,
      ),
      hourlyForecast: [
        for (var i = 0; i < 48; i++)
          HourlyForecast(
            time: base.add(Duration(hours: i)),
            temperature: 27,
            condition: WeatherCondition.cloudy,
            weatherCode: storm && (i == 2 || i == 3) ? 95 : 3,
            rainProbability: storm && (i == 2 || i == 3) ? 0.9 : 0.05,
            uvIndex: i == 0 ? 6 : 2,
            windGusts: 15,
            usAqi: 40,
            source: DataSource.forecast,
          ),
      ],
      dailyForecast: [
        DailyForecast(
          date: HcmTime.startOfDay(base),
          tempMin: 25,
          tempMax: 31,
          condition: WeatherCondition.cloudy,
          precipitationMm: 2,
        ),
      ],
    );
  }
}

DateTime Function() _clockAt(DateTime hcm) =>
    () => HcmTime.toInstant(hcm);

Future<WeatherProvider> _wp({bool storm = true, DateTime? replay}) async {
  final p = WeatherProvider(
    apiService: _FakeApi(_now, storm: storm),
    initialSettings: AppSettings(
      replayEnabled: replay != null,
      replayAt: replay,
    ),
    clock: _clockAt(_now),
  );
  await p.fetchWeatherData();
  return p;
}

Future<void> _pump(
  WidgetTester tester,
  WeatherProvider wp,
  PlannerProvider planner,
  Widget home, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: wp),
        ChangeNotifierProvider<PlannerProvider>.value(value: planner),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: AppSceneScope(child: child!),
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PlannerProvider', () {
    test('ghi thong bao mot lan; xem lai khong ghi lich su', () async {
      final wp = await _wp();
      final p = PlannerProvider();
      await p.load();
      final first = await p.record('a', 'Q1', wp.hourlyForecast, wp.nowHcm);
      expect(first.map((n) => n.type), contains(AlertType.thunderstorm));
      expect(p.unreadCount, first.length);
      // Danh gia lai cung du lieu -> khong lap.
      expect(await p.record('a', 'Q1', wp.hourlyForecast, wp.nowHcm), isEmpty);
      final r = PlannerProvider();
      await r.load(); // doc lai lich su da luu
      expect(r.history, hasLength(first.length));
      final replay = PlannerProvider();
      expect(
        await replay.record(
          'b',
          'Q3',
          wp.hourlyForecast,
          wp.nowHcm,
          replay: true,
        ),
        isEmpty,
      );
      expect(replay.alertsByPlace['b'], isNotEmpty);
    });

    test('yeu thich + lich luu va doc lai', () async {
      final p = PlannerProvider();
      await p.load();
      p.toggleFavorite(Activity.photography);
      p.addRoutine(
        const ActivityRoutine(
          id: 'x',
          activity: Activity.commute,
          placeId: 'a',
          hour: 7,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final q = PlannerProvider();
      await q.load();
      expect(q.isFavorite(Activity.photography), isTrue);
      expect(q.routines.single.id, 'x');
    });
  });

  group('Home', () {
    testWidgets('banner canh bao + the goi y; mo man Canh bao', (tester) async {
      final wp = await _wp();
      final planner = PlannerProvider();
      await _pump(tester, wp, planner, const HomeScreen());
      expect(find.byType(AlertsSummaryBanner), findsOneWidget);
      expect(find.textContaining('Dông · 16:00'), findsOneWidget);
      expect(find.byTooltip('Đóng cảnh báo'), findsOneWidget);
      // Danh gia luc tai -> co thong bao chua doc o nut header.
      expect(
        find.byTooltip(RegExp(r'^Cảnh báo, \d+ thông báo mới$')),
        findsOneWidget,
      );

      await tester.tap(find.byType(AlertsSummaryBanner).first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertsScreen), findsOneWidget);
      expect(find.text(kAlertDisclaimer), findsOneWidget);
      expect(planner.unreadCount, 0);
    });

    testWidgets('dong banner', (tester) async {
      final wp = await _wp();
      await _pump(tester, wp, PlannerProvider(), const HomeScreen());
      await tester.tap(find.byTooltip('Đóng cảnh báo'));
      await tester.pump();
      expect(find.byType(AlertsSummaryBanner), findsNothing);
    });

    testWidgets('khong co canh bao -> khong banner; co the goi y', (
      tester,
    ) async {
      final wp = await _wp(storm: false);
      final planner = PlannerProvider();
      // Tat UV de khong co canh bao nao.
      planner.setSettings(
        const AlertSettings().withEnabled(AlertType.uv, false),
      );
      await _pump(
        tester,
        wp,
        planner,
        const HomeScreen(),
        size: const Size(390, 4000),
      );
      expect(find.byType(AlertsSummaryBanner), findsNothing);
      expect(find.text('GỢI Ý HOẠT ĐỘNG'), findsOneWidget);
      expect(find.textContaining('Chạy bộ ·'), findsOneWidget);
    });
  });

  testWidgets('man Canh bao: theo dia diem, lich su, nut >= 48 dp', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final wp = await _wp();
    final planner = PlannerProvider();
    await _pump(
      tester,
      wp,
      planner,
      AlertsScreen(locations: LocationProvider()),
      size: const Size(390, 2400),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Dông · 16:00'), findsOneWidget);
    expect(find.text('LỊCH SỬ THÔNG BÁO'), findsOneWidget);
    expect(find.textContaining('Cảnh báo dông'), findsWidgets);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('man Canh bao (xem lai): tinh theo gio xem lai, khong ghi', (
    tester,
  ) async {
    final wp = await _wp(replay: DateTime.utc(2025, 6, 1, 14));
    expect(wp.isReplay, isTrue);
    final planner = PlannerProvider();
    await _pump(
      tester,
      wp,
      planner,
      AlertsScreen(locations: LocationProvider()),
      size: const Size(390, 2400),
    );
    await tester.pumpAndSettle();
    expect(find.text('CHẾ ĐỘ XEM LẠI'), findsOneWidget);
    expect(find.textContaining('Dông · 16:00'), findsOneWidget);
    expect(planner.history, isEmpty);
  });

  testWidgets('cai dat canh bao: tat mot loai, doi muc uu tien', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final planner = PlannerProvider();
    final wp = await _wp();
    await _pump(
      tester,
      wp,
      planner,
      const AlertSettingsScreen(),
      size: const Size(390, 3000),
    );
    expect(find.text('Dông'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'UV cao'));
    await tester.pump();
    expect(planner.settings.isEnabled(AlertType.uv), isFalse);
    await tester.tap(find.text('Nguy hiểm'));
    await tester.pump();
    expect(planner.settings.minNotifyLevel, AlertLevel.danger);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('man Hoat dong: chon yeu thich, khung gio, them lich', (
    tester,
  ) async {
    final planner = PlannerProvider();
    final wp = await _wp();
    await _pump(
      tester,
      wp,
      planner,
      const ActivitiesScreen(placeName: 'Q1'),
      size: const Size(390, 4000),
    );
    expect(find.text('CHẠY BỘ'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Tưới cây'));
    await tester.pump();
    expect(planner.isFavorite(Activity.watering), isTrue);
    expect(find.text('TƯỚI CÂY'), findsOneWidget);

    await tester.tap(find.text('Thêm lịch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(planner.routines, hasLength(1));
    expect(find.textContaining('Đi làm / đi học · 07:00'), findsOneWidget);
    await tester.tap(find.byTooltip('Xóa lịch Đi làm / đi học'));
    await tester.pump();
    expect(planner.routines, isEmpty);
  });
}
