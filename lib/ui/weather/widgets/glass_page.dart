/// Khung chung cho cac man hinh phu (chi tiet du bao, kiem chung AI, cai dat):
/// nen canh thoi tiet hien tai + theme kinh (chu trang, the kinh).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utils/constants.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_background.dart';
import 'glass_card.dart';

/// Theme cua app (sang/toi theo Cai dat) truoc khi bi theme kinh ghi de.
/// Hop thoai / o nhap dung theme nay de cai dat giao dien van co tac dung.
class AppThemeScope extends InheritedWidget {
  const AppThemeScope({super.key, required this.theme, required super.child});

  final ThemeData theme;

  static ThemeData? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppThemeScope>()?.theme;

  /// Boc noi dung hop thoai bang theme cua app (dung trong `builder:` cua
  /// showDialog / showDatePicker).
  static Widget wrapDialog(BuildContext context, Widget child) {
    final ThemeData? t = maybeOf(context);
    return t == null ? child : Theme(data: t, child: child);
  }

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) => oldWidget.theme != theme;
}

/// Danh dau theme kinh (widget dung chung nhu SourceTag doi sang chu trang).
class GlassThemeMarker extends ThemeExtension<GlassThemeMarker> {
  const GlassThemeMarker(this.ink);

  final GlassInk ink;

  static bool isGlass(BuildContext context) =>
      Theme.of(context).extension<GlassThemeMarker>() != null;

  /// Mau chu cua canh, null neu khong o tren nen kinh.
  static GlassInk? inkOf(BuildContext context) =>
      Theme.of(context).extension<GlassThemeMarker>()?.ink;

  @override
  GlassThemeMarker copyWith({GlassInk? ink}) =>
      GlassThemeMarker(ink ?? this.ink);

  @override
  GlassThemeMarker lerp(GlassThemeMarker? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

/// Theme cho noi dung nam tren nen canh: nen trong suot, chu trang, the =
/// mau kinh cua canh (SceneTheme.glassColor), vien trang mo, bo goc 22.
ThemeData glassThemeFor(SceneTheme scene, ThemeData appTheme) {
  final key = (scene, appTheme.brightness);
  return _glassCache[key] ??= _buildGlassTheme(scene, appTheme);
}

final Map<(SceneTheme, Brightness), ThemeData> _glassCache = {};

ThemeData _buildGlassTheme(SceneTheme scene, ThemeData appTheme) {
  final GlassInk ink = GlassInk.forTheme(scene);
  final ThemeData base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: TypeScale.family,
    colorScheme: ColorScheme.dark(
      primary: ink.accent,
      onPrimary: const Color(0xFF0B1F33),
      secondary: AppColors.accentLight,
      surface: const Color(0xFF1B2333),
      error: const Color(0xFFFFB4A9),
    ),
  );
  const TextStyle w = TextStyle(color: Palette.white);
  final TextStyle s = TextStyle(color: ink.secondary);
  return base.copyWith(
    extensions: [GlassThemeMarker(ink)],
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Palette.white,
      systemOverlayStyle: scene.statusBar,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scene.glassColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassSpec.radius),
        side: const BorderSide(color: Palette.border),
      ),
    ),
    iconTheme: const IconThemeData(color: Palette.white),
    textTheme: base.textTheme
        .apply(bodyColor: Palette.white, displayColor: Palette.white)
        .copyWith(
          bodySmall: base.textTheme.bodySmall?.merge(s),
          labelSmall: base.textTheme.labelSmall?.merge(s),
          titleLarge: base.textTheme.titleLarge?.merge(w),
        ),
    dividerTheme: const DividerThemeData(color: Palette.divider, thickness: 1),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 12,
      textColor: Palette.white,
      iconColor: Palette.white,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Colors.white,
      linearTrackColor: Color(0x33FFFFFF),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0B1F33),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.borderRadiusS),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Color(0x80FFFFFF)),
        minimumSize: const Size(44, 44),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : const Color(0xFFCFD8DC),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Color(0xFF34C759)
            : const Color(0x55FFFFFF),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Color(0x80FFFFFF)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xFF0B1F33)
              : Colors.white,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : Colors.transparent,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: Color(0x80FFFFFF)),
        ),
      ),
    ),
    snackBarTheme: appTheme.snackBarTheme,
    // Hop thoai / date picker dung theme cua app (xem AppThemeScope).
    dialogTheme: appTheme.dialogTheme,
    datePickerTheme: appTheme.datePickerTheme,
  );
}

/// Nen canh + theme kinh cho mot man hinh phu. [child] thuong la Scaffold
/// (nen trong suot nho theme).
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppSceneData data = AppScene.of(context);
    final SceneTheme st = data.theme;
    final ThemeData appTheme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: st.statusBar,
      child: AppThemeScope(
        theme: AppThemeScope.maybeOf(context) ?? appTheme,
        child: ColoredBox(
          color: st.gradient.last,
          child: WeatherBackground(
            scene: data.scene,
            isDay: data.isDay,
            windSpeedKmh: data.windSpeedKmh,
            intensity: data.intensity,
            // Thanh tieu de co nut o ben phai -> than sang mo (35 %).
            celestial: CelestialPlacement.topRight(
              MediaQuery.sizeOf(context).width,
              top: MediaQuery.paddingOf(context).top,
              opacity: 0.35,
            ),
            child: Theme(
              data: _withContrast(
                glassThemeFor(st, appTheme),
                st,
                MediaQuery.maybeHighContrastOf(context) ?? false,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tuong phan cao: the (Card) dac va toi hon, vien ro (cung quy tac voi
/// GlassSurface).
ThemeData _withContrast(ThemeData t, SceneTheme st, bool on) {
  if (!on) return t;
  final Color g = st.glassColor;
  return t.copyWith(
    cardTheme: t.cardTheme.copyWith(
      color: Color.alphaBlend(
        const Color(0x59000000),
        g.withValues(alpha: g.a < 0.8 ? 0.8 : g.a),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassSpec.radius),
        side: const BorderSide(color: Palette.secondary, width: 1.5),
      ),
    ),
  );
}
