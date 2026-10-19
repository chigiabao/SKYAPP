// Benchmark don gian: thoi gian build+paint (pump) va raster (toImage) cua
// WeatherBackground cho 120 khung 60 Hz o cac canh nang. In so lieu, chi
// assert long (khong lam vo CI tren may cham).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';

const Duration _frame = Duration(microseconds: 16667);

Widget _app(WeatherScene scene, GlobalKey key, {bool glass = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: RepaintBoundary(
          key: key,
          child: WeatherBackground(
            scene: scene,
            windSpeedKmh: 25,
            seed: 3,
            child: glass
                ? ListView(
                    padding: const EdgeInsets.only(top: 300),
                    children: [
                      for (int i = 0; i < 4; i++)
                        const GlassSurface(
                          tint: Color(0x33FFFFFF),
                          child: SizedBox(height: 100),
                        ),
                    ],
                  )
                : null,
          ),
        ),
      ),
    );

Future<void> _bench(
  WidgetTester tester,
  WeatherScene scene,
  String label, {
  bool glass = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  WeatherBackground.resetQuality();
  final GlobalKey key = GlobalKey();
  await tester.pumpWidget(_app(scene, key, glass: glass));
  await tester.pump(_frame);

  final int frames0 = WeatherBackground.debugPaintedFrames;
  final Stopwatch pumpSw = Stopwatch()..start();
  for (int i = 0; i < 120; i++) {
    await tester.pump(_frame);
  }
  pumpSw.stop();
  final int painted = WeatherBackground.debugPaintedFrames - frames0;

  // Raster: trung binh 10 khung (toImage), nhan voi so khung thuc su ve.
  final RenderRepaintBoundary rb =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  int rasterUs = 0;
  for (int i = 0; i < 10; i++) {
    await tester.pump(_frame * 2);
    await tester.runAsync(() async {
      final Stopwatch sw = Stopwatch()..start();
      final ui.Image img = await rb.toImage();
      await img.toByteData();
      sw.stop();
      rasterUs += sw.elapsedMicroseconds;
      img.dispose();
    });
  }
  final double rasterMs = rasterUs / 10 / 1000;
  // ignore: avoid_print
  print(
    'BENCH $label: pump120=${pumpSw.elapsedMilliseconds} ms, '
    'painted=$painted/120, raster/frame=${rasterMs.toStringAsFixed(2)} ms, '
    'raster120~${(rasterMs * painted).toStringAsFixed(0)} ms',
  );
  expect(painted, greaterThan(0));
  await tester.pumpWidget(const SizedBox());
}

void main() {
  for (final WeatherScene s in [
    WeatherScene.thunderstorm,
    WeatherScene.rain,
    WeatherScene.cloudy,
  ]) {
    testWidgets('bench ${s.name}', (tester) => _bench(tester, s, s.name));
  }
  testWidgets(
    'bench rain + glass cards',
    (tester) => _bench(tester, WeatherScene.rain, 'rain+glass', glass: true),
  );

  testWidgets('active=false dung ticker; 30 fps theo thoi gian', (
    tester,
  ) async {
    Widget bg(bool active) => MaterialApp(
      home: WeatherBackground(
        scene: WeatherScene.rain,
        seed: 1,
        active: active,
      ),
    );
    await tester.pumpWidget(bg(true));
    final int f0 = WeatherBackground.debugPaintedFrames;
    for (int i = 0; i < 60; i++) {
      await tester.pump(_frame);
    }
    // ~30 khung trong 1 s o 60 Hz.
    expect(WeatherBackground.debugPaintedFrames - f0, inInclusiveRange(28, 32));
    await tester.pumpWidget(bg(false));
    expect(WeatherBackground.debugRunningTickers, 0);
    final int f1 = WeatherBackground.debugPaintedFrames;
    await tester.pump(const Duration(seconds: 1));
    expect(WeatherBackground.debugPaintedFrames, f1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(bg(true));
    await tester.pump(_frame);
    expect(WeatherBackground.debugRunningTickers, 1);
    await tester.pumpWidget(const SizedBox());
    expect(WeatherBackground.debugRunningTickers, 0);
  });
}
