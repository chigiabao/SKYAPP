// Anh golden tao tren Windows: CI Linux/macOS chay `--exclude-tags golden`.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/painters/lightning_painter.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/ui/weather/weather_icons.dart';

const int _seed = 7;
const double _time = 12.3;

/// Gia lap bo cuc Home: tieu de lon tren nen + 2 the kinh co chu trang.
Widget _harness(WeatherScene scene, double time) {
  final SceneTheme th = SceneTheme.of(scene);
  Widget card(double height) => Container(
    height: height,
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: th.glassColor,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0x33FFFFFF)),
    ),
    alignment: Alignment.topLeft,
    child: const Text(
      'Abc 123',
      style: TextStyle(color: Colors.white, fontSize: 14),
    ),
  );
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: WeatherBackground(
      scene: scene,
      windSpeedKmh: scene == WeatherScene.windy ? 45 : 12,
      seed: _seed,
      debugFixedTime: time,
      child: Column(
        children: [
          const SizedBox(height: 96),
          const Text('31', style: TextStyle(color: Colors.white, fontSize: 64)),
          const SizedBox(height: 120),
          card(120),
          card(200),
        ],
      ),
    ),
  );
}

void main() {
  for (final WeatherScene scene in WeatherScene.values) {
    testWidgets('golden ${scene.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Canh dong: chup giua mot lan chop de thay tia set.
      final double time = scene == WeatherScene.thunderstorm
          ? LightningField(seed: _seed + SceneLayer.lightning.index * 101)
                    .firstStrikeTime +
                0.05
          : _time;
      await tester.pumpWidget(_harness(scene, time));
      await tester.pump();
      await expectLater(
        find.byType(WeatherBackground),
        matchesGoldenFile('goldens/${scene.name}.png'),
      );
    });
  }
  iconSheetGolden();
}

/// Bang icon: moi canh o 16 / 28 / 64 px tren nen dem va nen ngay.
void iconSheetGolden() {
  testWidgets('golden icons', (tester) async {
    tester.view.physicalSize = const Size(390, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget row(WeatherScene s) {
      final SceneTheme th = SceneTheme.of(s);
      return Container(
        height: 34,
        decoration: BoxDecoration(gradient: th.linearGradient),
        child: Row(
          children: [
            for (final double size in [16, 28])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: WeatherIcon(scene: s, size: size),
              ),
            WeatherIcon(scene: s, size: 28, color: Colors.white),
          ],
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: const Color(0xFF0B1026),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Column(
                  children: [for (final s in WeatherScene.values) row(s)],
                ),
              ),
              Expanded(
                child: Wrap(
                  children: [
                    for (final s in WeatherScene.values)
                      Padding(
                        padding: const EdgeInsets.all(2),
                        child: WeatherIcon(scene: s, size: 64),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/icons.png'),
    );
  });
}
