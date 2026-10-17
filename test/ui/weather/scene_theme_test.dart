import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';

void main() {
  const Color white = Color(0xFFFFFFFF);

  List<(String, SceneTheme)> allThemes() => [
    for (final WeatherScene s in WeatherScene.values) ...[
      ('${s.name}/ngay', SceneTheme.of(s)),
      ('${s.name}/dem', SceneTheme.of(s, isDay: false)),
    ],
  ];

  group('tuong phan chu trang', () {
    for (final (name, th) in allThemes()) {
      test(name, () {
        for (int i = 0; i <= 20; i++) {
          final double t = i / 20;
          for (int clouds = 0; clouds <= th.maxCloudOverlap; clouds++) {
            final double card = SceneTheme.contrastRatio(
              white,
              th.cardBackdropAt(t, cloudLayers: clouds),
            );
            expect(
              card,
              greaterThanOrEqualTo(4.5),
              reason: 'the kinh tai t=$t, $clouds lop may: $card',
            );
            // Chu lon (nhiet do) dat thang tren nen: WCAG chu lon >= 3:1.
            final double bg = SceneTheme.contrastRatio(
              white,
              th.backdropAt(t, cloudLayers: clouds),
            );
            expect(bg, greaterThanOrEqualTo(3.0), reason: 'nen tai t=$t: $bg');
          }
        }
      });
    }
  });

  test('rang buoc thong so', () {
    for (final (name, th) in allThemes()) {
      expect(th.gradient.length, 3, reason: name);
      expect(th.glassAlpha, inInclusiveRange(0.18, 0.22), reason: name);
      expect(
        th.contrastScrim == 0 ||
            (th.contrastScrim >= 0.12 && th.contrastScrim <= 0.20),
        isTrue,
        reason: name,
      );
      if (th.contrastScrim > 0) expect(th.isBright, isTrue, reason: name);
      expect(th.layers, isNotEmpty, reason: name);
      expect(th.statusBar.statusBarIconBrightness, Brightness.light);
    }
  });

  test('gradient theo dac ta', () {
    expect(SceneTheme.of(WeatherScene.clearDay).gradient, const [
      Color(0xFF3A8DDE),
      Color(0xFF6DB6F2),
      Color(0xFFA8D8F7),
    ]);
    expect(SceneTheme.of(WeatherScene.clearNight).gradient, const [
      Color(0xFF0B1026),
      Color(0xFF1B2A55),
      Color(0xFF33427A),
    ]);
    expect(SceneTheme.of(WeatherScene.cloudy).gradient, const [
      Color(0xFF6E7F96),
      Color(0xFF8F9CB0),
      Color(0xFFAAB4C3),
    ]);
    // Overcast toi hon cloudy; mua toi dan.
    double lum(WeatherScene s) =>
        SceneTheme.of(s).gradient[1].computeLuminance();
    expect(lum(WeatherScene.overcast), lessThan(lum(WeatherScene.cloudy)));
    expect(lum(WeatherScene.rain), lessThan(lum(WeatherScene.drizzle)));
    expect(lum(WeatherScene.heavyRain), lessThan(lum(WeatherScene.rain)));
    expect(
      lum(WeatherScene.thunderstorm),
      lessThan(lum(WeatherScene.heavyRain)),
    );
  });

  test('lerp', () {
    final a = SceneTheme.of(WeatherScene.clearDay);
    final b = SceneTheme.of(WeatherScene.thunderstorm);
    expect(identical(SceneTheme.lerp(a, b, 0), a), isTrue);
    expect(identical(SceneTheme.lerp(a, b, 1), b), isTrue);
    final m = SceneTheme.lerp(a, b, 0.5);
    expect(m.gradient[0], Color.lerp(a.gradient[0], b.gradient[0], 0.5));
    expect(m.glassAlpha, closeTo((a.glassAlpha + b.glassAlpha) / 2, 1e-9));
    expect(m.layers, b.layers);
    expect(SceneTheme.lerp(a, b, 0.49).layers, a.layers);
  });

  test('of tra ve cung instance (khong cap phat lai)', () {
    expect(
      identical(
        SceneTheme.of(WeatherScene.rain),
        SceneTheme.of(WeatherScene.rain),
      ),
      isTrue,
    );
    expect(
      identical(
        SceneTheme.of(WeatherScene.rain, isDay: false),
        SceneTheme.of(WeatherScene.rain, isDay: false),
      ),
      isTrue,
    );
    // Canh *Day/*Night bo qua isDay.
    expect(
      identical(
        SceneTheme.of(WeatherScene.clearDay, isDay: false),
        SceneTheme.of(WeatherScene.clearDay),
      ),
      isTrue,
    );
  });
}
