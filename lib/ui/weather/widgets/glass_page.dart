/// Khung chung cho cac man hinh phu (chi tiet du bao, kiem chung AI, cai dat):
/// nen canh thoi tiet hien tai + theme kinh (chu trang, the kinh).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scene.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_background.dart';
import '../../../utils/theme.dart';
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
  final ThemeData base = appTheme.copyWith(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.dark(
      primary: ink.accent,
      onPrimary: Palette.onWhite,
      secondary: Tones.brandSoft,
      surface: const Color(0xFF1B2333),
      error: const Color(0xFFFFB4A9),
    ),
  );
  const TextStyle w = TextStyle(color: Palette.white);
  final TextStyle s = TextStyle(color: ink.secondary);
  return base.copyWith(
    cupertinoOverrideTheme: appTheme.cupertinoOverrideTheme?.copyWith(
      brightness: Brightness.dark,
      primaryColor: Palette.white,
      barBackgroundColor: const Color(0xCC20242B),
      // Moi chu Cupertino (tieu de lon, nut thanh dieu huong, picker) trang
      // tren nen canh, ke ca khi app dang o giao dien sang.
      textTheme: AppTheme.cupertinoTextTheme(
        primary: Palette.white,
        foreground: Palette.white,
        secondary: ink.secondary,
      ),
    ),
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
    // Nut Material con lai mang dang iOS: dac trang (chinh), trang mo
    // (phu), chu trang dam (lien ket); bo 12, khong bong, khong gon song.
    elevatedButtonTheme: ElevatedButtonThemeData(style: _iosFilled),
    filledButtonTheme: FilledButtonThemeData(style: _iosFilled),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
        textStyle: TypeScale.headline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Palette.subtleFill,
        side: BorderSide.none,
        minimumSize: const Size(44, 44),
        textStyle: TypeScale.headline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Palette.subtleFill,
      selectedColor: Palette.white,
      disabledColor: Palette.subtleFill,
      checkmarkColor: Palette.onWhite,
      showCheckmark: true,
      side: const BorderSide(color: Palette.border),
      shape: const StadiumBorder(),
      labelStyle: TypeScale.subhead.copyWith(
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.onWhite
              : Palette.white,
        ),
      ),
      secondaryLabelStyle: TypeScale.subhead.copyWith(color: Palette.onWhite),
      iconTheme: const IconThemeData(color: Palette.white, size: 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.subtleFill,
      labelStyle: TextStyle(color: ink.secondary),
      floatingLabelStyle: const TextStyle(color: Palette.white),
      hintStyle: TextStyle(color: ink.secondary),
      helperStyle: TextStyle(color: ink.secondary),
      errorStyle: const TextStyle(color: Palette.dangerOnGlass),
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.m,
        vertical: Space.m,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: const BorderSide(color: Palette.secondary),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: const BorderSide(color: Palette.dangerOnGlass),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: const BorderSide(color: Palette.dangerOnGlass, width: 1.5),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Palette.white,
      selectionColor: Palette.highlight,
      selectionHandleColor: Palette.white,
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
              ? Palette.onWhite
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

final ButtonStyle _iosFilled = ElevatedButton.styleFrom(
  elevation: 0,
  backgroundColor: Colors.white,
  foregroundColor: Palette.onWhite,
  disabledBackgroundColor: Palette.subtleFill,
  disabledForegroundColor: Palette.secondary,
  minimumSize: const Size(44, 48),
  padding: const EdgeInsets.symmetric(horizontal: Space.l + 4),
  textStyle: TypeScale.headline,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.button),
  ),
);

/// Theme Cupertino cua nen kinh (tieu de lon, thanh dieu huong, picker,
/// nut Cupertino): chu trang. Phai dat bang widget [CupertinoTheme] rieng vi
/// [Theme] long nhau dung lai CupertinoTheme cua to tien (bo qua
/// `cupertinoOverrideTheme`).
CupertinoThemeData glassCupertinoTheme(SceneTheme scene) =>
    _cupertinoCache[scene] ??= CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: Palette.white,
      primaryContrastingColor: Palette.onWhite,
      barBackgroundColor: Palette.navBar,
      scaffoldBackgroundColor: const Color(0x00000000),
      textTheme: AppTheme.cupertinoTextTheme(
        primary: Palette.white,
        foreground: Palette.white,
        secondary: GlassInk.forTheme(scene).secondary,
      ),
    );

final Map<SceneTheme, CupertinoThemeData> _cupertinoCache = {};

/// Theme kinh day du (Material + Cupertino) cho mot cay con.
Widget glassThemed(SceneTheme scene, ThemeData appTheme, Widget child) => Theme(
  data: glassThemeFor(scene, appTheme),
  child: CupertinoTheme(data: glassCupertinoTheme(scene), child: child),
);

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
              child: CupertinoTheme(
                data: glassCupertinoTheme(st),
                child: child,
              ),
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
