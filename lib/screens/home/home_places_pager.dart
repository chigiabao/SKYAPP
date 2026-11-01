import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';

/// Hang "Địa điểm đã lưu" tren Home: cham trang (kieu iOS) + "2/4" + ten
/// dia diem ke tiep, nut ‹ › 44 pt. Vuot ngang PageView van doi trang.
class HomePlacesPager extends StatelessWidget {
  const HomePlacesPager({
    super.key,
    required this.index,
    required this.count,
    this.nextName,
    this.onPrevious,
    this.onNext,
  });

  final int index;
  final int count;
  final String? nextName;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Qua nhieu trang: bo cham, chi giu "2/14".
  static const int maxDots = 9;

  @override
  Widget build(BuildContext context) {
    final position = '${index + 1}/$count';
    final detail = nextName == null
        ? position
        : '$position · Tiếp theo: $nextName';
    final semantics =
        'Địa điểm đã lưu, trang ${index + 1} trên $count'
        '${nextName == null ? '' : '. Tiếp theo: $nextName'}. '
        'Vuốt ngang để đổi địa điểm';
    return Row(
      key: const ValueKey('home-places-pager'),
      children: [
        _arrow(CupertinoIcons.chevron_left, 'Địa điểm trước', onPrevious),
        Expanded(
          child: Semantics(
            container: true,
            label: semantics,
            excludeSemantics: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (count <= maxDots)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < count; i++)
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == index
                                  ? Palette.white
                                  : Palette.white.withValues(alpha: 0.35),
                            ),
                          ),
                      ],
                    ),
                  ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TypeScale.bodyMedium.copyWith(color: Palette.white),
                ),
              ],
            ),
          ),
        ),
        _arrow(CupertinoIcons.chevron_right, 'Địa điểm tiếp theo', onNext),
      ],
    );
  }

  Widget _arrow(IconData icon, String tooltip, VoidCallback? onPressed) =>
      Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          label: tooltip,
          excludeSemantics: true,
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(Touch.min, Touch.min),
            onPressed: onPressed,
            child: Icon(
              icon,
              size: 22,
              color: onPressed == null
                  ? Palette.white.withValues(alpha: 0.3)
                  : Palette.white,
            ),
          ),
        ),
      );
}
