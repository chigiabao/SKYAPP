import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/sun_times.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/ui/weather/widgets/aqi_card.dart';
import 'package:sky_weather_app/ui/weather/widgets/collapsing_header.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';
import 'package:sky_weather_app/ui/weather/widgets/hourly_strip.dart';
import 'package:sky_weather_app/ui/weather/widgets/metric_tile.dart';
import 'package:sky_weather_app/ui/weather/widgets/temp_range_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/uv_card.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/ai_forecast_card.dart';
import 'package:sky_weather_app/widgets/source_badge.dart';

/// Gio TP.HCM -> thoi diem that (cho tham so `clock` cua provider).
DateTime Function() _clockAt(DateTime hcm) =>
    () => HcmTime.toInstant(hcm);

/// Du lieu gia CHI dung trong test (khong goi mang).
class _FakeApi extends ApiService {
  _FakeApi(
    this.nowHcm, {
    this.code = 3,
    this.uv,
    this.aqi,
    this.hourProb = 0.4,
  });

  final double hourProb;

  final DateTime nowHcm;
  final int code;
  final double? uv;
  final int? aqi;
  @override
  Future<WeatherData> fetchWeatherData({DateTime? at}) async {
    final base = HcmTime.startOfHour(nowHcm);
    final today = HcmTime.startOfDay(nowHcm);
    return WeatherData(
      current: CurrentWeather(
        locationName: ApiConfig.locationName,
        temperature: 26.2,
        feelsLike: 32.6,
        condition: conditionFromWmo(code),
        weatherCode: code,
        lastUpdated: base,
        humidity: 93,
        windSpeed: 11.8,
        windGusts: 27.6,
        windDirection: 135,
        cloudCover: 91,
        precipitationMm: 0.4,
        pressure: 1011.3,
        visibilityKm: 16.96,
        uvIndex: uv,
        usAqi: aqi,
        pm25: aqi == null ? null : 20.4,
      ),
      hourlyForecast: [
        for (var i = 0; i < 24; i++)
          HourlyForecast(
            time: base.add(Duration(hours: i)),
            temperature: 25.7,
            condition: WeatherCondition.rainy,
            weatherCode: 61,
            rainProbability: hourProb,
            source: DataSource.forecast,
          ),
      ],
      dailyForecast: [
        for (var i = 0; i < 7; i++)
          DailyForecast(
            date: today.add(Duration(days: i)),
            tempMin: 24 + i * 0.3,
            tempMax: 30.4 + i * 0.2,
            condition: WeatherCondition.showers,
            weatherCode: 80,
            precipitationMm: 3,
            rainDayProbability: 0.6,
            source: DataSource.forecast,
          ),
      ],
      aiForecast: AIForecast(
        issuedAt: base,
        modelVersion: 'lgbm-test',
        predictions: [
          AIPrediction(
            timeLabel: '1h',
            temperature: 26,
            rainProbability: 0.11,
            targetTime: base.add(const Duration(hours: 1)),
          ),
        ],
      ),
    );
  }
}

Future<WeatherProvider> _provider(
  DateTime nowHcm, {
  int code = 3,
  double? uv,
  int? aqi,
  double hourProb = 0.4,
}) async {
  final p = WeatherProvider(
    apiService: _FakeApi(
      nowHcm,
      code: code,
      uv: uv,
      aqi: aqi,
      hourProb: hourProb,
    ),
    initialSettings: const AppSettings(),
    clock: _clockAt(nowHcm),
  );
  await p.fetchWeatherData();
  return p;
}

final DateTime _afternoon = DateTime.utc(2026, 10, 15, 14);

Future<(WeatherProvider, SceneOverride)> _pumpHome(
  WidgetTester tester, {
  Size size = const Size(360, 740),
  double scale = 1.0,
  bool reduceMotion = true,
  int code = 3,
  double hourProb = 0.4,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final provider = await _provider(_afternoon, code: code, hourProb: hourProb);
  final o = SceneOverride();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: provider),
        ChangeNotifierProvider<SceneOverride>.value(value: o),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: AppSceneScope(child: child!),
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return (provider, o);
}

WeatherScene _homeScene(WidgetTester tester) => tester
    .widget<WeatherBackground>(find.byType(WeatherBackground).first)
    .scene;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TempRangeGeometry', () {
    test('min / max / cham hien tai', () {
      const g = TempRangeGeometry(
        scaleMin: 20,
        scaleMax: 30,
        low: 22,
        high: 28,
        current: 25,
      );
      expect(g.start, closeTo(0.2, 1e-9));
      expect(g.end, closeTo(0.8, 1e-9));
      expect(g.dot, closeTo(0.5, 1e-9));
      // Toa do px co tru ban kinh dau tron.
      expect(TempRangeGeometry.xFor(0, 106, 3), 3);
      expect(TempRangeGeometry.xFor(1, 106, 3), 103);
      expect(TempRangeGeometry.xFor(0.5, 106, 3), 53);
    });

    test('cham nam ngoai doan bi kep vao doan; thang suy bien', () {
      const g = TempRangeGeometry(
        scaleMin: 20,
        scaleMax: 30,
        low: 22,
        high: 28,
        current: 35,
      );
      expect(g.dot, closeTo(0.8, 1e-9));
      const flat = TempRangeGeometry(
        scaleMin: 25,
        scaleMax: 25,
        low: 25,
        high: 25,
      );
      expect(flat.start, 0.5);
      expect(flat.dot, isNull);
      const swapped = TempRangeGeometry(
        scaleMin: 0,
        scaleMax: 10,
        low: 8,
        high: 2,
      );
      expect(swapped.start, closeTo(0.2, 1e-9));
      expect(swapped.end, closeTo(0.8, 1e-9));
    });
  });

  group('Mat troi moc / lan trong dai theo gio', () {
    test('chen dung vi tri, dung nhan gio phut', () {
      final start = DateTime.utc(2026, 10, 15, 0);
      final hours = [
        for (var i = 0; i < 30; i++)
          HourlyForecast(
            time: start.add(Duration(hours: i)),
            temperature: 26,
            condition: WeatherCondition.cloudy,
          ),
      ];
      final entries = buildHourlyTimeline(hours, nowHcm: start);
      final s15 = SunTimes.forDate(
        start,
        lat: ApiConfig.latitude,
        lon: ApiConfig.longitude,
      );
      final s16 = SunTimes.forDate(
        start.add(const Duration(days: 1)),
        lat: ApiConfig.latitude,
        lon: ApiConfig.longitude,
      );
      final suns = entries.whereType<SunEntry>().toList();
      // 15/10: moc + lan; 16/10 (den 05:59): moc khoang 05:4x.
      expect(suns.map((e) => e.time), [s15.sunrise, s15.sunset, s16.sunrise]);
      expect(suns.map((e) => e.isSunrise), [true, false, true]);
      String hm(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      expect(suns[0].timeText, hm(s15.sunrise));
      expect(suns[1].timeText, hm(s15.sunset));
      expect(suns[0].label, 'Mặt trời mọc');
      expect(suns[1].label, 'Mặt trời lặn');

      // Thu tu tang dan; moc ngay sau o gio chua no, truoc o gio ke tiep.
      for (var i = 1; i < entries.length; i++) {
        expect(entries[i].time.isBefore(entries[i - 1].time), isFalse);
      }
      final iRise = entries.indexOf(suns[0]);
      final before = entries[iRise - 1] as HourEntry;
      final after = entries[iRise + 1] as HourEntry;
      expect(before.time.hour, s15.sunrise.hour);
      expect(after.time.hour, s15.sunrise.hour + 1);
      expect(entries.whereType<HourEntry>(), hasLength(30));
      expect(entries.whereType<HourEntry>().first.isNow, isTrue);
    });

    test('moc ngoai pham vi bi bo', () {
      final start = DateTime.utc(2026, 10, 15, 8);
      final hours = [
        for (var i = 0; i < 3; i++)
          HourlyForecast(
            time: start.add(Duration(hours: i)),
            temperature: 26,
            condition: WeatherCondition.cloudy,
          ),
      ];
      expect(
        buildHourlyTimeline(hours, nowHcm: start).whereType<SunEntry>(),
        isEmpty,
      );
    });
  });

  group('AQI / UV', () {
    test('ranh gioi muc AQI (US EPA)', () {
      expect(AqiCategory.of(0).label, 'Tốt');
      expect(AqiCategory.of(50).label, 'Tốt');
      expect(AqiCategory.of(51).label, 'Trung bình');
      expect(AqiCategory.of(100).label, 'Trung bình');
      expect(AqiCategory.of(101).label, 'Kém cho nhóm nhạy cảm');
      expect(AqiCategory.of(150).label, 'Kém cho nhóm nhạy cảm');
      expect(AqiCategory.of(151).label, 'Kém');
      expect(AqiCategory.of(200).label, 'Kém');
      expect(AqiCategory.of(201).label, 'Rất kém');
      expect(AqiCategory.of(300).label, 'Rất kém');
      expect(AqiCategory.of(301).label, 'Nguy hại');
      expect(AqiCategory.of(600).label, 'Nguy hại');
      expect(aqiMarker(0), 0);
      expect(aqiMarker(250), 0.5);
      expect(aqiMarker(101), closeTo(0.202, 1e-9));
      expect(aqiMarker(900), 1);
    });

    test('ranh gioi muc UV (WHO)', () {
      expect(UvCategory.of(0).label, 'Thấp');
      expect(UvCategory.of(2.4).label, 'Thấp');
      expect(UvCategory.of(2.5).label, 'Trung bình');
      expect(UvCategory.of(5).label, 'Trung bình');
      expect(UvCategory.of(6).label, 'Cao');
      expect(UvCategory.of(7).label, 'Cao');
      expect(UvCategory.of(8).label, 'Rất cao');
      expect(UvCategory.of(10).label, 'Rất cao');
      expect(UvCategory.of(11).label, 'Cực cao');
      expect(UvCategory.of(14).label, 'Cực cao');
      expect(uvMarker(5.5), 0.5);
      expect(uvMarker(15), 1);
    });

    Future<void> pumpCards(WidgetTester tester, Widget a, Widget b) async {
      final provider = await _provider(_afternoon);
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: Column(children: [a, b])),
          ),
        ),
      );
    }

    testWidgets('null -> "Không có dữ liệu", khong co so', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCards(
        tester,
        const AqiCard(usAqi: null),
        const UvCard(uvIndex: null),
      );
      expect(find.text(kNoData), findsNWidgets(2));
      expect(find.byType(IndexScaleBar), findsNothing);
      expect(
        find.bySemanticsLabel('Chất lượng không khí: $kNoData'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('co so lieu: gia tri, muc, vach', (tester) async {
      await pumpCards(
        tester,
        const AqiCard(usAqi: 101, pm25: 36.6),
        const UvCard(uvIndex: 3.15),
      );
      expect(find.text('Kém cho nhóm nhạy cảm'), findsOneWidget);
      expect(find.text('Trung bình'), findsOneWidget);
      final bars = tester.widgetList<IndexScaleBar>(find.byType(IndexScaleBar));
      expect(bars.map((b) => b.marker), [aqiMarker(101), uvMarker(3.15)]);
    });
  });

  group('Canh tu thoi tiet hien tai', () {
    test('ma 61 luc 14:00 -> rain (ngay)', () async {
      final p = await _provider(DateTime.utc(2026, 10, 15, 14), code: 61);
      final d = AppSceneData.compute(provider: p);
      expect(d.isDay, isTrue);
      expect(d.scene, WeatherScene.rain);
    });

    test('ma 0 luc 21:00 -> clearNight', () async {
      final p = await _provider(DateTime.utc(2026, 10, 15, 21), code: 0);
      final d = AppSceneData.compute(provider: p);
      expect(d.isDay, isFalse);
      expect(d.scene, WeatherScene.clearNight);
    });

    test('che do xem lai dung gio xem lai', () async {
      final p = WeatherProvider(
        apiService: _FakeApi(DateTime.utc(2026, 10, 7, 12), code: 0),
        initialSettings: AppSettings(
          replayEnabled: true,
          replayAt: DateTime.utc(2026, 10, 7, 12),
        ),
        clock: _clockAt(DateTime.utc(2026, 10, 15, 22)),
      );
      await p.fetchWeatherData();
      expect(AppSceneData.compute(provider: p).scene, WeatherScene.clearDay);
    });

    test('dang tai lai (chua co du lieu) -> giu canh cu', () {
      final p = WeatherProvider(
        apiService: _FakeApi(_afternoon),
        initialSettings: const AppSettings(),
        clock: _clockAt(_afternoon),
      );
      final d = AppSceneData.compute(
        provider: p,
        previous: WeatherScene.thunderstorm,
      );
      expect(d.scene, WeatherScene.thunderstorm);
    });
  });

  group('Home kinh', () {
    testWidgets('gia lap doi canh Home ngay lap tuc', (tester) async {
      final (_, o) = await _pumpHome(tester, code: 61);
      expect(_homeScene(tester), WeatherScene.rain);
      o.set(scene: WeatherScene.snow);
      await tester.pump();
      expect(_homeScene(tester), WeatherScene.snow);
      o.set(scene: WeatherScene.clearNight, isDay: false);
      await tester.pump();
      expect(_homeScene(tester), WeatherScene.clearNight);
      o.clear();
      await tester.pump();
      expect(_homeScene(tester), WeatherScene.rain);
    });

    testWidgets('cuon -> thanh gon "26° | Nhiều mây"', (tester) async {
      await _pumpHome(tester);
      expect(find.text('26° | Nhiều mây'), findsNothing);
      expect(find.text('Cao 30° · Thấp 24°'), findsOneWidget);
      expect(find.text('Cảm giác như 33°'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('26° | Nhiều mây'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('UV / AQI null tren Home -> "Không có dữ liệu"', (
      tester,
    ) async {
      await _pumpHome(tester);
      final seen = <String>{};
      for (var i = 0; i < 10; i++) {
        if (find.text('CHỈ SỐ UV').evaluate().isNotEmpty) seen.add('uv');
        if (find.text(kNoData).evaluate().length >= 2) seen.add('nodata');
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
        await tester.pump();
      }
      expect(seen, containsAll(['uv', 'nodata']));
    });

    for (final scale in [1.0, 1.6]) {
      testWidgets('1024x768 ngang, hai cot, co chu $scale: khong tran', (
        tester,
      ) async {
        await _pumpHome(tester, size: const Size(1024, 768), scale: scale);
        expect(find.text('DỰ BÁO 7 NGÀY'), findsOneWidget); // cot phai
        expect(find.text('TP. Hồ Chí Minh'), findsOneWidget);
        for (var i = 0; i < 8; i++) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -300),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      });
    }

    for (final size in const [Size(360, 740), Size(390, 844), Size(412, 915)]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets(
          '${size.width.toInt()}x${size.height.toInt()} co chu $scale: khong tran',
          (tester) async {
            await _pumpHome(tester, size: size, scale: scale, hourProb: 0.8);
            for (var i = 0; i < 12; i++) {
              await tester.drag(
                find.byType(CustomScrollView),
                const Offset(0, -300),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
            }
          },
        );
      }
    }

    testWidgets('canh bao mua: hien, doc duoc, dong duoc', (tester) async {
      await _pumpHome(tester, hourProb: 0.8);
      expect(
        find.text('Khả năng mưa cao · 14:00\u2060–\u206020:00'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Đóng cảnh báo'));
      await tester.pump();
      expect(find.textContaining('Khả năng mưa cao'), findsNothing);
    });

    testWidgets('khong canh bao khi xac suat thap', (tester) async {
      await _pumpHome(tester);
      expect(find.textContaining('Cảnh báo'), findsNothing);
      expect(find.textContaining('Khả năng mưa cao'), findsNothing);
    });

    testWidgets('nut bam >= 48 dp', (tester) async {
      final handle = tester.ensureSemantics();
      // Man hinh rat cao: moi the cung hien (khong bi header ghim cat) ->
      // kiem moi nut bam mot lan.
      await _pumpHome(tester, size: const Size(390, 5200), hourProb: 0.8);
      expect(find.text('Lượng mưa'.toUpperCase()), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await _pumpHome(tester, size: const Size(390, 844), hourProb: 0.8);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    for (final dark in [false, true]) {
      testWidgets('theme ${dark ? 'toi' : 'sang'}: sheet dia diem doc duoc', (
        tester,
      ) async {
        await _pumpHome(
          tester,
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        );
        await tester.tap(find.byTooltip('Danh sách địa điểm'));
        await tester.pumpAndSettle();
        final t = tester.widget<Text>(find.text('Đang xem'));
        expect(t.style?.color, Colors.white);
        expect(tester.takeException(), isNull);
      });
    }

    for (final w in [360.0, 390.0]) {
      testWidgets('mat troi khong de len chu dau trang (rong $w)', (
        tester,
      ) async {
        for (final code in [0, 3]) {
          await _pumpHome(tester, size: Size(w, 800), code: code);
          final bg = tester.widget<WeatherBackground>(
            find.byType(WeatherBackground).first,
          );
          final disc = bg.celestial!.discRect;
          for (final t in ['TP. Hồ Chí Minh', '26°', 'Nhiều mây']) {
            final f = find.text(t);
            if (f.evaluate().isEmpty) continue;
            expect(
              disc.overlaps(tester.getRect(f.first)),
              isFalse,
              reason: '$t: ${tester.getRect(f.first)} vs $disc',
            );
          }
        }
      });
    }

    testWidgets('khong lap cau tom tat o dau trang; khong pill nguon', (
      tester,
    ) async {
      await _pumpHome(tester, hourProb: 0.8);
      expect(find.textContaining('Có khả năng mưa'), findsOneWidget);
      expect(find.text('Thực tế'), findsNothing);
    });

    for (final w in [360.0, 390.0]) {
      testWidgets('nut khong de len chu dau trang khi cuon (rong $w)', (
        tester,
      ) async {
        await _pumpHome(tester, size: Size(w, 800));
        final buttons = [
          tester.getRect(find.byTooltip('Làm mới')),
          tester.getRect(find.byTooltip('Cài đặt')),
        ];
        double opacityOf(Element e) {
          double o = 1;
          e.visitAncestorElements((a) {
            final wdg = a.widget;
            if (wdg is Opacity) o *= wdg.opacity;
            return wdg is! CustomScrollView;
          });
          return o;
        }

        for (var step = 0; step < 12; step++) {
          final clip = find.byKey(CollapsingHeaderDelegate.heroClipKey);
          final clipRect = clip.evaluate().isEmpty
              ? null
              : tester.getRect(clip);
          final header = find.byType(SliverPersistentHeader);
          for (final e
              in find
                  .descendant(of: header, matching: find.byType(Text))
                  .evaluate()) {
            if (opacityOf(e) <= 0.1) continue;
            var r = tester.getRect(find.byWidget(e.widget).first);
            final inHero = find
                .descendant(of: clip, matching: find.byWidget(e.widget))
                .evaluate()
                .isNotEmpty;
            if (inHero && clipRect != null) {
              if (!r.overlaps(clipRect)) continue;
              r = r.intersect(clipRect);
            }
            for (final b in buttons) {
              expect(
                b.overlaps(r),
                isFalse,
                reason:
                    '"${(e.widget as Text).data}" $r vs nut $b (buoc $step)',
              );
            }
          }
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -30),
          );
          await tester.pump();
        }
        // Sau khi cuon het dau trang: thanh gon hien du.
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pump();
        final compact = find.text('26° | Nhiều mây');
        expect(compact, findsOneWidget);
        expect(opacityOf(compact.evaluate().first), 1.0);
      });
    }

    testWidgets('pill bar: ban do va danh sach dia diem', (tester) async {
      await _pumpHome(tester);
      await tester.tap(find.byTooltip('Bản đồ'));
      await tester.pumpAndSettle();
      expect(find.text('Bản đồ'), findsWidgets);
      // Ban do flutter_map: attribution OpenStreetMap.
      expect(find.textContaining('OpenStreetMap'), findsWidgets);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Danh sách địa điểm'));
      await tester.pumpAndSettle();
      expect(find.text('Địa điểm'), findsOneWidget);
      expect(find.text('Đang xem'), findsOneWidget);
    });

    testWidgets('khong ro ri ticker khi roi Home', (tester) async {
      await _pumpHome(tester, reduceMotion: false, code: 61);
      expect(WeatherBackground.debugRunningTickers, greaterThan(0));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(WeatherBackground.debugLiveStates, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(WeatherBackground.debugLiveStates, 0);
      expect(WeatherBackground.debugRunningTickers, 0);
    });
  });

  test('the kinh dung mau kinh cua canh', () {
    final th = SceneTheme.of(WeatherScene.clearDay);
    expect(th.glassColor.a, inInclusiveRange(0.18, 0.22));
    expect(GlassSpec.radius, 22);
  });

  test('nhan nguon chi cho nguon thieu so khi tron', () {
    expect(
      minoritySources([DataSource.observed, DataSource.observed]),
      isEmpty,
    );
    expect(
      minoritySources([
        DataSource.observed,
        DataSource.forecast,
        DataSource.forecast,
      ]),
      {DataSource.observed},
    );
    expect(minoritySources([null, DataSource.forecast, DataSource.forecast]), {
      DataSource.climatology,
    });
  });

  test('ten mo hinh rut gon', () {
    expect(AIForecastCard.shortModel('lgbm-hcmc-v2-20261015'), 'mô hình v2');
    expect(AIForecastCard.shortModel('lgbm'), isNull);
  });
}
