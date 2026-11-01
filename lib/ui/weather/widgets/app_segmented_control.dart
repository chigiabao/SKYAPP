import 'package:flutter/cupertino.dart';

import '../../../utils/haptics.dart';
import '../design_tokens.dart';
import 'glass_page.dart';

/// Mot phan doan cua [AppSegmentedControl].
class AppSegment<T> {
  const AppSegment({
    required this.value,
    required this.label,
    this.icon,
    this.semanticsLabel,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? semanticsLabel;
}

/// Bo chon phan doan kieu iOS (CupertinoSlidingSegmentedControl) dung chung:
/// cac phan bang nhau, cao toi thieu 44, chu xuong dong thay vi bi cat khi
/// co chu lon, rung nhe khi doi lua chon. Tren nen kinh dung mau kinh; tren
/// trang he thong (Cai dat) dung mau mac dinh cua iOS.
class AppSegmentedControl<T extends Object> extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.fontSize = 15,
    this.width,
    this.onDeselect,
  });

  /// Cau hoi khong bat buoc: khac null -> khi da chon, hien nut "Bỏ chọn"
  /// (canh phai, duoi bo chon) de quay ve trang thai chua chon.
  final VoidCallback? onDeselect;

  final List<AppSegment<T>> segments;

  /// null = chua chon phan nao (vd. cau hoi khong bat buoc).
  final T? selected;

  /// null = vo hieu hoa.
  final ValueChanged<T>? onChanged;
  final double fontSize;

  /// Be ngang co dinh de do chu (bo qua LayoutBuilder) - dung trong hop thoai
  /// tinh kich thuoc intrinsic (AlertDialog). Uoc luong NHO hon thuc te chi
  /// lam phan cao hon, khong cat chu.
  final double? width;

  static const _controlPadding = EdgeInsets.all(3);
  static const _labelPadding = EdgeInsets.all(Space.xs);

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final glass = GlassThemeMarker.isGlass(context);
    final Color fg = glass
        ? Palette.white
        : CupertinoColors.label.resolveFrom(context);
    final enabled = onChanged != null;
    final style = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: enabled ? fg : fg.withValues(alpha: 0.5),
        letterSpacing: 0,
      ),
    );
    // Cupertino giu moi phan cung chieu cao (khong tu gian theo chu): do
    // truoc chieu cao chu da xuong dong o be ngang moi phan de khong bi cat
    // khi co chu lon.
    Widget build0(double maxWidth) {
      final n = segments.length;
      final segmentWidth =
          ((maxWidth - _controlPadding.horizontal - (n - 1)) / n)
              .clamp(0.0, double.infinity)
              .toDouble();
      final iconSpace = segments.any((s) => s.icon != null)
          ? mq.textScaler.scale(fontSize) + Space.xs
          : 0.0;
      final labelWidth = (segmentWidth - _labelPadding.horizontal - iconSpace)
          .clamp(1.0, double.infinity)
          .toDouble();
      var segmentHeight = Touch.min;
      for (final s in segments) {
        final painter = TextPainter(
          text: TextSpan(text: s.label, style: style),
          textDirection: Directionality.of(context),
          textScaler: mq.textScaler,
        )..layout(maxWidth: labelWidth);
        final h = (painter.height + _labelPadding.vertical).ceilToDouble();
        if (h > segmentHeight) segmentHeight = h;
        painter.dispose();
      }
      // Phu het be ngang duoc cap (kieu iOS trong form / thanh cong cu).
      final control = maxWidth.isFinite
          ? SizedBox(
              width: maxWidth,
              child: _control(context, style, segmentHeight),
            )
          : _control(context, style, segmentHeight);
      final clear = onDeselect;
      if (clear == null || selected == null || !enabled) return control;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          control,
          CupertinoButton(
            key: const ValueKey('segment-deselect'),
            padding: const EdgeInsets.symmetric(horizontal: Space.s),
            minimumSize: const Size(Touch.min, Touch.min),
            onPressed: () {
              AppHaptics.selection();
              clear();
            },
            child: Text(
              'Bỏ chọn',
              style: style.copyWith(
                fontWeight: FontWeight.w400,
                color: glass
                    ? SystemColors.accentDark
                    : CupertinoColors.activeBlue.resolveFrom(context),
              ),
            ),
          ),
        ],
      );
    }

    final fixed = width;
    if (fixed != null) return build0(fixed);
    return LayoutBuilder(builder: (context, box) => build0(box.maxWidth));
  }

  Widget _control(BuildContext context, TextStyle style, double height) {
    final mq = MediaQuery.of(context);
    final glass = GlassThemeMarker.isGlass(context);
    final enabled = onChanged != null;
    return CupertinoSlidingSegmentedControl<T>(
      key: mq.disableAnimations ? ValueKey(selected) : null,
      groupValue: selected,
      backgroundColor: glass
          ? Palette.segmentTrack
          : CupertinoColors.tertiarySystemFill.resolveFrom(context),
      thumbColor: glass
          ? Palette.segmentThumb
          : const CupertinoDynamicColor.withBrightness(
              color: Color(0xFFFFFFFF),
              darkColor: Color(0xFF636366),
            ).resolveFrom(context),
      padding: _controlPadding,
      disabledChildren: enabled ? <T>{} : {for (final s in segments) s.value},
      onValueChanged: (value) {
        if (value == null || !enabled || value == selected) return;
        AppHaptics.selection();
        onChanged!(value);
      },
      children: {
        for (final s in segments)
          s.value: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: _labelPadding,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.icon != null) ...[
                      Icon(
                        s.icon,
                        size: mq.textScaler.scale(fontSize),
                        color: style.color,
                      ),
                      const SizedBox(width: Space.xs),
                    ],
                    Flexible(
                      child: Text(
                        s.label,
                        semanticsLabel: s.semanticsLabel,
                        textAlign: TextAlign.center,
                        textScaler: mq.textScaler,
                        style: style,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      },
    );
  }
}
