import 'package:flutter/material.dart';

import '../ui/weather/widgets/glass_page.dart';

// Primary colors - Blue gradient theme
class AppColors {
  // Light theme colors
  static const Color primaryLight = Color(0xFF2196F3);
  static const Color primaryDark = Color(0xFF1976D2);
  static const Color accentLight = Color(0xFF64B5F6);

  // Dark theme colors
  static const Color darkBackground = Color(0xFF1A1A2E);
  static const Color darkSurface = Color(0xFF16213E);
  static const Color darkCard = Color(0xFF1F3460);

  // Common colors
  static const Color white = Colors.white;
  static const Color textLight = Color(0xFF424242);
  static const Color textDark = Color(0xFFE0E0E0);
  static const Color textSecondary = Color(0xFF9E9E9E);

  // Weather condition colors
  static const Color sunny = Color(0xFFFFB74D);
  static const Color rainy = Color(0xFF4FC3F7);
  static const Color cloudy = Color(0xFF90A4AE);
  static const Color stormy = Color(0xFF7E57C2);

  // Mau chu/icon "mua" du tuong phan: xanh dam tren nen sang (>= 4.5:1),
  // xanh nhat tren nen toi.
  static const Color rainyTextLight = Color(0xFF0277BD);

  /// Tren nen kinh: mau mua da kiem tuong phan cua canh (GlassInk).
  static Color rainyText(BuildContext context) =>
      GlassThemeMarker.inkOf(context)?.rain ??
      (Theme.of(context).brightness == Brightness.dark
          ? rainy
          : rainyTextLight);

  // Chu phu (caption) tren nen sang: #6B6B6B ~ 5:1 tren trang
  static const Color textSecondaryLight = Color(0xFF6B6B6B);

  // Chart colors
  static const Color chartLine = Color(0xFF42A5F5);
  static const Color chartFill = Color(0x3342A5F5);
  static const Color precipitationBar = Color(0xFF4FC3F7);

  // Gradient for backgrounds
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [primaryLight, primaryDark],
  );

  static const LinearGradient darkGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [darkSurface, darkBackground],
  );

  // The thoi tiet chinh (sang): dam hon primaryLight de chu trang/caption
  // dat AA (trang tren #1976D2 ~ 4.6:1).
  static const LinearGradient heroLightGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryDark, Color(0xFF1259B0)],
  );

  // Chu phu tren the thoi tiet chinh (thay cho white70 qua mo).
  static const Color onHeroSecondary = Color(0xF2FFFFFF);

  // The thoi tiet chinh trong che do toi: xanh cham sang hon nen (#1A1A2E)
  // va the (#1F3460) de tach khoi nen; chu trang dat >= 7:1.
  static const LinearGradient heroDarkGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2E5AAC), Color(0xFF223F7A)],
  );

  // Mau icon chi so: dat >= 3:1 (non-text, WCAG 1.4.11) tren nen the.
  static Color statIcon(BuildContext context, StatTone tone) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (tone) {
      case StatTone.water:
        return dark ? rainy : rainyTextLight; // #4FC3F7 / #0277BD
      case StatTone.air:
        return dark ? const Color(0xFF90CAF9) : primaryDark; // #1976D2
      case StatTone.pressure:
        return dark ? const Color(0xFFB39DDB) : const Color(0xFF5E35B1);
      case StatTone.warm:
        return dark ? const Color(0xFFFFB74D) : const Color(0xFFC2410C);
      case StatTone.neutral:
        return dark ? const Color(0xFFB0BEC5) : const Color(0xFF546E7A);
    }
  }
}

enum StatTone { water, air, pressure, warm, neutral }

// Sizes and spacing
class AppSizes {
  static const double paddingXS = 4.0;
  static const double paddingS = 8.0;
  static const double paddingM = 16.0;
  static const double paddingL = 24.0;
  static const double paddingXL = 32.0;

  static const double borderRadius = 16.0;
  static const double borderRadiusS = 8.0;
  static const double borderRadiusL = 24.0;

  static const double iconSizeS = 20.0;
  static const double iconSizeM = 28.0;
  static const double iconSizeL = 48.0;
  static const double iconSizeXL = 80.0;

  static const double cardElevation = 4.0;

  // Touch target minimum (accessibility)
  static const double minTouchTarget = 44.0;
}

// Text styles
class AppTextStyles {
  static const TextStyle temperatureLarge = TextStyle(
    fontSize: 72,
    fontWeight: FontWeight.w300,
    letterSpacing: -2,
  );

  static const TextStyle temperatureMedium = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle temperatureSmall = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle heading1 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle heading2 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle heading3 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.3,
  );
}
