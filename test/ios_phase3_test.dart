// Phase 3 (giao dien iOS tung man): tieu de lon, danh sach inset-grouped,
// sheet dung chung, chu giai ban do gon, chu mua 7 ngay, ngon ngu de hieu.
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_page.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_controls.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_list.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_page.dart';
import 'package:sky_weather_app/ui/weather/widgets/ios_sheet.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(390, 844),
  bool reduceMotion = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = WeatherProvider();
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
}

Widget _page({List<Widget>? children, Future<void> Function()? onRefresh}) =>
    GlassPage(
      child: Builder(
        builder: (_) => IosPageScaffold(
          title: 'Cảnh báo',
          onRefresh: onRefresh,
          actions: [
            IosBarButton(
              icon: CupertinoIcons.refresh,
              tooltip: 'Tải lại',
              onPressed: () {},
            ),
          ],
          children:
              children ??
              [
                for (var i = 0; i < 30; i++)
                  SizedBox(height: 60, child: Text('Hàng $i')),
              ],
        ),
      ),
    );

DailyForecast _day(
  String source, {
  double? rain,
  int code = 3,
  String? confidence,
}) => DailyForecast.fromJson({
  'date': '2026-10-21',
  'temperature_min': 24,
  'temperature_max': 31,
  'weather_code': code,
  'source': source,
  'rain_day_probability': rain,
  'confidence': ?confidence,
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Tieu de lon iOS', () {
    testWidgets('34pt large title collapses to inline bar with blur', (
      tester,
    ) async {
      await _pump(tester, _page());
      final bar = find.byType(CupertinoSliverNavigationBar);
      expect(bar, findsOneWidget);
      final w = tester.widget<CupertinoSliverNavigationBar>(bar);
      // Tieu de dai: thu nho toi ~28 pt roi cat "...", chua le phai.
      final large = w.largeTitle! as IosLargeTitle;
      expect(large.title, 'Cảnh báo');
      // Nen mo (blur) khi cuon: mau thanh khong dac.
      expect(w.backgroundColor, Palette.navBar);
      expect(Palette.navBar.a, lessThan(1));
      // Kieu chu tieu de lon 34 pt dam.
      final style = CupertinoTheme.of(
        tester.element(find.text('Cảnh báo').first),
      ).textTheme.navLargeTitleTextStyle;
      expect(style.fontSize, 34);
      expect(style.color, Palette.white);
      double barHeight() =>
          tester.renderObject<RenderSliver>(bar).geometry!.paintExtent;
      final before = barHeight();
      expect(before, greaterThanOrEqualTo(44 + 52));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      // Thu lai thanh 44 pt (tieu de 17 pt o giua).
      expect(barHeight(), closeTo(44, 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion: static 17pt bar, no large title', (
      tester,
    ) async {
      await _pump(tester, _page(), reduceMotion: true);
      expect(find.byType(CupertinoSliverNavigationBar), findsNothing);
      final bar = tester.widget<CupertinoNavigationBar>(
        find.byType(CupertinoNavigationBar),
      );
      expect((bar.middle! as Text).data, 'Cảnh báo');
      expect(bar.transitionBetweenRoutes, isFalse);
    });

    testWidgets('pull-to-refresh is the iOS sliver control', (tester) async {
      var refreshed = 0;
      await _pump(tester, _page(onRefresh: () async => refreshed++));
      expect(
        find.byType(CupertinoSliverRefreshControl, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(RefreshIndicator), findsNothing);
    });

    testWidgets('200% text: title and actions do not overflow', (tester) async {
      await _pump(tester, _page(), size: const Size(375, 667), textScale: 2);
      expect(tester.takeException(), isNull);
      final back = find.byTooltip('Tải lại');
      expect(tester.getSize(back).height, greaterThanOrEqualTo(44));
    });
  });

  group('Danh sach inset-grouped', () {
    testWidgets('header, rounded group, hairlines, row targets', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await _pump(
        tester,
        _page(
          children: [
            IosListSection(
              header: 'Thông báo',
              footer: 'Chú thích nhóm.',
              children: [
                IosListRow(title: 'Một', onTap: () => taps++),
                const IosListRow(title: 'Hai', subtitle: 'Phụ'),
                const IosListRow(title: 'Ba', value: '°C'),
              ],
            ),
          ],
        ),
        reduceMotion: true,
      );
      expect(find.text('THÔNG BÁO'), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-inset-group')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ios-inset-group')),
          matching: find.byType(Divider),
        ),
        findsNWidgets(2),
      );
      final group = tester.widget<GlassSurface>(
        find.byKey(const ValueKey('ios-inset-group')),
      );
      expect(group.radius, Radii.group);
      expect(
        tester.getSemantics(find.text('THÔNG BÁO')),
        isSemantics(isHeader: true, label: 'THÔNG BÁO'),
      );
      expect(tester.getSize(find.text('Một').first).height, lessThan(48));
      final row = find.ancestor(
        of: find.text('Một'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      await tester.tap(row);
      expect(taps, 1);
      expect(find.byIcon(CupertinoIcons.chevron_forward), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('selectable pill shows checkmark when selected', (
      tester,
    ) async {
      var on = false;
      await _pump(
        tester,
        GlassPage(
          child: StatefulBuilder(
            builder: (context, set) => Scaffold(
              body: Center(
                child: IosPill(
                  label: 'Chạy bộ',
                  icon: CupertinoIcons.sportscourt,
                  selected: on,
                  onChanged: (v) => set(() => on = v),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(CupertinoIcons.checkmark_alt), findsNothing);
      expect(
        tester.getSize(find.byType(IosPill)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('Chạy bộ'));
      await tester.pump();
      expect(on, isTrue);
      expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);
    });
  });

  group('Sheet dung chung', () {
    testWidgets('grabber, 13pt corners, title and close', (tester) async {
      String? result;
      await _pump(
        tester,
        GlassPage(
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result = await showIosSheet<String>(
                    context,
                    title: 'Chi tiết ô',
                    builder: (c) => TextButton(
                      onPressed: () => Navigator.pop(c, 'ok'),
                      child: const Text('Chọn'),
                    ),
                  ),
                  child: const Text('Mở'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở'));
      await tester.pumpAndSettle();
      final clip = tester.widget<ClipRRect>(
        find.byKey(const ValueKey('glass-sheet')),
      );
      expect(
        clip.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      );
      expect(
        find.byKey(const ValueKey('glass-sheet-drag-handle')),
        findsOneWidget,
      );
      expect(find.text('Chi tiết ô'), findsOneWidget);
      expect(find.byTooltip('Đóng'), findsOneWidget);
      await tester.tap(find.text('Chọn'));
      await tester.pumpAndSettle();
      expect(result, 'ok');
    });

    testWidgets('time sheet: CupertinoDatePicker with Cancel / Done', (
      tester,
    ) async {
      TimeOfDay? picked;
      var closed = false;
      await _pump(
        tester,
        GlassPage(
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await showIosTimeSheet(
                      context,
                      title: 'Giờ về',
                      initial: const TimeOfDay(hour: 17, minute: 30),
                    );
                    closed = true;
                  },
                  child: const Text('Mở'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsOneWidget);
      expect(find.text('Giờ về'), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-sheet-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ios-sheet-done')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(picked, const TimeOfDay(hour: 17, minute: 30));

      closed = false;
      await tester.tap(find.text('Mở'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ios-sheet-cancel')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(picked, isNull);
    });

    testWidgets('form nav bar stacks title at 200% text without overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        GlassPage(
          child: Scaffold(
            body: IosSheetNavBar(
              title: 'Khôi phục mật khẩu',
              doneLabel: 'Đổi mật khẩu',
              onDone: () {},
            ),
          ),
        ),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Khôi phục mật khẩu'), findsOneWidget);
    });
  });

  group('Chu giai ban do', () {
    const entries = [
      LegendEntry(Palette.tempCool, '24°'),
      LegendEntry(Palette.tempHot, '33°'),
    ];

    testWidgets('phone: compact numbered scale, "Chú giải" expands', (
      tester,
    ) async {
      await _pump(
        tester,
        const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MapLegend(
              layer: MapLayerKind.temperature,
              entries: entries,
              hasMissing: true,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('map-legend-compact')), findsOneWidget);
      // Khong chi dua vao mau: so tren thang + o "Không có dữ liệu".
      expect(find.text('24°'), findsOneWidget);
      expect(find.text('33°'), findsOneWidget);
      expect(find.text('Không có dữ liệu'), findsOneWidget);
      expect(find.text(kOsmAttribution), findsOneWidget);
      expect(find.text('Ô có cảnh báo mưa/dông'), findsNothing);
      final toggle = find.byKey(const ValueKey('map-legend-toggle'));
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(44));
      await tester.tap(toggle);
      await tester.pump();
      expect(find.byKey(const ValueKey('map-legend-expanded')), findsOneWidget);
      expect(find.text('Ô có cảnh báo mưa/dông'), findsOneWidget);
      expect(find.text('Không có dữ liệu'), findsOneWidget);
    });

    testWidgets('tablet/desktop: expanded by default', (tester) async {
      await _pump(
        tester,
        const Scaffold(
          body: MapLegend(layer: MapLayerKind.temperature, entries: entries),
        ),
        size: const Size(1024, 768),
      );
      expect(find.byKey(const ValueKey('map-legend-expanded')), findsOneWidget);
    });
  });

  group('7 ngay: chu mua nhat quan', () {
    test('probability always shown as %, even below 20%', () {
      expect(dailyRainText(_day('ai', rain: 0.05)), '5%');
      expect(dailyRainText(_day('ai', rain: 0.6, code: 61)), '60%');
    });

    test('no probability: "Có mưa" only when icon is rain', () {
      expect(dailyRainText(_day('ai', code: 61)), 'Có mưa');
      expect(dailyRainText(_day('ai', code: 3)), isNull);
      // Ngay thuc te: icon mua -> chu "Có mưa" (khong lech icon).
      expect(dailyRainText(_day('observed', rain: 0, code: 51)), 'Có mưa');
      expect(dailyRainText(_day('observed', rain: 1, code: 3)), 'Có mưa');
      expect(dailyRainText(_day('observed', rain: 0, code: 2)), isNull);
    });

    test('climatology and low confidence rows are "Xu hướng"', () {
      expect(isTrendDay(_day('climatology', rain: 0.3)), isTrue);
      expect(isTrendDay(_day('ai', rain: 0.3, confidence: 'low')), isTrue);
      expect(isTrendDay(_day('ai', rain: 0.3, confidence: 'high')), isFalse);
    });
  });

  group('Ngon ngu de hieu', () {
    test('observed data is plain Vietnamese and still says "mô hình"', () {
      expect(DataSource.observed.label, DataCopy.observed);
      expect(DataCopy.observed, 'Số liệu đã ghi nhận (mô hình)');
      expect(DataSource.observed.note, contains('không phải số đo'));
      expect(DataSource.ai.shortLabel, DataCopy.aiForecast);
    });

    test('no analysis jargon in user-facing strings', () {
      final jargon = RegExp(
        r"'[^'\n]*(dữ liệu mô hình phân tích|số liệu phân tích|"
        r"dữ liệu phân tích|phân tích mô hình)[^'\n]*'",
      );
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trimLeft();
          if (l.startsWith('//')) continue;
          if (jargon.hasMatch(l)) hits.add('${f.path}:${i + 1}');
        }
      }
      expect(hits, isEmpty);
    });
  });
}
