import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/ui/weather/glass_ink.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';

/// Kiem tuong phan tren mau DA CHONG LOP (canh + may + scrim + kinh) cho moi
/// canh, ca ngay va dem, o moi vi tri doc.
void main() {
  for (final s in WeatherScene.values) {
    for (final isDay in [true, false]) {
      test('${s.name}/${isDay ? 'ngay' : 'dem'}', () {
        final th = SceneTheme.of(s, isDay: isDay);
        final ink = GlassInk.forTheme(th);
        final card = GlassInk.cardBackdrops(th);
        for (final (name, c) in [
          ('chinh', Palette.white),
          ('phu', ink.secondary),
          ('tieu de', ink.title),
          ('nhan', ink.accent),
          ('mua', ink.rain),
          ('canh bao', ink.warning),
        ]) {
          expect(
            GlassInk.worstContrast(c, card),
            greaterThanOrEqualTo(kMinTextContrast),
            reason: 'chu $name tren the kinh',
          );
        }
        // Icon / vach amber cua canh bao tren kinh: >= 3:1 (khong phai chu).
        expect(
          GlassInk.worstContrast(ink.alert, card),
          greaterThanOrEqualTo(3.0),
          reason: 'amber canh bao',
        );
        final header = GlassInk.headerBackdrops(th, ink.headerScrim);
        expect(
          GlassInk.worstContrast(Palette.white, header),
          greaterThanOrEqualTo(kMinTextContrast),
          reason: 'dau trang (chu trang)',
        );
        expect(
          GlassInk.worstContrast(ink.headerSecondary, header),
          greaterThanOrEqualTo(kMinTextContrast),
          reason: 'dau trang (chu phu)',
        );
      });
    }
  }

  test('canh bao: chu toi tren amber', () {
    expect(
      SceneTheme.contrastRatio(Palette.onAlert, Palette.alert),
      greaterThanOrEqualTo(kMinTextContrast),
    );
  });

  test('canh toi giu duoc phan cap (chu phu < 1.0)', () {
    final ink = GlassInk.forTheme(SceneTheme.of(WeatherScene.clearNight));
    expect(ink.secondary.a, lessThan(1.0));
    expect(const Color(0xFFFFFFFF).a, 1.0);
  });
}
