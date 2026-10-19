import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/bottom_pill_bar.dart';
import 'package:sky_weather_app/ui/weather/widgets/home_motion.dart';
import 'package:sky_weather_app/ui/weather/widgets/rain_timeline_card.dart';

/// Home v2: the dong thoi gian mua + nut "Ra ngoài" o 360 px, chu x1 / x2.
void main() {
  final t0 = DateTime.utc(2026, 10, 18, 9);
  final slots = [
    for (var i = 0; i < 24; i++)
      (
        time: t0.add(Duration(hours: i)),
        p: i >= 3 && i < 8 ? 0.9 : 0.05,
        mm: i >= 3 && i < 8 ? 2.0 : 0.0,
        thunder: i == 3,
      ),
  ];

  Future<void> pump(WidgetTester tester, Widget child, double scale) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: AppScene(
            data: const AppSceneData(
              scene: WeatherScene.rain,
              isDay: true,
              windSpeedKmh: 0,
              intensity: 0,
              resolved: WeatherScene.rain,
            ),
            child: c!,
          ),
        ),
        home: Scaffold(
          backgroundColor: Colors.blueGrey,
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('the mua: cham mo, dong 48 dp, khong tran (x$scale)', (
      tester,
    ) async {
      var opened = 0;
      var closed = 0;
      await pump(
        tester,
        RainTimelineCard(
          slots: slots,
          title: 'Cảnh báo · Dông, sét · 12:00–17:00',
          thunder: true,
          onOpen: () => opened++,
          onDismiss: () => closed++,
        ),
        scale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Bây giờ'), findsOneWidget);
      expect(find.textContaining('tổng 10,0 mm'), findsOneWidget);
      final close = tester.getSize(find.byTooltip('Đóng cảnh báo'));
      expect(close.width, greaterThanOrEqualTo(48));
      await tester.tap(find.textContaining('Cảnh báo ·'));
      await tester.tap(find.byTooltip('Đóng cảnh báo'));
      expect((opened, closed), (1, 1));
    });

    testWidgets('nut Ra ngoai: mini mua 2h, >= 48 dp (x$scale)', (
      tester,
    ) async {
      var trips = 0;
      await pump(
        tester,
        Align(
          alignment: Alignment.bottomCenter,
          child: BottomPillBar(
            pageCount: 3,
            currentPage: 1,
            onMap: () {},
            onLocations: () {},
            onTrip: () => trips++,
            tripRainPercent: 70,
          ),
        ),
        scale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Mưa 2h: 70%'), findsOneWidget);
      final b = tester.getSize(find.byTooltip('Tôi sắp ra ngoài'));
      expect(b.height, greaterThanOrEqualTo(48));
      await tester.tap(find.byTooltip('Tôi sắp ra ngoài'));
      expect(trips, 1);
      expect(
        find.bySemanticsLabel('Tôi sắp ra ngoài. Khả năng mưa 2 giờ tới 70%'),
        findsOneWidget,
      );
    });
  }

  testWidgets('enabling reduced motion completes an active entrance', (
    tester,
  ) async {
    final reduce = ValueNotifier(false);
    addTearDown(reduce.dispose);
    final startedAt = DateTime.now();
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reduce,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: StaggerIn(
              index: 7,
              startedAt: startedAt,
              child: const Text('Forecast'),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    final entranceTransform = find.descendant(
      of: find.byType(StaggerIn),
      matching: find.byType(Transform),
    );
    expect(entranceTransform, findsOneWidget);
    reduce.value = true;
    await tester.pump();
    expect(entranceTransform, findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Forecast'), findsOneWidget);
  });

  testWidgets('enabling reduced motion stops active refresh drops', (
    tester,
  ) async {
    final reduce = ValueNotifier(false);
    addTearDown(reduce.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reduce,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: RainRefresh(
              onRefresh: () async {},
              backgroundColor: Colors.black,
              child: ListView(children: const [Text('Forecast')]),
            ),
          ),
        ),
      ),
    );
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump(const Duration(milliseconds: 100));
    final drops = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is RainDropsPainter,
    );
    expect(drops, findsOneWidget);
    reduce.value = true;
    await tester.pump();
    expect(drops, findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
