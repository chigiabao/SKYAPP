import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../ui/weather/widgets/ios_page.dart';

/// Trang Cai dat (va moi trang con): nen canh toi + kinh nhu cac man khac,
/// tieu de lon iOS, danh sach inset-grouped (the bo 12, duong ke thut vao
/// sau icon, hang sang nhe khi nhan).
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.childrenBuilder,
  });

  final String title;
  final List<Widget> Function(BuildContext) childrenBuilder;

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  /// Theme kinh + quy uoc danh sach iOS cho noi dung Cai dat.
  static ThemeData groupedTheme(BuildContext context) {
    final base = Theme.of(context);
    final ink = GlassInk.of(context);
    return base.copyWith(
      highlightColor: Palette.rowPressed,
      // Chu phu (tieu de nhom, ghi chu, chan trang) phan lon nam thang tren
      // nen canh -> mau chu phu cua dau trang (>= 4.5:1 tren nen).
      textTheme: base.textTheme.copyWith(
        bodySmall: base.textTheme.bodySmall?.copyWith(
          color: ink.headerSecondary,
        ),
      ),
      cardTheme: base.cardTheme.copyWith(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.group),
          side: const BorderSide(color: Palette.border, width: 0.5),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minTileHeight: 52,
        minVerticalPadding: 10,
        horizontalTitleGap: 12,
        textColor: Palette.white,
        iconColor: Palette.white,
        titleTextStyle: TypeScale.iosBody.copyWith(
          fontFamily: TypeScale.family,
          color: Palette.white,
        ),
        subtitleTextStyle: TypeScale.subhead.copyWith(
          fontFamily: TypeScale.family,
          color: ink.secondary,
        ),
        leadingAndTrailingTextStyle: TypeScale.iosBody.copyWith(
          fontFamily: TypeScale.family,
          color: ink.secondary,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Palette.divider,
        thickness: 0.5,
        space: 0.5,
        indent: 58,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Palette.white,
          minimumSize: const Size(Touch.min, Touch.min),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) => Theme(
    data: groupedTheme(context),
    child: Builder(
      builder: (context) => IosPageScaffold(
        title: title,
        scrollKey: PageStorageKey(title),
        children: childrenBuilder(context),
      ),
    ),
  );
}
