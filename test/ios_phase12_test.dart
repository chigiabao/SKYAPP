// iOS giai doan 1 (nen tang) + 2 (loi UX nghiem trong). Du lieu gia CHI
// dung trong test, khong goi mang.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/trip_provider.dart';
import 'package:sky_weather_app/screens/compare_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/services/trip_location.dart';
import 'package:sky_weather_app/services/trip_notifier.dart';
import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/ui/weather/widgets/adaptive_dialog.dart';
import 'package:sky_weather_app/ui/weather/widgets/app_segmented_control.dart';
import 'package:sky_weather_app/ui/weather/widgets/bottom_pill_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/collapsing_header.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_overview.dart';
import 'package:sky_weather_app/utils/theme.dart';

import 'support/fake_weather_repository.dart';

/// 21:00 21/10/2026 (gio TP.HCM) - moc xem lai mau.
final _now = DateTime.utc(2026, 10, 21, 21);

HourlyForecast _hour(
  DateTime t, {
  double? uv,
  double? mm,
  double? prob,
  DataSource source = DataSource.observed,
}) => HourlyForecast(
  time: t,
  temperature: 27,
  condition: WeatherCondition.cloudy,
  uvIndex: uv,
  precipitationMm: mm,
  rainProbability: prob ?? (source == DataSource.observed ? 0 : null),
  source: source,
);

class _HourlyRepo extends FakeWeatherRepository {
  _HourlyRepo(this.response)
    : super(
        onNearest: (_, _) async => const Place(
          id: 'tsn',
          name: 'Tân Sơn Nhất',
          kind: PlaceKind.phuong,
          lat: 10.8,
          lon: 106.66,
        ),
      );

  final Future<List<dynamic>> Function(DateTime? at) response;
  final List<DateTime?> hourlyAt = [];

  @override
  Future<List<dynamic>> fetchHourlyRaw({
    int hours = ApiConfig.hourlyHours,
    DateTime? at,
    String? locationId,
  }) {
    hourlyAt.add(at);
    return response(at);
  }
}

class _Location implements TripLocationSource {
  @override
  Future<GpsStatus> ensurePermission() async => GpsStatus.ok;

  @override
  Stream<LatLng> watch({required bool background}) =>
      const Stream<LatLng>.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Phase 1: iOS foundations', () {
    test('one font family everywhere, incl. every Cupertino style', () {
      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        // Ngon ngu thiet ke iOS tren moi nen tang (ca web/Android).
        expect(theme.platform, TargetPlatform.iOS);
        expect(theme.textTheme.bodyMedium!.fontFamily, TypeScale.family);
        final c = theme.cupertinoOverrideTheme!.textTheme!;
        // Goc loi chu "hep": mac dinh Flutter la 'CupertinoSystemText' +
        // letterSpacing -0.41, khong co tren web.
        for (final style in [
          c.textStyle,
          c.actionTextStyle,
          c.actionSmallTextStyle,
          c.navTitleTextStyle,
          c.navActionTextStyle,
          c.tabLabelTextStyle,
        ]) {
          expect(style.fontFamily, TypeScale.family);
          expect(style.letterSpacing ?? 0, greaterThanOrEqualTo(0));
        }
        expect(c.navLargeTitleTextStyle.fontFamily, TypeScale.displayFamily);
        for (final p in TargetPlatform.values) {
          expect(
            theme.pageTransitionsTheme.builders[p],
            isA<CupertinoPageTransitionsBuilder>(),
          );
        }
      }
      // Ngoai thiet bi Apple: Inter (dong goi, du dau tieng Viet).
      expect(TypeScale.family, 'Inter');
    });

    test('iOS type scale tokens', () {
      expect(TypeScale.largeTitle.fontSize, 34);
      expect(TypeScale.title1.fontSize, 28);
      expect(TypeScale.title2.fontSize, 22);
      expect(TypeScale.title3.fontSize, 20);
      expect(TypeScale.headline.fontSize, 17);
      expect(TypeScale.headline.fontWeight, FontWeight.w600);
      expect(TypeScale.iosBody.fontSize, 17);
      expect(TypeScale.callout.fontSize, 16);
      expect(TypeScale.subhead.fontSize, 15);
      expect(TypeScale.footnote.fontSize, 13);
      expect(TypeScale.caption1.fontSize, 12);
      expect(TypeScale.tabLabel.fontSize, 11);
    });

    testWidgets('scroll content reserves tab bar + home indicator', (
      tester,
    ) async {
      late double reserved;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(bottom: 34),
          ),
          child: Builder(
            builder: (context) {
              reserved = BottomPillBar.reservedHeight(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        reserved,
        BottomPillBar.heightFor(390, TextScaler.noScaling) + 34 + Space.l,
      );
      expect(reserved, greaterThanOrEqualTo(50 + 34));
    });

    testWidgets('segmented control: selection haptic, no-op on same value', (
      tester,
    ) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var value = 'b';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => AppSegmentedControl<String>(
                segments: const [
                  AppSegment(value: 'a', label: 'Ít'),
                  AppSegment(value: 'b', label: 'Vừa'),
                  AppSegment(value: 'c', label: 'Nhiều'),
                ],
                selected: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byType(CupertinoSlidingSegmentedControl<String>),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.text('Nhiều')).height,
        lessThan(
          tester.getSize(find.byType(AppSegmentedControl<String>)).height,
        ),
      );
      expect(
        tester.getSize(find.byType(AppSegmentedControl<String>)).height,
        greaterThanOrEqualTo(Touch.min),
      );
      await tester.tap(find.text('Nhiều'));
      await tester.pumpAndSettle();
      expect(value, 'c');
      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('adaptive alert is a CupertinoAlertDialog returning value', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async => result = await showAppAlert<bool>(
                context,
                title: 'Xóa?',
                message: 'Không hoàn tác được.',
                actions: const [
                  AppDialogAction(label: 'Hủy', value: false, isDefault: true),
                  AppDialogAction(
                    label: 'Xóa',
                    value: true,
                    isDestructive: true,
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.tap(find.text('Xóa'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('action sheet offers move up / move down without dragging', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async => picked = await showAppActionSheet<String>(
                context,
                actions: const [
                  AppDialogAction(label: 'Di chuyển lên', value: 'up'),
                  AppDialogAction(label: 'Di chuyển xuống', value: 'down'),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      await tester.tap(find.text('Di chuyển xuống'));
      await tester.pumpAndSettle();
      expect(picked, 'down');
    });
  });

  group('Phase 2.1: alert time state (fake clock 21:00)', () {
    // Che do xem lai: gio SAU 21:00 cung la "thuc te" (so lieu phan tich).
    final hours = [
      for (var i = 0; i < 24; i++)
        _hour(
          _now.add(Duration(hours: i)),
          // Mua 21:00-22:00 (dang xay ra) va 18:00-19:00 ngay mai.
          mm: i == 0 || i == 21 ? 1.0 : 0,
          // UV 12:00-14:00 ngay mai.
          uv: i == 15 || i == 16 ? 8.4 : 0,
        ),
    ];

    test('ongoing only when now is inside the window; else upcoming', () {
      final events = evaluateAlerts(hours, nowHcm: _now, placeId: 'p');
      final uv = events.firstWhere((e) => e.type == AlertType.uv);
      expect(uv.timing, AlertTiming.upcoming);
      expect(uv.title, contains('Ngày mai 12:00'));
      // Xem lai: gio sau moc xem lai la so lieu da ghi nhan -> doc la
      // "Đã xảy ra", khong phai "Sắp tới" (thu tu / timing giu nguyen).
      expect(uv.detail, contains('Đã xảy ra (theo số liệu đã ghi nhận)'));
      expect(uv.detail, isNot(contains('Sắp tới')));
      expect(uv.detail, isNot(contains('Đang xảy ra')));
      // Du bao that su van la "Sắp tới (dự báo)".
      final fc = AlertEvent(
        type: AlertType.uv,
        level: AlertLevel.advisory,
        placeId: 'p',
        start: uv.start,
        end: uv.end,
        peak: 8.4,
        observed: false,
        asOf: _now,
      );
      expect(fc.timing, AlertTiming.upcoming);
      expect(fc.detail, contains('Sắp tới (dự báo)'));

      final rain = events.where((e) => e.type == AlertType.rain).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      expect(rain, hasLength(2));
      expect(rain.first.timing, AlertTiming.ongoing);
      expect(rain.first.detail, contains('Đang xảy ra'));
      expect(rain.first.title, isNot(contains('Mai')));
      expect(rain.last.timing, AlertTiming.upcoming);
      expect(rain.last.title, contains('Ngày mai 18:00'));
    });

    test('past windows are "Đã qua" and never listed as active', () {
      final events = evaluateAlerts(hours, nowHcm: _now, placeId: 'p');
      final rainNow = events.firstWhere(
        (e) => e.type == AlertType.rain && e.start == _now,
      );
      final later = _now.add(const Duration(hours: 2));
      expect(rainNow.timingAt(later), AlertTiming.past);
      expect(AlertTiming.past.label, 'Đã qua');
      // Danh gia lai luc 23:00: canh bao 21:00-22:00 bien mat.
      final again = evaluateAlerts(hours, nowHcm: later, placeId: 'p');
      expect(
        again.where((e) => e.type == AlertType.rain && e.start == _now),
        isEmpty,
      );
      expect(again.every((e) => e.timingAt(later) != AlertTiming.past), isTrue);
    });

    test('boundaries: start inclusive, end exclusive', () {
      final e = AlertEvent(
        type: AlertType.rain,
        level: AlertLevel.advisory,
        placeId: 'p',
        start: _now,
        end: _now.add(const Duration(hours: 1)),
        peak: 1,
        observed: false,
      );
      expect(
        e.timingAt(_now.subtract(const Duration(minutes: 1))),
        AlertTiming.upcoming,
      );
      expect(e.timingAt(_now), AlertTiming.ongoing);
      expect(
        e.timingAt(_now.add(const Duration(minutes: 59))),
        AlertTiming.ongoing,
      );
      expect(e.timingAt(_now.add(const Duration(hours: 1))), AlertTiming.past);
    });
  });

  group('Phase 2.3: stale hero', () {
    Future<void> pump(WidgetTester tester, WeatherHeaderInfo info) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HomeWeatherOverview(info: info, onTrip: () {}),
              ),
            ),
          ),
        );

    testWidgets('old data dims the number and shows its time', (tester) async {
      await pump(
        tester,
        const WeatherHeaderInfo(
          city: 'Tân Sơn Nhất',
          detail: 'Nhà',
          temperature: '31°',
          condition: 'Mưa phùn',
          updated: 'Cập nhật 27/10 15:00',
          isStale: true,
          staleAt: 'Lúc 15:00 27/10',
        ),
      );
      expect(find.text('Lúc 15:00 27/10'), findsOneWidget);
      expect(find.text('Dữ liệu cũ'), findsOneWidget);
      final hero = tester.widget<Text>(
        find.byKey(const ValueKey('hero-temperature')),
      );
      expect(hero.style!.color!.a, closeTo(Opacities.staleHero, 0.01));
      // Ngay duoi so lon.
      expect(
        tester.getTopLeft(find.text('Lúc 15:00 27/10')).dy,
        greaterThan(
          tester
                  .getBottomLeft(find.byKey(const ValueKey('hero-temperature')))
                  .dy -
              1,
        ),
      );
    });

    testWidgets('fresh data keeps the full-strength number', (tester) async {
      await pump(
        tester,
        const WeatherHeaderInfo(
          city: 'Tân Sơn Nhất',
          detail: 'Nhà',
          temperature: '27°',
          condition: 'Mưa phùn',
        ),
      );
      expect(find.byKey(const ValueKey('hero-stale-at')), findsNothing);
      final hero = tester.widget<Text>(
        find.byKey(const ValueKey('hero-temperature')),
      );
      expect(hero.style!.color!.a, 1);
    });
  });

  group('Phase 2.4: compare rain is consistent', () {
    const units = UnitPrefs();

    test('observed (replay) hours: column and verdict agree', () {
      final obs = [
        for (var i = 0; i < 4; i++)
          _hour(_now.add(Duration(hours: i)), mm: i == 0 ? 0.5 : 0),
      ];
      final r = compareRain3h(obs, _now, units);
      expect(r.value, 'Có mưa');
      expect(r.note, startsWith('đã ghi nhận'));
      expect(r.note, isNot(contains('thực tế')));
      expect(rainOnset(obs, _now), _now);
      // Gio thuc te kho -> "Không mưa", khong phai "--".
      final dry = [
        for (var i = 0; i < 4; i++) _hour(_now.add(Duration(hours: i)), mm: 0),
      ];
      expect(compareRain3h(dry, _now, units).value, 'Không mưa');
      expect(rainOnset(dry, _now), isNull);
    });

    test('forecast hours give a probability; no hours explain why', () {
      final fc = [
        for (var i = 0; i < 3; i++)
          _hour(
            _now.add(Duration(hours: i)),
            prob: 0.3 + i * 0.1,
            source: DataSource.ai,
          ),
      ];
      expect(compareRain3h(fc, _now, units).value, '50%');
      final none = compareRain3h(const [], _now, units);
      expect(none.value, 'Chưa có');
      expect(none.note, 'chưa có số liệu theo giờ');
    });
  });

  group('Phase 2.6: trip nowcast in replay', () {
    TripProvider trip(_HourlyRepo repo) => TripProvider(
      api: repo,
      location: _Location(),
      notifier: const NoopTripNotifier(),
      clock: () => DateTime.utc(2026, 10, 31, 14),
      tickEvery: null,
    );

    test('replay fetches the replay hour, not the live one', () async {
      final repo = _HourlyRepo(
        (at) async => [
          for (var i = 0; i < 3; i++)
            {
              'timestamp': HcmTime.toIso(_now.add(Duration(hours: i))),
              'temperature': 27,
              'weather_code': 61,
              'precipitation': 0.4,
              'source': 'observed',
            },
        ],
      );
      final t = trip(repo);
      addTearDown(t.dispose);
      await t.loadNowcast(10.8, 106.66, at: _now);
      expect(repo.hourlyAt, [_now]);
      expect(t.nowcastError, isNull);
      expect(t.nowcastHours, hasLength(3));
    });

    test('503 explains the real reason instead of "server error"', () async {
      final repo = _HourlyRepo(
        (_) => Future.error(
          ApiException(
            ApiErrorKind.server,
            statusCode: 503,
            detail: 'Không đủ dữ liệu đầu vào',
          ),
        ),
      );
      final t = trip(repo);
      addTearDown(t.dispose);
      await t.loadNowcast(10.8, 106.66, at: _now);
      expect(t.nowcastError, startsWith('Chế độ xem lại'));
      expect(t.nowcastError, isNot(contains('Máy chủ đang gặp lỗi')));
      await t.loadNowcast(10.8, 106.66);
      expect(t.nowcastError, contains('AI của nhóm chưa có dự báo 2 giờ tới'));
    });
  });
}
