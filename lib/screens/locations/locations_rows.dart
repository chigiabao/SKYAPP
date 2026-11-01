/// Dong dia diem da luu / ket qua tim kiem va hieu ung them / xoa.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/place.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/adaptive_dialog.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../locations_screen.dart';
import 'locations_widgets.dart';
import '../../ui/weather/widgets/ios_page.dart';

/// Dong hien dan (them) / thu gon (xoa) 220 ms; tat khi giam chuyen dong.
class LocationsAnimatedRow extends StatefulWidget {
  const LocationsAnimatedRow({
    super.key,
    required this.appear,
    required this.visible,
    required this.onHidden,
    required this.child,
  });

  final bool appear;
  final bool visible;
  final VoidCallback onHidden;
  final Widget child;

  @override
  State<LocationsAnimatedRow> createState() => _AnimatedRowState();
}

class _AnimatedRowState extends State<LocationsAnimatedRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.short,
    value: widget.appear ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );

  @override
  void initState() {
    super.initState();
    if (widget.appear) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.of(context).disableAnimations) {
          _c.value = 1;
        } else {
          _c.forward();
        }
      });
    }
  }

  @override
  void didUpdateWidget(LocationsAnimatedRow old) {
    super.didUpdateWidget(old);
    if (old.visible && !widget.visible) {
      _c.reverse().then((_) {
        if (mounted && !widget.visible) widget.onHidden();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _curve,
    alignment: Alignment.topCenter,
    child: FadeTransition(opacity: _curve, child: widget.child),
  );
}

enum _RowAction { label, up, down, remove }

class LocationsSavedRow extends StatelessWidget {
  const LocationsSavedRow({
    super.key,
    required this.index,
    required this.count,
    required this.place,
    required this.saved,
    required this.cell,
    required this.viewing,
    required this.compareMode,
    required this.picked,
    required this.onTap,
    required this.onLabel,
    required this.onMove,
    required this.onRemove,
  });

  final int index;
  final int count;
  final Place place;
  final SavedPlace saved;
  final MapCell? cell;
  final bool viewing;
  final bool compareMode;
  final bool picked;
  final VoidCallback onTap;
  final VoidCallback onLabel;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final label = saved.shortLabelText;
    final sub = [?label, place.friendlyDetail].join(' · ');
    // Nhom inset-grouped iOS: hang dau bo goc tren, hang cuoi bo goc duoi,
    // duong ke manh giua cac hang (thut vao sau tay keo).
    const r = Radius.circular(Radii.group);
    final first = index == 0;
    final last = index == count - 1;
    return GlassSurface(
      key: ValueKey('saved-row-surface-$index'),
      border: false,
      borderRadius: BorderRadius.only(
        topLeft: first ? r : Radius.zero,
        topRight: first ? r : Radius.zero,
        bottomLeft: last ? r : Radius.zero,
        bottomRight: last ? r : Radius.zero,
      ),
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: first
              ? null
              : const Border(
                  top: BorderSide(color: Palette.divider, width: 0.5),
                ),
        ),
        child: Row(
          children: [
            if (compareMode)
              Semantics(
                checked: picked,
                label: 'Chọn ${place.name} để so sánh',
                excludeSemantics: true,
                onTap: onTap,
                child: Pressable(
                  onTap: onTap,
                  button: false,
                  child: SizedBox.square(
                    dimension: Touch.min,
                    child: Icon(
                      picked
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: picked ? ink.accent : Palette.white,
                    ),
                  ),
                ),
              )
            else
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: 'Kéo để đổi thứ tự',
                  child: const SizedBox(
                    width: 40,
                    height: Touch.min + 16,
                    child: Icon(
                      CupertinoIcons.line_horizontal_3,
                      color: Palette.secondary,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Pressable(
                onTap: onTap,
                semanticsLabel: [
                  place.name,
                  sub,
                  if (viewing) 'đang xem',
                  if (compareMode) picked ? 'đã chọn' : 'chưa chọn',
                ].join(', '),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              place.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TypeScale.label.copyWith(
                                color: Palette.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (viewing) ...[
                                  Text(
                                    'Đang xem',
                                    style: TypeScale.footnote.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: Palette.white,
                                    ),
                                  ),
                                  Text(
                                    ' · ',
                                    style: TypeScale.small.copyWith(
                                      color: ink.secondary,
                                    ),
                                  ),
                                ],
                                Expanded(
                                  child: Text(
                                    sub,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TypeScale.footnote.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: ink.secondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.s),
                      ExcludeSemantics(child: PlaceWeatherSummary(cell: cell)),
                    ],
                  ),
                ),
              ),
            ),
            if (!compareMode)
              IosBarButton(
                tooltip: 'Tùy chọn cho ${place.name}',
                icon: CupertinoIcons.ellipsis_circle,
                onPressed: () async {
                  final a = await showAppActionSheet<_RowAction>(
                    context,
                    title: place.name,
                    actions: [
                      const AppDialogAction(
                        label: 'Đổi nhãn',
                        value: _RowAction.label,
                        icon: CupertinoIcons.tag,
                      ),
                      if (index > 0)
                        const AppDialogAction(
                          label: 'Di chuyển lên',
                          value: _RowAction.up,
                          icon: CupertinoIcons.arrow_up,
                        ),
                      if (index < count - 1)
                        const AppDialogAction(
                          label: 'Di chuyển xuống',
                          value: _RowAction.down,
                          icon: CupertinoIcons.arrow_down,
                        ),
                      const AppDialogAction(
                        label: 'Xóa',
                        value: _RowAction.remove,
                        isDestructive: true,
                        icon: CupertinoIcons.delete,
                      ),
                    ],
                  );
                  switch (a) {
                    case _RowAction.label:
                      onLabel();
                    case _RowAction.up:
                      onMove(index - 1);
                    case _RowAction.down:
                      onMove(index + 1);
                    case _RowAction.remove:
                      onRemove();
                    case null:
                      break;
                  }
                },
              )
            else
              const SizedBox(width: Space.s),
          ],
        ),
      ),
    );
  }
}

class LocationsDeleteBackground extends StatelessWidget {
  const LocationsDeleteBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: Space.xl),
      decoration: BoxDecoration(
        color: Palette.swipeDelete,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, color: Palette.white),
          SizedBox(width: Space.s),
          Text(
            'Xóa',
            style: TextStyle(color: Palette.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class LocationsResultRow extends StatelessWidget {
  const LocationsResultRow({
    super.key,
    required this.place,
    required this.saved,
    required this.onTap,
  });

  final Place place;
  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final sub = place.region == null
        ? place.kind.label
        : '${place.kind.label} · ${friendlyRegion(place.region!)}';
    return Pressable(
      onTap: onTap,
      semanticsLabel:
          '${place.name}, $sub, ${saved ? 'đã lưu, mở' : 'lưu địa điểm'}',
      child: GlassSurface(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.m, Space.m),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    style: TypeScale.label.copyWith(
                      color: Palette.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    sub,
                    style: TypeScale.footnote.copyWith(
                      fontWeight: FontWeight.w500,
                      color: ink.secondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              saved ? Icons.check_rounded : Icons.add_circle_outline_rounded,
              color: Palette.white,
            ),
            const SizedBox(width: Space.xs),
            Text(
              saved ? 'Đã lưu' : 'Lưu',
              style: TypeScale.small.copyWith(
                color: Palette.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
