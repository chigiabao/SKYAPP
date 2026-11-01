/// Khung man hinh phu kieu iOS: tieu de lon 34 pt thu lai thanh tieu de
/// 17 pt dam + nen mo (blur) khi cuon, keo-de-lam-moi kieu iOS, noi dung
/// can giua toi da [Space.contentMaxWidth] tren man rong.
///
/// Giam chuyen dong: thanh tieu de tinh (17 pt) - khong co tieu de lon thu
/// gian theo cuon va khong bay tieu de giua cac trang.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';

/// Le ngang cua noi dung (16, hoac can giua cot 640 tren man rong).
double iosPageHPad(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width > Space.contentMaxWidth + 2 * Space.l
      ? (width - Space.contentMaxWidth) / 2
      : Space.l;
}

class IosPageScaffold extends StatelessWidget {
  const IosPageScaffold({
    super.key,
    required this.title,
    this.actions = const [],
    this.children,
    this.slivers,
    this.onRefresh,
    this.controller,
    this.scrollKey,
    this.leading,
    this.largeTitle = true,
    this.padding,
    this.bottomBar,
  }) : assert((children == null) != (slivers == null));

  final String title;

  /// Nut ben phai thanh tieu de (moi nut >= 44 pt).
  final List<Widget> actions;

  /// Noi dung dang danh sach (boc trong SliverList co le ngang).
  final List<Widget>? children;

  /// Hoac sliver tu dung (khong them le).
  final List<Widget>? slivers;

  /// Bat keo-de-lam-moi kieu iOS.
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  final Key? scrollKey;
  final Widget? leading;

  /// false: chi thanh tieu de 17 pt (vd. ban do toan man hinh).
  final bool largeTitle;

  /// Le cho [children]; mac dinh ngang [iosPageHPad], tren 8, duoi 32.
  final EdgeInsets? padding;

  /// Thanh co dinh duoi man hinh (vd. nut gui).
  final Widget? bottomBar;

  static Widget _trailing(List<Widget> actions) => actions.isEmpty
      ? const SizedBox.shrink()
      : Row(mainAxisSize: MainAxisSize.min, children: actions);

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final hPad = iosPageHPad(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Man rong: tieu de lon thang hang voi cot noi dung.
    final EdgeInsetsDirectional? barPad = hPad > Space.l
        ? EdgeInsetsDirectional.only(
            start: math.max(Space.l, hPad - Space.s),
            end: math.max(Space.l, hPad - Space.s),
          )
        : null;
    final Widget titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final Widget? trailing = actions.isEmpty ? null : _trailing(actions);
    // Nut quay lai iOS (chevron) co nhan tieng Viet cho VoiceOver / tooltip.
    final Widget? back =
        leading ??
        (ModalRoute.of(context)?.impliesAppBarDismissal ?? false
            ? const IosBackButton()
            : null);

    final content = <Widget>[
      if (onRefresh != null)
        CupertinoSliverRefreshControl(onRefresh: onRefresh),
      if (slivers != null)
        ...slivers!
      else
        SliverPadding(
          padding:
              padding ??
              EdgeInsets.fromLTRB(
                hPad,
                Space.s,
                hPad,
                Space.xxl + (bottomBar == null ? bottomInset : 0),
              ),
          sliver: SliverList(delegate: SliverChildListDelegate(children!)),
        ),
    ];

    final bool large = largeTitle && !still;
    final scroll = CustomScrollView(
      key: scrollKey,
      controller: controller,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        if (large)
          CupertinoSliverNavigationBar(
            key: const ValueKey('ios-large-title-bar'),
            // Tieu de dai: thu nho toi da xuong ~28 pt, sau do cat "...";
            // chua le phai bang le trai (khong cham mep man hinh).
            largeTitle: IosLargeTitle(title),
            middle: titleText,
            alwaysShowMiddle: false,
            leading: back,
            automaticallyImplyLeading: false,
            trailing: trailing,
            padding: barPad,
            backgroundColor: Palette.navBar,
            border: const Border(
              bottom: BorderSide(color: Palette.divider, width: 0.5),
            ),
          ),
        ...content,
      ],
    );

    // Tieu de nam tren nen canh: lop toi nhe [GlassInk.headerScrim] (tinh
    // san de chu trang >= 4.5:1 tren moi canh); nen mo + blur dam hon chi
    // hien khi noi dung cuon xuong duoi thanh (giong iOS 15+).
    final double scrim = GlassInk.of(context).headerScrim;
    return CupertinoPageScaffoldBackgroundColor(
      color: Color.fromRGBO(0, 0, 0, scrim),
      child: Scaffold(
        backgroundColor: Palette.pageDim,
        appBar: large
            ? null
            : CupertinoNavigationBar(
                key: const ValueKey('ios-inline-bar'),
                middle: titleText,
                leading: back,
                automaticallyImplyLeading: false,
                trailing: trailing,
                padding: barPad,
                transitionBetweenRoutes: !still,
                automaticBackgroundVisibility: largeTitle,
                backgroundColor: Palette.navBar,
                border: const Border(
                  bottom: BorderSide(color: Palette.divider, width: 0.5),
                ),
              ),
        body: scroll,
        bottomNavigationBar: bottomBar,
      ),
    );
  }
}

/// Tieu de lon 34 pt: le phai = le trai (16), thu nho khi qua dai nhung
/// khong duoi [minFontSize]; van dai thi cat "..." (ten day du o thanh 17 pt
/// va trinh doc man hinh).
class IosLargeTitle extends StatelessWidget {
  const IosLargeTitle(this.title, {super.key});

  final String title;

  /// Co chu nho nhat truoc khi cat (HIG: tieu de lon khong nen qua nho).
  static const double minFontSize = 28;

  /// Le trai cua tieu de lon trong CupertinoSliverNavigationBar.
  static const double edgeInset = 16;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: edgeInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = base.fontSize ?? 34;
          final painter = TextPainter(
            text: TextSpan(text: title, style: base),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final width = painter.width;
          painter.dispose();
          final fit = width <= constraints.maxWidth || width == 0
              ? 1.0
              : constraints.maxWidth / width;
          final fontSize = math.max(math.min(size, minFontSize), size * fit);
          return Text(
            title,
            key: const ValueKey('ios-large-title'),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(fontSize: fontSize),
          );
        },
      ),
    );
  }
}

/// Nut quay lai: chevron iOS, vung cham 44, nhan "Quay lại".
class IosBackButton extends StatelessWidget {
  const IosBackButton({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Quay lại',
    excludeFromSemantics: true,
    child: Semantics(
      container: true,
      button: true,
      label: 'Quay lại',
      excludeSemantics: true,
      child: CupertinoButton(
        key: const ValueKey('ios-back'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Icon(CupertinoIcons.back, size: 28, color: Palette.white),
      ),
    ),
  );
}

/// Nut bieu tuong tren thanh tieu de iOS (44 pt, co nhan cho VoiceOver).
class IosBarButton extends StatelessWidget {
  const IosBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    excludeFromSemantics: true,
    child: Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      excludeSemantics: true,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: onPressed,
        child: Icon(icon, size: 24, color: Palette.white),
      ),
    ),
  );
}

/// Nut chu tren thanh tieu de (vd. "So sánh", "Xong").
class IosBarTextButton extends StatelessWidget {
  const IosBarTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.bold = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool bold;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: Space.s),
    minimumSize: const Size(44, 44),
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ExcludeSemantics(child: Icon(icon, size: 20, color: Palette.white)),
          const SizedBox(width: Space.xs),
        ],
        Text(
          label,
          style: TextStyle(
            fontFamily: TypeScale.family,
            fontSize: TypeScale.iosBody.fontSize,
            letterSpacing: 0,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: onPressed == null ? Palette.highlight : Palette.white,
          ),
        ),
      ],
    ),
  );
}
