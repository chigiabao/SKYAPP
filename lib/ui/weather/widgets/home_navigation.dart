import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../../../utils/haptics.dart';
import 'glass_card.dart';

/// Cac tab cua thanh tab (thu tu hien thi).
enum HomeTab { today, map, trip, places }

/// iOS tab bar on phones (full width, blurred, hairline top border, safe
/// area aware); a glass rail with the same order on desktop.
class HomeNavigation extends StatelessWidget {
  const HomeNavigation({
    super.key,
    required this.onHome,
    required this.onMap,
    required this.onLocations,
    required this.locationPosition,
    this.onTrip,
    this.rainPercent,
    this.vertical = false,
    this.selected = HomeTab.today,
  });

  /// Tab dang mo (to dam + `selected` cho trinh doc man hinh).
  final HomeTab selected;

  final VoidCallback? onHome;
  final VoidCallback onMap;
  final VoidCallback onLocations;
  final VoidCallback? onTrip;
  final String locationPosition;
  final int? rainPercent;
  final bool vertical;

  /// Chu trong thanh chi phong toi 1.3 lan (nhu tab bar he thong); nhan day
  /// du van co o tooltip / trinh doc man hinh.
  static const double maxTextScale = 1.3;

  /// Base tint; the surface remains translucent except in high contrast.
  static const Color background = Color(0xFF131C24);

  /// Mau nen thanh tab iOS (mo, tren lop lam mo).
  static const Color barTint = Color(0xB8131C24);

  /// Vach mảnh phia tren thanh tab (hairline iOS).
  static const Color hairline = Color(0x33FFFFFF);

  static const double _iconHeight = 26;
  static const double _padV = 4;
  static const double _gap = 2;

  /// Chieu cao toi thieu thanh tab iOS (HIG 49 pt, lam tron 50).
  static const double minHeight = 50;

  static TextStyle get _labelStyle =>
      TypeScale.tabLabel.copyWith(inherit: false, fontFamily: TypeScale.family);

  /// Chieu cao thanh (khong tinh vung an toan): 50, tang nhe khi chu lon.
  static double heightFor(double width, TextScaler scaler) {
    final s = scaler.clamp(maxScaleFactor: maxTextScale);
    final label =
        s.scale(TypeScale.tabLabel.fontSize!) * TypeScale.tabLabel.height!;
    return math.max(
      minHeight,
      (2 * _padV + _iconHeight + _gap + label).ceilToDouble(),
    );
  }

  /// Khoang trong can chua o day moi danh sach cuon phia sau thanh tab:
  /// chieu cao thanh + vung an toan (home indicator) + nhip [Space.l].
  static double reservedHeight(BuildContext context) {
    final mq = MediaQuery.of(context);
    return heightFor(mq.size.width, mq.textScaler) +
        mq.padding.bottom +
        Space.l;
  }

  @override
  Widget build(BuildContext context) {
    final destinations = <Widget>[
      _NavigationItem(
        icon: CupertinoIcons.cloud_sun_fill,
        label: 'Hôm nay',
        tooltip: 'Thời tiết hôm nay',
        selected: selected == HomeTab.today,
        onTap: onHome,
      ),
      _NavigationItem(
        icon: CupertinoIcons.map,
        label: 'Bản đồ',
        tooltip: 'Bản đồ',
        selected: selected == HomeTab.map,
        onTap: onMap,
      ),
      if (onTrip != null)
        _NavigationItem(
          icon: CupertinoIcons.location,
          label: 'Ra ngoài',
          tooltip: 'Tôi sắp ra ngoài',
          selected: selected == HomeTab.trip,
          onTap: onTrip,
          showDot: rainPercent != null,
          semanticsLabel: rainPercent == null
              ? 'Tôi sắp ra ngoài'
              : 'Tôi sắp ra ngoài. Khả năng mưa 2 giờ tới $rainPercent%',
        ),
      _NavigationItem(
        icon: CupertinoIcons.list_bullet,
        label: 'Địa điểm',
        tooltip: 'Danh sách địa điểm',
        selected: selected == HomeTab.places,
        onTap: onLocations,
        semanticsLabel: 'Danh sách địa điểm. $locationPosition',
      ),
    ];
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxTextScale,
      child: Builder(
        builder: (context) {
          final height = heightFor(0, MediaQuery.textScalerOf(context));
          if (vertical) {
            return GlassSurface(
              radius: Radii.tile,
              tint: Color.alphaBlend(
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
                background.withValues(alpha: 0.76),
              ),
              padding: const EdgeInsets.symmetric(horizontal: Space.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: Space.xs),
                  for (final d in destinations)
                    SizedBox(height: math.max(height, 64), child: d),
                  const SizedBox(height: Space.xs),
                ],
              ),
            );
          }
          // Thanh tab iOS: tran het chieu ngang, lam mo nen, vach manh phia
          // tren, keo xuong duoi home indicator (vung an toan).
          final hc = MediaQuery.maybeHighContrastOf(context) ?? false;
          final bar = DecoratedBox(
            key: const ValueKey('ios-tab-bar'),
            decoration: BoxDecoration(
              color: hc ? Palette.headerSolid : barTint,
              border: Border(
                top: BorderSide(
                  color: hc ? Palette.secondary : hairline,
                  width: hc ? 1 : 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: height,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final d in destinations) Expanded(child: d),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          if (hc) return bar;
          return ClipRect(
            child: BackdropFilter.grouped(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: bar,
            ),
          );
        },
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.showDot = false,
    this.semanticsLabel,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;

  /// Keep the actual rain percentage in semantics, not a crowded badge.
  final bool showDot;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? Palette.rain : Palette.secondary;
    final tap = onTap == null
        ? null
        : () {
            AppHaptics.selection();
            onTap!();
          };
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: semanticsLabel ?? label,
        onTap: tap,
        excludeSemantics: true,
        child: CupertinoButton(
          onPressed: tap,
          minimumSize: const Size(Touch.min, Touch.min),
          padding: const EdgeInsets.symmetric(vertical: HomeNavigation._padV),
          pressedOpacity: reducedMotion ? 1 : Opacities.pressed,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: HomeNavigation._iconHeight,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(icon, size: 24, color: fg),
                    if (showDot)
                      const Positioned(
                        right: 0,
                        top: 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Palette.rain,
                            shape: BoxShape.circle,
                          ),
                          child: SizedBox.square(dimension: 5),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: HomeNavigation._gap),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: HomeNavigation._labelStyle.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
