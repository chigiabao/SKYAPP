import 'package:flutter/material.dart';

import '../ui/weather/design_tokens.dart';
import '../ui/weather/widgets/glass_page.dart';

/// Mau phu thuoc ngu canh (nen kinh / sang / toi). Gia tri mau nam trong
/// design_tokens.dart ([Tones], [Palette]); lop nay chi chon mau theo nen.
abstract final class AppColors {
  /// Chu/icon "mua": tren kinh lay mau da kiem tuong phan cua canh
  /// (GlassInk); xanh dam tren nen sang (>= 4.5:1), xanh nhat tren nen toi.
  static Color rainyText(BuildContext context) =>
      GlassThemeMarker.inkOf(context)?.rain ??
      (Theme.of(context).brightness == Brightness.dark
          ? Tones.rainOnDark
          : Tones.rainOnLight);

  // Mau icon chi so: dat >= 3:1 (non-text, WCAG 1.4.11) tren nen the.
  static Color statIcon(BuildContext context, StatTone tone) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (tone) {
      case StatTone.water:
        return dark ? Tones.rainOnDark : Tones.rainOnLight;
      case StatTone.air:
        return dark ? Tones.airOnDark : Tones.airOnLight;
      case StatTone.pressure:
        return dark ? Tones.pressureOnDark : Tones.pressureOnLight;
      case StatTone.warm:
        return dark ? Tones.warmOnDark : Tones.warmOnLight;
      case StatTone.neutral:
        return dark ? Tones.neutralOnDark : Tones.neutralOnLight;
    }
  }
}

enum StatTone { water, air, pressure, warm, neutral }
