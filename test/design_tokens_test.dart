import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/utils/constants.dart';

/// design_tokens.dart la nguon mau / kich thuoc duy nhat: man hinh va widget
/// khong viet tay ma mau hex, va bang mau cu (AppColors / AppSizes /
/// AppTextStyles) da gop vao token voi CUNG gia tri.
void main() {
  test('screens and widgets use tokens instead of hex Color literals', () {
    final hex = RegExp(r'Color\(0x[0-9A-Fa-f]{8}\)');
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final f in Directory(dir).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (hex.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'Add a token to design_tokens.dart');
  });

  test('legacy constants.dart no longer defines a second token system', () {
    final src = File('lib/utils/constants.dart').readAsStringSync();
    expect(src, isNot(contains('class AppSizes')));
    expect(src, isNot(contains('class AppTextStyles')));
    expect(src, isNot(contains('Color(0x')));
  });

  test('merged tokens keep the previous values', () {
    // Kich thuoc cu (AppSizes) -> Space / Radii / IconSizes.
    expect(
      [Space.xs, Space.s, Space.l, Space.xl, Space.xxl],
      [4, 8, 16, 24, 32],
    );
    expect([Radii.small, Radii.medium, Radii.large], [8, 16, 24]);
    expect([IconSizes.inline, IconSizes.row, IconSizes.state], [20, 28, 48]);
    expect(Touch.min, 48);

    // Kieu chu cu (AppTextStyles) -> TypeScale.
    expect(TypeScale.heading2.fontSize, 20);
    expect(TypeScale.heading3.fontWeight, FontWeight.w600);
    expect(TypeScale.caption.letterSpacing, 0.3);
    expect(TypeScale.bodySmall.height, isNull);

    // Mau cu (AppColors) -> Tones.
    expect(Tones.brandDeep, const Color(0xFF1976D2));
    expect(Tones.airOnLight, Tones.brandDeep);
    expect(Tones.rainOnLight, const Color(0xFF0277BD));
    expect(Palette.onAlert, Palette.ink);
    expect(DataColors.rainScale, hasLength(5));
    expect(DataColors.windScale, hasLength(5));
  });

  testWidgets('AppColors helpers pick tones by brightness', (tester) async {
    late Color lightRain, darkRain, lightWarm, darkWarm;
    // Theme truc tiep (khong qua MaterialApp/AnimatedTheme dang chuyen dan).
    Widget probe(Brightness b, void Function(BuildContext) read) => Theme(
      data: ThemeData(brightness: b),
      child: Builder(
        builder: (context) {
          read(context);
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(
      probe(Brightness.light, (c) {
        lightRain = AppColors.rainyText(c);
        lightWarm = AppColors.statIcon(c, StatTone.warm);
      }),
    );
    await tester.pumpWidget(
      probe(Brightness.dark, (c) {
        darkRain = AppColors.rainyText(c);
        darkWarm = AppColors.statIcon(c, StatTone.warm);
      }),
    );
    expect(lightRain, Tones.rainOnLight);
    expect(darkRain, Tones.rainOnDark);
    expect(lightWarm, Tones.warmOnLight);
    expect(darkWarm, Tones.warmOnDark);
  });
}
