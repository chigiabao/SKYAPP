import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/habits.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/reminders.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/activities_screen.dart';
import 'package:sky_weather_app/screens/alert_settings_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/background_check.dart';
import 'package:sky_weather_app/services/notification_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

/// Thu 2026-10-15 14:10 (gio TP.HCM).
final DateTime _now = DateTime.utc(2026, 10, 15, 14, 10);

DateTime Function() _clockAt(DateTime hcm) =>
    () => HcmTime.toInstant(hcm);

/// Fake CHI dung trong test: ghi lai moi lenh thay vi goi plugin.
class FakeNotifications implements NotificationService {
  FakeNotifications({this.grant = true});

  bool grant;
  int permissionRequests = 0;
  final List<(int, String)> shown = [];
  final List<(int, DateTime, String, String)> scheduled = [];
  int cancels = 0;

  @override
  Future<bool> init() async => true;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return grant;
  }

  @override
  Future<void> show(int id, String title, String body) async =>
      shown.add((id, title));

  @override
  Future<void> schedule(
    int id,
    DateTime atHcm,
    String title,
    String body,
  ) async => scheduled.add((id, atHcm, title, body));

  @override
  Future<void> cancelScheduled() async {
    cancels++;
    scheduled.clear();
  }
}

/// Du lieu gia: 48 gio tu [base]; [storm] = cac gio co dong.
List<HourlyForecast> _hours(DateTime base, {Set<int> storm = const {}}) => [
  for (var i = 0; i < 48; i++)
    HourlyForecast(
      time: HcmTime.startOfHour(base).add(Duration(hours: i)),
      temperature: 27,
      condition: WeatherCondition.cloudy,
      weatherCode: storm.contains(i) ? 95 : 3,
      rainProbability: storm.contains(i) ? 0.95 : 0.05,
      uvIndex: 2,
      windGusts: 15,
      usAqi: 40,
      source: DataSource.forecast,
    ),
];

class _FakeApi extends ApiService {
  _FakeApi({this.storm = const {}});
  final Set<int> storm;

  @override
  Future<WeatherData> fetchWeatherData({DateTime? at}) async {
    final base = HcmTime.startOfHour(at ?? _now);
    return WeatherData(
      current: CurrentWeather(
        locationName: ApiConfig.locationName,
        temperature: 30,
        condition: WeatherCondition.cloudy,
        weatherCode: 3,
        lastUpdated: base,
      ),
      hourlyForecast: _hours(base, storm: storm),
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

const _daily = ActivityRoutine(
  id: 'r1',
  activity: Activity.running,
  placeId: 'a',
  hour: 7,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('lich nhac', () {
    test('gio nhac = gio hoat dong - X phut, qua lan sau neu da lo', () {
      final a = nextReminder(_daily, DateTime.utc(2026, 10, 15, 6, 20), 30)!;
      expect(a.occurrence, DateTime.utc(2026, 10, 15, 7));
      expect(a.fireAt, DateTime.utc(2026, 10, 15, 6, 30));
      // 06:40: da qua gio nhac hom nay -> ngay mai.
      final b = nextReminder(_daily, DateTime.utc(2026, 10, 15, 6, 40), 30)!;
      expect(b.fireAt, DateTime.utc(2026, 10, 16, 6, 30));
    });

    test('qua nua dem: lich 00:15 thu Ba -> nhac 23:45 thu Hai', () {
      const r = ActivityRoutine(
        id: 'n',
        activity: Activity.commute,
        placeId: 'a',
        hour: 0,
        minute: 15,
        weekdays: {DateTime.tuesday},
      );
      // 2026-10-12 la thu Hai.
      final x = nextReminder(r, DateTime.utc(2026, 10, 12, 22), 30)!;
      expect(x.occurrence, DateTime.utc(2026, 10, 13, 0, 15));
      expect(x.fireAt, DateTime.utc(2026, 10, 12, 23, 45));
      // Nhac truoc 2 gio, luc 23:00 -> lan 00:30 dem nay khong kip.
      const d = ActivityRoutine(
        id: 'd',
        activity: Activity.commute,
        placeId: 'a',
        hour: 0,
        minute: 30,
      );
      final y = nextReminder(d, DateTime.utc(2026, 10, 12, 23), 120)!;
      expect(y.occurrence, DateTime.utc(2026, 10, 14, 0, 30));
      expect(y.fireAt, DateTime.utc(2026, 10, 13, 22, 30));
      expect(
        nextReminder(
          const ActivityRoutine(
            id: 'e',
            activity: Activity.commute,
            placeId: 'a',
            hour: 7,
            weekdays: {},
          ),
          _now,
          30,
        ),
        isNull,
      );
    });

    test('len lich 48 gio: id 1..n, sap theo gio, kem diem thoi tiet', () {
      final plan = planReminders(
        [_daily],
        nowHcm: _now,
        minutesBefore: 30,
        quiet: const AlertSettings(quietEnabled: false),
        hoursFor: (id) => _hours(_now),
        placeName: (id) => 'Q1',
      );
      expect(plan.reminders.map((r) => r.fireAt), [
        DateTime.utc(2026, 10, 16, 6, 30),
        DateTime.utc(2026, 10, 17, 6, 30),
      ]);
      expect(plan.reminders.map((r) => r.id), [1, 2]);
      expect(plan.reminders.first.title, 'Chạy bộ lúc 07:00 (còn 30 phút)');
      expect(plan.reminders.first.body, startsWith('Q1 · Thời tiết tốt'));
    });

    test('gio yen lang: nhac tu dat van gui; chi bo khi bat ton trong', () {
      const early = ActivityRoutine(
        id: 'e',
        activity: Activity.running,
        placeId: 'a',
        hour: 5,
      );
      final plan = planReminders(
        [early],
        nowHcm: _now,
        minutesBefore: 30,
        quiet: const AlertSettings(),
        hoursFor: (_) => null,
        respectQuiet: true,
      );
      expect(plan.reminders, isEmpty);
      expect(plan.skippedQuiet, 2);
      final off = planReminders(
        [early],
        nowHcm: _now,
        minutesBefore: 30,
        quiet: const AlertSettings(quietEnabled: false),
        hoursFor: (_) => null,
        respectQuiet: true,
      );
      expect(off.reminders, hasLength(2));
      expect(off.reminders.first.body, 'Chưa có dự báo cho khung giờ này');
    });

    test('thoi tiet xau -> goi y khung thay the', () {
      // _hours tinh tu 14:00 ngay 15: 07:00 ngay 16 la i = 17.
      final hours = _hours(_now, storm: {16, 17, 18});
      final plan = planReminders(
        [_daily],
        nowHcm: _now,
        minutesBefore: 30,
        quiet: const AlertSettings(quietEnabled: false),
        hoursFor: (_) => hours,
      );
      final first = plan.reminders.first;
      expect(WindowRating.of(first.score!.score), WindowRating.poor);
      expect(first.alternative, isNotNull);
      expect(first.alternative!.time.hour, anyOf(9, 10, 4, 5));
      expect(first.body, contains('Gợi ý: '));
    });

    test('NotifySettings doc / ghi an toan', () {
      final s = NotifySettings.fromJson(
        const NotifySettings(system: true, minutesBefore: 60).toJson(),
      );
      expect(s.system, isTrue);
      expect(s.minutesBefore, 60);
      expect(NotifySettings.fromJson({'minutesBefore': -5}).minutesBefore, 30);
    });
  });

  group('thong bao he thong (fake)', () {
    test('xin quyen khi bat; tu choi -> giu tat', () async {
      final fake = FakeNotifications(grant: false);
      final p = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await p.load();
      expect(fake.permissionRequests, 0); // khong xin luc mo
      expect(await p.setSystemNotifications(true), isFalse);
      expect(p.notifySettings.system, isFalse);
      fake.grant = true;
      expect(await p.setSystemNotifications(true), isTrue);
      expect(p.notifySettings.system, isTrue);
    });

    test('gui mot lan (chong trung), khong gui khi xem lai', () async {
      final fake = FakeNotifications();
      final p = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await p.load();
      await p.setSystemNotifications(true);
      final hours = _hours(_now, storm: {2, 3});
      p.record('b', 'Q3', hours, _now, replay: true);
      expect(fake.shown, isEmpty);
      final n = await p.record('a', 'Q1', hours, _now);
      await p.flush();
      expect(n, isNotEmpty);
      expect(fake.shown, hasLength(n.length));
      await p.record('a', 'Q1', hours, _now);
      await p.flush();
      expect(fake.shown, hasLength(n.length));
    });

    test('gio yen lang: muc Canh bao bi giu, khong gui', () async {
      final fake = FakeNotifications();
      final night = DateTime.utc(2026, 10, 15, 23, 10);
      final p = PlannerProvider(notifications: fake, clock: _clockAt(night));
      await p.load();
      await p.setSystemNotifications(true);
      p.record('a', 'Q1', _hours(night, storm: {2}), night);
      await p.flush();
      expect(fake.shown, isEmpty);
      expect(p.heldByQuietHours, greaterThan(0));
    });

    test('them lich -> hen nhac; tat -> huy het', () async {
      final fake = FakeNotifications();
      final p = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await p.load();
      await p.setSystemNotifications(true);
      p.noteLiveHours('a', 'Q1', _hours(_now));
      p.addRoutine(_daily);
      await p.flush();
      expect(fake.scheduled.map((s) => s.$2), [
        DateTime.utc(2026, 10, 16, 6, 30),
        DateTime.utc(2026, 10, 17, 6, 30),
      ]);
      p.setReminderMinutes(60);
      await p.flush();
      expect(fake.scheduled.first.$2, DateTime.utc(2026, 10, 16, 6));
      await p.setSystemNotifications(false);
      await p.flush();
      expect(fake.scheduled, isEmpty);
    });

    test('kiem tra nen: tai du lieu, gui canh bao, bo qua khi tat', () async {
      final fake = FakeNotifications();
      final api = _FakeApi(storm: {2, 3});
      expect(
        await runBackgroundCheck(
          notifications: fake,
          api: api,
          clock: _clockAt(_now),
        ),
        0,
      );
      SharedPreferences.setMockInitialValues({
        PlannerProvider.notifyKey: '{"system":true}',
      });
      final sent = await runBackgroundCheck(
        notifications: fake,
        api: api,
        clock: _clockAt(_now),
      );
      expect(sent, greaterThan(0));
      expect(fake.shown, hasLength(sent));
      // Xem lai -> khong gui.
      SharedPreferences.setMockInitialValues({
        PlannerProvider.notifyKey: '{"system":true}',
        AppSettings.replayEnabledKey: true,
        AppSettings.replayAtKey: '2026-10-10T12:00:00+07:00',
      });
      expect(
        await runBackgroundCheck(notifications: fake, api: api),
        0,
      );
    });
  });

  group('dong bo nen / app (race lich su)', () {
    Future<void> enableSystem() async => SharedPreferences.setMockInitialValues({
      PlannerProvider.notifyKey: '{"system":true}',
    });

    test('hai lan chay nen lien tiep: lan hai gui 0', () async {
      await enableSystem();
      final fake = FakeNotifications();
      final api = _FakeApi(storm: {2, 3});
      final first = await runBackgroundCheck(
        notifications: fake,
        api: api,
        clock: _clockAt(_now),
      );
      expect(first, greaterThan(0));
      final second = await runBackgroundCheck(
        notifications: fake,
        api: api,
        clock: _clockAt(_now),
      );
      expect(second, 0);
      expect(fake.shown, hasLength(first));
    });

    test('app va nen ghi xen ke: khong mat muc, khong bao trung', () async {
      await enableSystem();
      final fake = FakeNotifications();
      final app = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await app.load();
      // App (dang mo) ghi canh bao dong cho 'a'.
      final mine = await app.record('a', 'Q1', _hours(_now, storm: {2}), _now);
      expect(mine, isNotEmpty);
      // Tac vu nen (isolate khac) ghi canh bao cho dia diem mac dinh.
      final bg = await runBackgroundCheck(
        notifications: fake,
        api: _FakeApi(storm: {5, 6}),
        clock: _clockAt(_now),
      );
      expect(bg, greaterThan(0));
      final shownBefore = fake.shown.length;
      // App chua reload: lan record tiep cung du lieu nen -> khong bao lai.
      final again = await app.record(
        Place.defaultId,
        'TSN',
        _hours(_now, storm: {5, 6}),
        _now,
      );
      expect(again, isEmpty);
      expect(fake.shown, hasLength(shownBefore));
      // Khong mat muc cua ben nao (bo nho + da luu).
      final keys = {for (final n in app.history) n.placeId};
      expect(keys, containsAll(['a', Place.defaultId]));
      final reread = PlannerProvider(clock: _clockAt(_now));
      await reread.load();
      expect(reread.history, hasLength(app.history.length));
      // Resume -> gop.
      await app.syncFromDisk();
      expect(app.history, hasLength(reread.history.length));
    });

    test('sau "Xoá lịch sử" khong bao lai canh bao con hieu luc', () async {
      final fake = FakeNotifications();
      final p = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await p.load();
      await p.setSystemNotifications(true);
      final hours = _hours(_now, storm: {2, 3});
      final n = await p.record('a', 'Q1', hours, _now);
      expect(n, isNotEmpty);
      p.clearHistory();
      await p.flush();
      expect(p.history, isEmpty);
      expect(await p.record('a', 'Q1', hours, _now), isEmpty);
      await p.flush();
      expect(fake.shown, hasLength(n.length));
    });

    test('mergeNotices: giu muc cao nhat, read = OR', () {
      AlertNotice mk(AlertLevel l, {bool read = false}) => AlertNotice(
        type: AlertType.rain,
        level: l,
        placeId: 'a',
        placeName: 'Q1',
        start: _now,
        end: _now.add(const Duration(hours: 2)),
        createdAt: _now,
        title: '',
        body: '',
        read: read,
      );
      final m = mergeNotices(
        [mk(AlertLevel.warning, read: true)],
        [mk(AlertLevel.danger)],
      );
      expect(m.single.level, AlertLevel.danger);
      expect(m.single.read, isTrue);
    });
  });

  group('nhac trong gio yen lang', () {
    test('mac dinh van hen nhac 05:30 (gio yen lang 22-06)', () async {
      final fake = FakeNotifications();
      final p = PlannerProvider(notifications: fake, clock: _clockAt(_now));
      await p.load();
      await p.setSystemNotifications(true);
      p.addRoutine(
        const ActivityRoutine(
          id: 'run6',
          activity: Activity.running,
          placeId: 'a',
          hour: 6,
        ),
      );
      await p.flush();
      expect(p.notifySettings.reminderQuiet, isFalse);
      expect(
        fake.scheduled.map((s) => s.$2),
        contains(DateTime.utc(2026, 10, 16, 5, 30)),
      );
      p.setReminderQuiet(true);
      await p.flush();
      expect(fake.scheduled, isEmpty);
      expect(p.reminderPlan.skippedQuiet, greaterThan(0));
    });
  });

  group('thoi quen', () {
    test('chua dong y -> khong ghi; dong y -> gio quen, goi y, xoa', () {
      var h = const HabitData();
      h = h.recordDone(Activity.running, _now).recordOpen(_now);
      expect(h.isEmpty, isTrue);
      h = h.copyWith(enabled: true);
      final six = DateTime.utc(2026, 10, 15, 6, 5);
      for (var i = 0; i < 3; i++) {
        h = h.recordDone(Activity.running, six).recordOpen(six);
      }
      expect(h.habitHours(Activity.running), [6]);
      expect(h.hourBonus(Activity.running)[6], kHabitBonus);
      expect(h.hourBonus(Activity.cycling)[6], kOpenBonus);
      final sg = h.suggestions(const []);
      expect(sg.single.hour, 6);
      expect(sg.single.activity, Activity.running);
      // Da co lich cung gio -> khong goi y; bo qua -> an.
      expect(
        h.suggestions(const [
          ActivityRoutine(
            id: 'x',
            activity: Activity.running,
            placeId: 'a',
            hour: 6,
          ),
        ]),
        isEmpty,
      );
      expect(h.dismiss(sg.single).suggestions(const []), isEmpty);
      final back = HabitData.fromJson(h.toJson());
      expect(back.doneAt(Activity.running, 6), 3);
      expect(back.opens[6], 3);
      final c = h.cleared();
      expect(c.isEmpty, isTrue);
      expect(c.enabled, isTrue);
      expect(h.copyWith(enabled: false).hourBonus(Activity.running), isEmpty);
    });

    test('bestWindows uu tien gio quen va ghi ly do', () {
      final hours = _hours(DateTime.utc(2026, 10, 16, 4));
      final now = DateTime.utc(2026, 10, 16, 4);
      final plain = bestWindows(Activity.running, hours, nowHcm: now);
      expect(plain.first.start.hour, 5);
      final habit = bestWindows(
        Activity.running,
        hours,
        nowHcm: now,
        hourBonus: const {18: kHabitBonus},
      );
      expect(habit.first.start.hour, 18);
      expect(habit.first.reason, endsWith('Hợp giờ quen'));
    });

    test('provider: luu va doc lai, xoa du lieu', () async {
      final p = PlannerProvider(clock: _clockAt(_now));
      await p.load();
      p.recordDone(Activity.running);
      expect(p.habits.isEmpty, isTrue);
      p.setHabitLearning(true);
      p.recordDone(Activity.running);
      p.recordAppOpen();
      await p.flush();
      final q = PlannerProvider();
      await q.load();
      expect(q.habits.enabled, isTrue);
      expect(q.habits.doneAt(Activity.running, 14), 1);
      q.clearHabits();
      await q.flush();
      final r = PlannerProvider();
      await r.load();
      expect(r.habits.isEmpty, isTrue);
    });
  });

  group('man hinh', () {
    Future<WeatherProvider> wp() async {
      final p = WeatherProvider(
        apiService: _FakeApi(),
        initialSettings: const AppSettings(),
        clock: _clockAt(_now),
      );
      await p.fetchWeatherData();
      return p;
    }

    Future<void> pump(
      WidgetTester tester,
      WeatherProvider w,
      PlannerProvider planner,
      Widget home,
    ) async {
      tester.view.physicalSize = const Size(390, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<WeatherProvider>.value(value: w),
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

    testWidgets('cai dat thong bao he thong: xin quyen, chon X phut', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final fake = FakeNotifications(grant: false);
      final planner = PlannerProvider(
        notifications: fake,
        clock: _clockAt(_now),
      );
      await pump(tester, await wp(), planner, const AlertSettingsScreen());
      expect(find.text('THÔNG BÁO HỆ THỐNG'), findsOneWidget);
      expect(find.text('Nhắc trước'), findsNothing);
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Thông báo trên điện thoại',
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(fake.permissionRequests, 1);
      expect(planner.notifySettings.system, isFalse);
      expect(find.textContaining('Chưa được cấp quyền'), findsOneWidget);

      fake.grant = true;
      await tester.tap(toggle);
      await tester.pump();
      expect(planner.notifySettings.system, isTrue);
      expect(find.text('Nhắc trước'), findsOneWidget);
      await tester.tap(find.text('1 giờ'));
      await tester.pump();
      expect(planner.notifySettings.minutesBefore, 60);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Nhắc trước giờ hoạt động'),
      );
      await tester.pump();
      expect(planner.notifySettings.reminders, isFalse);
      expect(find.text('Nhắc trước'), findsNothing);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('hoc thoi quen: dong y, da lam, xac nhan goi y, xoa', (
      tester,
    ) async {
      final planner = PlannerProvider(clock: _clockAt(_now));
      await pump(
        tester,
        await wp(),
        planner,
        const ActivitiesScreen(placeName: 'Q1'),
      );
      expect(find.text('HỌC THÓI QUEN'), findsOneWidget);
      expect(find.text('Đã làm'), findsNothing);
      expect(find.text('Xóa dữ liệu thói quen'), findsNothing);
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Cho phép học thói quen'),
      );
      await tester.pump();
      expect(find.text('Đã làm'), findsWidgets);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Đã làm').first);
        await tester.pump();
      }
      expect(planner.habits.doneAt(Activity.running, 14), 3);
      expect(find.textContaining('Gợi ý lịch: Chạy bộ lúc 14:00'), findsOneWidget);
      await tester.tap(find.text('Xác nhận'));
      await tester.pump();
      expect(planner.routines.single.hour, 14);
      expect(find.textContaining('Gợi ý lịch'), findsNothing);

      await tester.tap(find.text('Xóa dữ liệu thói quen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
      await tester.pumpAndSettle();
      expect(planner.habits.doneAt(Activity.running, 14), 0);
      expect(planner.habits.enabled, isTrue);
      expect(planner.routines, hasLength(1));
    });
  });
}
