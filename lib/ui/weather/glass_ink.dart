/// Mau chu / nhan da KIEM TUONG PHAN cho tung canh.
///
/// Tinh tren mau thuc te sau khi chong lop (gradient + overlay + toi da
/// [SceneTheme.maxCloudOverlap] lop may + scrim + kinh), o moi vi tri doc:
///   * chu phu / tieu de the: alpha trang nho nhat (tu muc mong muon) dat
///     >= 4.5:1; canh qua sang thi tang toi 1.0;
///   * mau nhan (accent, mua, canh bao): pha dan voi trang den khi dat 4.5:1;
///   * dau trang (chu nam thang tren nen, khong co kinh): lop toi
///     [headerScrim] du de chu trang nho dat 4.5:1 o 40 % tren man hinh.
library;

import 'package:flutter/widgets.dart';

import 'app_scene.dart';
import 'design_tokens.dart';
import 'weather_scene.dart';

const double kMinTextContrast = 4.5;

@immutable
class GlassInk {
  const GlassInk._({
    required this.secondary,
    required this.title,
    required this.accent,
    required this.rain,
    required this.warning,
    required this.alert,
    required this.headerScrim,
    required this.headerSecondary,
  });

  /// Chu phu tren the kinh.
  final Color secondary;

  /// Tieu de nho viet hoa cua the.
  final Color title;

  /// Mau nhan cua canh (lien ket, muc dang chon) - da du tuong phan.
  final Color accent;

  /// Chu "mua" tren kinh.
  final Color rain;

  /// Chu canh bao nhe (vd. "Dữ liệu cũ") tren kinh.
  final Color warning;

  /// Mau amber cua canh bao (icon, vach) - >= 3:1 tren kinh.
  final Color alert;

  /// Alpha lop den sau dau trang.
  final double headerScrim;

  /// Chu phu cua dau trang (tren nen + [headerScrim]).
  final Color headerSecondary;

  static final Map<SceneTheme, GlassInk> _cache = {};

  /// Mau cho canh dang hien.
  static GlassInk of(BuildContext context) =>
      forTheme(AppScene.of(context).theme);

  static GlassInk forTheme(SceneTheme th) => _cache[th] ??= _compute(th);

  /// Cac mau nen (sau chong lop) phia sau chu trong the kinh.
  static List<Color> cardBackdrops(SceneTheme th) => [
    for (int i = 0; i <= 20; i++)
      for (int c = 0; c <= th.maxCloudOverlap; c++)
        th.cardBackdropAt(i / 20, cloudLayers: c),
  ];

  /// Nen phia sau dau trang (40 % tren man hinh) da phu [scrim].
  static List<Color> headerBackdrops(SceneTheme th, double scrim) => [
    for (int i = 0; i <= 8; i++)
      for (int c = 0; c <= th.maxCloudOverlap; c++)
        Color.alphaBlend(
          const Color(0xFF000000).withValues(alpha: scrim),
          th.backdropAt(i / 20, cloudLayers: c),
        ),
  ];

  static double worstContrast(Color fg, List<Color> backs) {
    double worst = double.infinity;
    for (final Color b in backs) {
      final double r = SceneTheme.contrastRatio(Color.alphaBlend(fg, b), b);
      if (r < worst) worst = r;
    }
    return worst;
  }

  static Color _whiteAlpha(double from, List<Color> backs) {
    for (double a = from; a < 1.0; a += 0.05) {
      final Color c = const Color(0xFFFFFFFF).withValues(alpha: a);
      if (worstContrast(c, backs) >= kMinTextContrast) return c;
    }
    return const Color(0xFFFFFFFF);
  }

  static Color _towardWhite(
    Color base,
    List<Color> backs, [
    double min = kMinTextContrast,
  ]) {
    for (double t = 0; t < 1.0; t += 0.05) {
      final Color c = Color.lerp(base, const Color(0xFFFFFFFF), t)!;
      if (worstContrast(c, backs) >= min) return c;
    }
    return const Color(0xFFFFFFFF);
  }

  static GlassInk _compute(SceneTheme th) {
    final List<Color> card = cardBackdrops(th);
    double scrim = 0;
    for (final double s in const [0.0, 0.1, 0.2, 0.3, 0.4]) {
      scrim = s;
      if (worstContrast(Palette.white, headerBackdrops(th, s)) >=
          kMinTextContrast) {
        break;
      }
    }
    return GlassInk._(
      secondary: _whiteAlpha(Opacities.secondary, card),
      title: _whiteAlpha(Opacities.title, card),
      accent: _towardWhite(th.accent, card),
      rain: _towardWhite(Palette.rain, card),
      warning: _towardWhite(Palette.stale, card),
      alert: _towardWhite(Palette.alert, card, 3.0),
      headerScrim: scrim,
      headerSecondary: _whiteAlpha(
        Opacities.secondary,
        headerBackdrops(th, scrim),
      ),
    );
  }
}
