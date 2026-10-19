import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/onboarding_screen.dart';
import 'package:sky_weather_app/services/notification_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

/// Gio TP.HCM 05:00 ngay 20/10/2026 (dong ho UTC + 7).
final DateTime _instant = DateTime.utc(2026, 10, 19, 22);
final DateTime _day = DateTime.utc(2026, 10, 20);

/// Du lieu gia CHI dung trong test: mua 15h-18h, con lai kho.
List<HourlyForecast> _hours({Set<int> rain = const {15, 16, 17}}) => [
  for (var i = 0; i < 48; i++)
    HourlyForecast(
      time: _day.add(Duration(hours: i)),
      temperature: 29,
      condition: WeatherCondition.cloudy,
      weatherCode: 3,
      rainProbability: rain.contains(i % 24) ? 0.7 : 0.1,
      source: DataSource.forecast,
    ),
];

class _Notify implements NotificationService {
  final scheduled = <(int, DateTime, String, String)>[];

  @override
  Future<bool> init() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show(int id, String title, String body) async {}
  @override
  Future<void> schedule(int id, DateTime at, String title, String body) async =>
      scheduled.add((id, at, title, body));
  @override
  Future<void> cancelScheduled() async => scheduled.clear();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nguoi dung moi: di lam / di hoc bat san', () {
    expect(kDefaultFavorites.first, Activity.commute);
    expect(PlannerProvider().favorites, contains(Activity.commute));
  });

  test('dong di / ve: "Về 17h30: mưa 70% – mang áo mưa"', () {
    final now = _day.add(const Duration(hours: 9));
    final back = commuteLine('Về', 17, 30, _hours(), now)!;
    expect(back.text, 'Về 17h30: mưa 70% – mang áo mưa');
    expect(back.bad, isTrue);
    // 7h30 da qua (9h) -> ngay mai, van co du lieu.
    final go = commuteLine('Đi', 7, 30, _hours(), now)!;
    expect(go.text, startsWith('Đi mai 7h30: ít mưa (10%)'));
    expect(commuteLine('Đi', 7, 30, const [], now), isNull);
  });

  test('tom tat buoi sang theo Nha / Noi lam', () {
    const c = CommuteSettings();
    expect(
      morningBrief([(name: 'Bến Thành', hours: _hours())], _day, c),
      'Hôm nay: mưa 15–18h ở Bến Thành, mang áo mưa khi về.',
    );
    expect(
      morningBrief([(name: 'Nhà', hours: _hours(rain: {}))], _day, c),
      'Hôm nay: không có mưa đáng kể ở Nhà.',
    );
    expect(morningBrief([(name: 'Nhà', hours: null)], _day, c), isNull);
  });

  test('CommuteSettings doc / ghi JSON, mac dinh 7:30 / 17:30 / 6:30', () {
    const d = CommuteSettings();
    expect((d.leaveHour, d.leaveMinute), (7, 30));
    expect((d.returnHour, d.returnMinute), (17, 30));
    expect((d.briefHour, d.briefMinute), (6, 30));
    final c = d.copyWith(homeId: 'a', briefEnabled: true, leaveHour: 6);
    final r = CommuteSettings.fromJson(c.toJson());
    expect((r.homeId, r.briefEnabled, r.leaveHour), ('a', true, 6));
    expect(CommuteSettings.fromJson({'leaveHour': 99}).leaveHour, 7);
  });

  test('thong bao buoi sang: hen 6:30 gio HCM, noi dung tu du lieu moi', () async {
    final n = _Notify();
    final p = PlannerProvider(notifications: n, clock: () => _instant);
    await p.load();
    p.setCommute(const CommuteSettings(workId: 'q1'));
    expect(await p.setMorningBrief(true), isTrue);
    p.noteLiveHours('q1', 'Bến Thành', _hours());
    await p.rescheduleReminders();
    final brief = n.scheduled.where(
      (s) => s.$1 == PlannerProvider.morningBriefId,
    );
    expect(brief, hasLength(1));
    expect(brief.single.$2, _day.add(const Duration(hours: 6, minutes: 30)));
    expect(brief.single.$4, contains('mưa 15–18h ở Bến Thành'));

    // Gio yen lang 22h-7h, nguoi dung khong cho gui trong gio yen lang.
    p.setSettings(p.settings.copyWith(quietEnd: 7));
    p.setCommute(p.commute.copyWith(briefInQuiet: false));
    await p.rescheduleReminders();
    expect(p.morningBriefAt, isNull);
    expect(n.scheduled.where((s) => s.$1 == PlannerProvider.morningBriefId),
        isEmpty);
  });

  group('Onboarding', () {
    Future<void> pump(WidgetTester tester, {double scale = 1}) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => PlannerProvider()),
            ChangeNotifierProvider(create: (_) => LocationProvider()),
            ChangeNotifierProvider(create: (_) => WeatherProvider()),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
              ),
              child: AppSceneScope(child: child!),
            ),
            home: const OnboardingGate(child: Text('HOME')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('3 buoc, khong tran o 360x740 textScale $scale', (
        tester,
      ) async {
        await pump(tester, scale: scale);
        expect(find.text('Bạn đi lại giữa đâu?'), findsOneWidget);
        await tester.tap(find.text('Tiếp tục'));
        await tester.pump();
        expect(find.text('Mấy giờ bạn đi và về?'), findsOneWidget);
        expect(find.text('7h30'), findsOneWidget);
        expect(find.text('17h30'), findsOneWidget);
        await tester.tap(find.text('Tiếp tục'));
        await tester.pump();
        expect(find.text('Biết mưa trước khi ra đường'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Bắt đầu dùng'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Biết mưa trước khi ra đường'), findsNothing);
        final p = await SharedPreferences.getInstance();
        expect(p.getBool(OnboardingGate.doneKey), isTrue);
      });
    }

    testWidgets('bo qua -> chi hien mot lan', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Bỏ qua'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Bạn đi lại giữa đâu?'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.text('Bạn đi lại giữa đâu?'), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
    });
  });
}
