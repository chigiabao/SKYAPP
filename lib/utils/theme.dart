import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/weather/design_tokens.dart';

class AppTheme {
  static final ThemeData lightTheme = _build(Brightness.light);
  static final ThemeData darkTheme = _build(Brightness.dark);

  /// Chuyen trang iOS (truot ngang + vuot tu mep trai de quay lai) cho moi
  /// nen tang; tat hieu ung khi bat giam chuyen dong.
  static const PageTransitionsTheme pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: _WeatherPageTransitionsBuilder(),
      TargetPlatform.fuchsia: _WeatherPageTransitionsBuilder(),
      TargetPlatform.iOS: _WeatherPageTransitionsBuilder(),
      TargetPlatform.linux: _WeatherPageTransitionsBuilder(),
      TargetPlatform.macOS: _WeatherPageTransitionsBuilder(),
      TargetPlatform.windows: _WeatherPageTransitionsBuilder(),
    },
  );

  /// Toan bo kieu chu Cupertino (nut, thanh dieu huong, tab, picker) dung
  /// CUNG ho chu cua app. Mac dinh Flutter dung 'CupertinoSystemText' +
  /// letterSpacing am; tren web khong co font nay -> chu roi ve font du phong
  /// hep, lech voi phan con lai.
  static CupertinoTextThemeData cupertinoTextTheme({
    required Color primary,
    required Color foreground,
    required Color secondary,
  }) {
    final text = TextStyle(
      inherit: false,
      fontFamily: TypeScale.family,
      fontSize: 17,
      letterSpacing: 0,
      color: foreground,
      decoration: TextDecoration.none,
    );
    final display = text.copyWith(fontFamily: TypeScale.displayFamily);
    return CupertinoTextThemeData(
      primaryColor: primary,
      textStyle: text,
      actionTextStyle: text.copyWith(color: primary),
      actionSmallTextStyle: text.copyWith(fontSize: 15, color: primary),
      tabLabelTextStyle: text
          .merge(TypeScale.tabLabel)
          .copyWith(color: secondary),
      navTitleTextStyle: text.merge(TypeScale.headline),
      navLargeTitleTextStyle: display.merge(TypeScale.largeTitle),
      navActionTextStyle: text.copyWith(color: primary),
      pickerTextStyle: display.copyWith(fontSize: 21),
      dateTimePickerTextStyle: display.copyWith(fontSize: 21),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? SystemColors.surfaceDark : Colors.white;
    final foreground = dark ? Colors.white : SystemColors.label;
    final secondary = dark
        ? SystemColors.secondaryLabelDark
        : SystemColors.secondaryLabelLight;
    final accent = dark ? SystemColors.accentDark : SystemColors.accentLight;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      // Ngon ngu thiet ke iOS tren MOI nen tang (ca web/Android): cuon nay
      // bat, nut quay lai iOS, RefreshIndicator.adaptive, Switch.adaptive...
      platform: TargetPlatform.iOS,
      fontFamily: TypeScale.family,
      // Web/desktop mac dinh VisualDensity.compact + shrinkWrap -> nut
      // 40 px. Giu vung cham >= 48 px tren moi nen tang.
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        primary: accent,
        surface: surface,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark
          ? SystemColors.backgroundDark
          : SystemColors.groupedBackground,
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: accent,
        scaffoldBackgroundColor: surface,
        textTheme: cupertinoTextTheme(
          primary: accent,
          foreground: foreground,
          secondary: secondary,
        ),
      ),
      // Nut quay lai kieu iOS (chevron) ca tren web, noi Flutter mac dinh
      // dung mui ten Material.
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const Icon(CupertinoIcons.back),
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      pageTransitionsTheme: pageTransitions,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: foreground,
        titleTextStyle: base.textTheme.titleMedium!.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: foreground,
          letterSpacing: 0,
        ),
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
      ),
      textTheme: base.textTheme
          .apply(bodyColor: foreground, displayColor: foreground)
          .copyWith(
            bodySmall: base.textTheme.bodySmall!.copyWith(color: secondary),
          ),
      iconTheme: IconThemeData(color: foreground, size: 22),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: accent,
          foregroundColor: dark ? SystemColors.onAccentDark : Colors.white,
          minimumSize: const Size(48, 48),
          shape: shape,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: shape,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 12,
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? SystemColors.separatorDark : SystemColors.separatorLight,
        thickness: 0.5,
        space: 0.5,
      ),
    );
  }
}

class _WeatherPageTransitionsBuilder extends CupertinoPageTransitionsBuilder {
  const _WeatherPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return super.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
