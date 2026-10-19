import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'glass_card.dart';

/// The same destinations stay in the same order on phone and desktop.
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
  });

  final VoidCallback? onHome;
  final VoidCallback onMap;
  final VoidCallback onLocations;
  final VoidCallback? onTrip;
  final String locationPosition;
  final int? rainPercent;
  final bool vertical;

  static const _labelStyle = TextStyle(
    inherit: false,
    fontFamily: TypeScale.family,
    fontSize: 13,
    height: 1.3,
    letterSpacing: 0,
    fontWeight: FontWeight.w600,
  );
  static const _subtitleStyle = TextStyle(
    inherit: false,
    fontFamily: TypeScale.family,
    fontSize: 12,
    height: 1.3,
    letterSpacing: 0,
    fontWeight: FontWeight.w500,
    color: Palette.white,
  );
  static const _labels = ['Hôm nay', 'Bản đồ', 'Ra ngoài', 'Địa điểm'];

  static bool _twoRows(double innerWidth, TextScaler scaler) =>
      scaler.scale(13) > 19 && innerWidth < 420;

  static double _itemHeight(double width, TextScaler scaler, int index) {
    double textHeight(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: math.max(1.0, width - 2 * Space.xs));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    // Reserve the longest valid rain label so live updates never resize the bar.
    final content =
        2 * Space.s +
        24 +
        Space.xs +
        textHeight(_labels[index], _labelStyle) +
        (index == 2 ? textHeight('Mưa 2h: 100%', _subtitleStyle) : 0);
    return math.max(72.0, content.ceilToDouble());
  }

  static double _rowHeight(
    double itemWidth,
    TextScaler scaler,
    Iterable<int> indices,
  ) => indices.fold(
    72.0,
    (height, index) => math.max(height, _itemHeight(itemWidth, scaler, index)),
  );

  static double heightFor(double width, TextScaler scaler) {
    final innerWidth = width - 2 * Space.xs;
    if (_twoRows(innerWidth, scaler)) {
      final itemWidth = (innerWidth - Space.xs) / 2;
      return 2 * Space.xs +
          _rowHeight(itemWidth, scaler, [0, 1]) +
          Space.xs +
          _rowHeight(itemWidth, scaler, [2, 3]);
    }
    return 2 * Space.xs + _rowHeight(innerWidth / 4, scaler, [0, 1, 2, 3]);
  }

  @override
  Widget build(BuildContext context) {
    final destinations = <Widget>[
      _NavigationItem(
        icon: Icons.today_outlined,
        label: 'Hôm nay',
        tooltip: 'Thời tiết hôm nay',
        selected: true,
        onTap: onHome,
      ),
      _NavigationItem(
        icon: Icons.map_outlined,
        label: 'Bản đồ',
        tooltip: 'Bản đồ',
        onTap: onMap,
      ),
      if (onTrip != null)
        _NavigationItem(
          icon: Icons.directions_walk_rounded,
          label: 'Ra ngoài',
          tooltip: 'Tôi sắp ra ngoài',
          onTap: onTrip,
          subtitle: rainPercent == null ? null : 'Mưa 2h: $rainPercent%',
          semanticsLabel: rainPercent == null
              ? 'Tôi sắp ra ngoài'
              : 'Tôi sắp ra ngoài. Khả năng mưa 2 giờ tới $rainPercent%',
        ),
      _NavigationItem(
        icon: Icons.location_on_outlined,
        label: 'Địa điểm',
        tooltip: 'Danh sách địa điểm',
        onTap: onLocations,
        semanticsLabel: 'Danh sách địa điểm. $locationPosition',
      ),
    ];
    return GlassSurface(
      radius: 8,
      tint: const Color(0xF21C252C),
      padding: const EdgeInsets.all(Space.xs),
      child: LayoutBuilder(
        builder: (context, box) {
          if (vertical) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final destination in destinations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.s),
                    child: destination,
                  ),
              ],
            );
          }
          final scaler = MediaQuery.textScalerOf(context);
          Widget row(List<Widget> items, double height) => SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final item in items) Expanded(child: item)],
            ),
          );
          if (_twoRows(box.maxWidth, scaler)) {
            final itemWidth = (box.maxWidth - Space.xs) / 2;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  destinations.take(2).toList(),
                  _rowHeight(itemWidth, scaler, [0, 1]),
                ),
                const SizedBox(height: Space.xs),
                row(
                  destinations.skip(2).toList(),
                  _rowHeight(itemWidth, scaler, [2, 3]),
                ),
              ],
            );
          }
          return row(
            destinations,
            _rowHeight(box.maxWidth / 4, scaler, [0, 1, 2, 3]),
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
    this.subtitle,
    this.semanticsLabel,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;
  final String? subtitle;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    excludeFromSemantics: true,
    child: Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? Palette.white : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: 72,
              minWidth: Touch.min,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: Space.s,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 24,
                    color: selected ? Palette.onAlert : Palette.white,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: HomeNavigation._labelStyle.copyWith(
                      color: selected ? Palette.onAlert : Palette.white,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      style: HomeNavigation._subtitleStyle,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
