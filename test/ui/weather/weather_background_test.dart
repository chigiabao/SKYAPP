import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/debug/weather_simulator_screen.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/ui/weather/weather_icons.dart';

Widget _app(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(390, 844),
      disableAnimations: disableAnimations,
    ),
    child: child,
  ),
);

void main() {
  setUp(WeatherBackground.resetQuality);

  testWidgets('doi canh 50 lan roi go bo: khong loi, khong ro ticker', (
    tester,
  ) async {
    const scenes = WeatherScene.values;
    for (int i = 0; i < 50; i++) {
      await tester.pumpWidget(
        _app(
          WeatherBackground(
            scene: scenes[i % scenes.length],
            windSpeedKmh: (i * 7 % 80).toDouble(),
            seed: 3,
          ),
        ),
      );
      await tester.pump(Duration(milliseconds: 16 + (i % 5) * 40));
      expect(WeatherBackground.debugLiveStates, 1);
      expect(WeatherBackground.debugRunningTickers, 1);
    }
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(WeatherBackground.debugLiveStates, 0);
    expect(WeatherBackground.debugRunningTickers, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('chuyen canh giu lop cu den khi xong (700 ms)', (tester) async {
    await tester.pumpWidget(
      _app(const WeatherBackground(scene: WeatherScene.clearDay, seed: 1)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(
      _app(const WeatherBackground(scene: WeatherScene.rain, seed: 1)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    // Giua chung: ca hai bo lop cung ton tai.
    expect(
      find.descendant(
        of: find.byType(WeatherBackground),
        matching: find.byType(FadeTransition),
      ),
      findsNWidgets(2),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(WeatherBackground),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(_app(const SizedBox()));
  });

  testWidgets('giam chuyen dong: khong ticker, khong hat', (tester) async {
    await tester.pumpWidget(
      _app(
        const WeatherBackground(scene: WeatherScene.heavyRain, seed: 2),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(WeatherBackground.debugRunningTickers, 0);
    // Doi canh cung tuc thi, khong lap lich khung hinh.
    await tester.pumpWidget(
      _app(
        const WeatherBackground(scene: WeatherScene.snow, seed: 2),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(_app(const SizedBox()));
  });

  testWidgets('TickerMode tat -> khong lap lich khung hinh', (tester) async {
    await tester.pumpWidget(
      _app(
        const TickerMode(
          enabled: false,
          child: WeatherBackground(scene: WeatherScene.snow),
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_app(const SizedBox()));
  });

  testWidgets('app vao nen -> dung ticker, tro lai -> chay tiep', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const WeatherBackground(scene: WeatherScene.rain)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(WeatherBackground.debugRunningTickers, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(WeatherBackground.debugRunningTickers, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(WeatherBackground.debugRunningTickers, 1);
    await tester.pumpWidget(_app(const SizedBox()));
    expect(WeatherBackground.debugRunningTickers, 0);
  });

  testWidgets('splashTargets + lowPower + haptics khong loi', (tester) async {
    final targets = ValueNotifier<List<Rect>>([
      const Rect.fromLTWH(16, 300, 358, 120),
    ]);
    addTearDown(targets.dispose);
    await tester.pumpWidget(
      _app(
        WeatherBackground(
          scene: WeatherScene.thunderstorm,
          windSpeedKmh: 30,
          intensity: 1.5,
          lowPower: true,
          lightningHaptics: true,
          splashTargets: targets,
          seed: 5,
        ),
      ),
    );
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    targets.value = [const Rect.fromLTWH(16, 500, 358, 80)];
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_app(const SizedBox()));
  });

  test('SceneOverride + effectiveScene', () {
    final o = SceneOverride();
    int notified = 0;
    o.addListener(() => notified++);
    expect(o.active, isFalse);
    expect(effectiveScene(WeatherScene.rain, o), WeatherScene.rain);
    expect(effectiveScene(WeatherScene.rain, null), WeatherScene.rain);
    o.set(scene: WeatherScene.snow);
    expect(o.active, isTrue);
    expect(effectiveScene(WeatherScene.rain, o), WeatherScene.snow);
    o.set(isDay: false);
    expect(o.scene, isNull);
    expect(effectiveScene(WeatherScene.clearDay, o), WeatherScene.clearNight);
    expect(effectiveScene(WeatherScene.fog, o), WeatherScene.fog);
    o.clear();
    expect(o.active, isFalse);
    expect(notified, 3);
    o.dispose();
  });

  testWidgets('WeatherIcon ve duoc moi canh o 16-64 px', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Wrap(
          children: [
            for (final s in WeatherScene.values)
              for (final double size in [16, 28, 64])
                WeatherIcon(scene: s, size: size),
            WeatherIcon.fromCode(95, isDay: true, color: Colors.white),
            WeatherIcon.fromCode(null, isDay: false),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Dông'), findsWidgets);
    final fromCode = tester.widget<WeatherIcon>(
      find.byType(WeatherIcon).at(45),
    );
    expect(fromCode.scene, WeatherScene.thunderstorm);
  });

  testWidgets('man hinh gia lap: ap dung va bo gia lap', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final o = SceneOverride();
    addTearDown(o.dispose);
    expect(WeatherSimulatorScreen.available, isTrue);
    await tester.pumpWidget(
      MaterialApp(home: WeatherSimulatorScreen(sceneOverride: o)),
    );
    await tester.pump();
    expect(find.text('Giả lập thời tiết'), findsOneWidget);
    await tester.tap(find.text('Mưa to'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.ensureVisible(find.text('Áp dụng cho ứng dụng'));
    await tester.tap(find.text('Áp dụng cho ứng dụng'));
    await tester.pump();
    expect(o.active, isTrue);
    expect(o.scene, WeatherScene.heavyRain);
    await tester.tap(find.text('Bỏ giả lập'));
    await tester.pump();
    expect(o.active, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
