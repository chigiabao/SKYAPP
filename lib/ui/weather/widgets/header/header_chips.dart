part of '../collapsing_header.dart';

class _BarLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(
      Size(size.width, HeaderMetrics.actionsHeight),
    );
    double left = 0;
    double right = 0;
    if (hasChild(_BarSlot.actions)) {
      final Size a = layoutChild(_BarSlot.actions, loose);
      positionChild(
        _BarSlot.actions,
        Offset(Space.xs, (size.height - a.height) / 2),
      );
      left = Space.xs + a.width;
    }
    if (hasChild(_BarSlot.trailing)) {
      final Size a = layoutChild(_BarSlot.trailing, loose);
      positionChild(
        _BarSlot.trailing,
        Offset(size.width - Space.xs - a.width, (size.height - a.height) / 2),
      );
      right = Space.xs + a.width;
    }
    if (hasChild(_BarSlot.title)) {
      // Can giua that su: chua lai hai ben bang nhom nut rong hon.
      final double inset = (left > right ? left : right) + Space.s;
      double start = inset;
      double end = size.width - inset;
      if (end - start < 96) {
        start = left + Space.s;
        end = size.width - (right > 0 ? right + Space.s : Space.l);
      }
      final double maxW = (end - start).clamp(0.0, size.width);
      final Size t = layoutChild(
        _BarSlot.title,
        BoxConstraints(maxWidth: maxW, maxHeight: size.height),
      );
      final double centered = (size.width - t.width) / 2;
      final double x = centered < start
          ? start
          : (centered + t.width > end ? end - t.width : centered);
      positionChild(_BarSlot.title, Offset(x, (size.height - t.height) / 2));
    }
  }

  @override
  bool shouldRelayout(_BarLayout oldDelegate) => false;
}

/// Khoi dau trang day du (dung trong delegate va o cot trai man hinh rong).

class _TodayChip extends StatelessWidget {
  const _TodayChip({required this.text, required this.rain});

  final String text;
  final bool rain;

  @override
  Widget build(BuildContext context) {
    final GlassInk ink = GlassInk.of(context);
    // Mua: nen pha mau mua + vien mua de noi bat hon trang thai hien tai.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: rain
            ? Color.alphaBlend(
                ink.rain.withValues(alpha: 0.16),
                Colors.black.withValues(alpha: 0.30),
              )
            : Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
          color: rain ? ink.rain.withValues(alpha: 0.55) : Palette.border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                rain ? Icons.umbrella_rounded : Icons.wb_sunny_outlined,
                size: IconSizes.sm,
                color: rain ? ink.rain : Palette.white,
              ),
            ),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: _todayStyle.copyWith(color: Palette.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Cập nhật lúc HH:mm" + cham xoay nho khi dang lam moi tren cache.
class _RefreshingPill extends StatelessWidget {
  const _RefreshingPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final bool reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: '$label, đang làm mới',
      liveRegion: true,
      excludeSemantics: true,
      child: GlassSurface(
        radius: Radii.pill,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs + 1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 12,
              child: reduce
                  ? const Icon(
                      Icons.sync_rounded,
                      size: 12,
                      color: Palette.white,
                    )
                  : const CupertinoActivityIndicator(
                      radius: 6,
                      color: Palette.white,
                    ),
            ),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(
                label,
                style: TypeScale.small.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Palette.white,
                  fontFeatures: kTabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
