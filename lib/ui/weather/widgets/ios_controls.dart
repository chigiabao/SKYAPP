/// Nut, vien chon va o nhap kieu iOS tren nen kinh toi.
///
/// - [IosButton.filled]: hanh dong chinh (nen trang, chu toi ~15:1).
/// - [IosButton.tinted]: hanh dong phu (nen trang mo, chu trang).
/// - [IosButton.plain]: lien ket / hanh dong nhe (chu trang dam).
/// Moi nut cao >= 48, chu tu xuong dong khi co chu lon.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import '../../../utils/haptics.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';

enum IosButtonKind { filled, tinted, plain }

class IosButton extends StatelessWidget {
  const IosButton.filled({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.destructive = false,
    this.minHeight = Touch.min,
  }) : kind = IosButtonKind.filled;

  const IosButton.tinted({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.destructive = false,
    this.minHeight = Touch.min,
  }) : kind = IosButtonKind.tinted;

  const IosButton.plain({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.destructive = false,
    this.minHeight = Touch.min,
  }) : kind = IosButtonKind.plain;

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final IosButtonKind kind;

  /// Rong het cot (nut chinh cuoi form / the).
  final bool expand;
  final bool destructive;

  /// Chieu cao toi thieu (nut chinh lon, vd. "Bắt đầu theo dõi" 64).
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final still = MediaQuery.disableAnimationsOf(context);
    final (Color bg, Color fg) = switch (kind) {
      IosButtonKind.filled =>
        destructive
            ? (Palette.danger, Palette.white)
            : (Palette.white, Palette.onWhite),
      IosButtonKind.tinted => (
        Palette.subtleFill,
        destructive ? Palette.dangerOnGlass : Palette.white,
      ),
      IosButtonKind.plain => (
        const Color(0x00000000),
        destructive ? Palette.dangerOnGlass : Palette.white,
      ),
    };
    final style = TypeScale.headline.copyWith(
      fontFamily: TypeScale.family,
      color: fg,
    );
    final Widget text = Text(label, textAlign: TextAlign.center, style: style);
    final Widget content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          ExcludeSemantics(child: Icon(icon, size: 20, color: fg)),
          const SizedBox(width: Space.s),
        ],
        Flexible(child: text),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: CupertinoButton(
          padding: EdgeInsets.symmetric(
            horizontal: kind == IosButtonKind.plain ? Space.s : Space.l + 4,
            vertical: Space.m,
          ),
          minimumSize: Size(Touch.min, minHeight),
          color: kind == IosButtonKind.plain ? null : bg,
          disabledColor: bg,
          borderRadius: BorderRadius.circular(Radii.button),
          pressedOpacity: still ? 0.85 : Opacities.pressed,
          onPressed: enabled
              ? () {
                  if (kind == IosButtonKind.filled) AppHaptics.light();
                  onPressed!();
                }
              : null,
          child: content,
        ),
      ),
    );
  }
}

/// Vien chon (pill) co dau tick khi chon - thay chip Material.
class IosPill extends StatelessWidget {
  const IosPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.icon,
    this.semanticsLabel,
    this.selectable = true,
  });

  /// false: nut goi y (vd. tu khoa tim kiem) - doc la nut, khong co trang
  /// thai chon.
  final bool selectable;

  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  /// Icon khi chua chon (khi chon luon la dau tick).
  final IconData? icon;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Palette.onWhite : Palette.white;
    final IconData? lead = selected ? CupertinoIcons.checkmark_alt : icon;
    return Semantics(
      container: true,
      button: true,
      checked: selectable ? selected : null,
      enabled: onChanged != null,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null
            ? null
            : () {
                AppHaptics.selection();
                onChanged!(!selected);
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.min),
          child: Center(
            widthFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? Palette.white : Palette.subtleFill,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(
                  color: selected ? Palette.white : Palette.border,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.m + 2,
                  vertical: Space.s,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (lead != null) ...[
                      Icon(lead, size: 16, color: fg),
                      const SizedBox(width: Space.xs + 2),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: TypeScale.subhead.copyWith(
                          color: fg,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
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
}

/// Thanh truot kieu iOS (CupertinoSlider) kem nhan gia tri ben phai.
///
/// - Buoc theo [divisions] (giong Slider Material).
/// - Rung nhe (selection) moi nac va o hai dau, giong nhau tren moi nen
///   tang (xem [_tick]); khong rung them khi tha tay.
/// - Semantics: doc la thanh truot voi [semanticLabel] + [semanticValue];
///   vuot len / xuong tang giam dung mot buoc.
class IosSlider extends StatelessWidget {
  const IosSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.valueWidth = 88,
    required this.valueLabel,
    required this.semanticLabel,
    this.divisions,
    this.semanticValue,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Gia tri hien thi ben phai (vd. "70%", "24 giờ").
  /// Be rong toi thieu cot gia tri (o co chu 100 %).
  final double valueWidth;

  final String valueLabel;

  /// Ten doc cho trinh doc man hinh (vd. "Ngưỡng Mưa").
  final String semanticLabel;

  /// Doi gia tri -> chu doc (mac dinh = [valueLabel] cho gia tri hien tai).
  final String Function(double v)? semanticValue;

  double get _step =>
      (max - min) / (divisions == null || divisions! <= 0 ? 10 : divisions!);

  String _say(double v) => semanticValue?.call(v) ?? valueLabel;

  /// Mot kieu rung tren moi nen tang: "tick" moi nac (co [divisions]) va khi
  /// cham hai dau. CupertinoSlider tu rung o hai dau tren iOS -> bo qua de
  /// khong rung doi; khong rung them luc tha tay.
  void _tick(double from, double to) {
    if (to == from) return;
    final edge = to == min || to == max;
    if (edge && defaultTargetPlatform == TargetPlatform.iOS) return;
    if (edge || divisions != null) AppHaptics.selection();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final v = value.clamp(min, max).toDouble();
    final up = (v + _step).clamp(min, max).toDouble();
    final down = (v - _step).clamp(min, max).toDouble();
    void nudge(double to) {
      if (to == v || onChanged == null) return;
      AppHaptics.selection();
      onChanged!(to);
      onChangeEnd?.call(to);
    }

    return Semantics(
      container: true,
      slider: true,
      enabled: enabled,
      label: semanticLabel,
      value: _say(v),
      increasedValue: up == v ? null : _say(up),
      decreasedValue: down == v ? null : _say(down),
      onIncrease: enabled && up != v ? () => nudge(up) : null,
      onDecrease: enabled && down != v ? () => nudge(down) : null,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Row(
          children: [
            Expanded(
              child: CupertinoSlider(
                value: v,
                min: min,
                max: max,
                divisions: divisions,
                activeColor: Palette.white,
                thumbColor: Palette.white,
                onChanged: !enabled
                    ? null
                    : (to) {
                        _tick(v, to);
                        onChanged!(to);
                      },
                onChangeEnd: onChangeEnd,
              ),
            ),
            const SizedBox(width: Space.s),
            // Cot gia tri rong co dinh (theo co chu): cac thanh truot xep
            // chong nhau co ray dai bang nhau, so can phai.
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.textScalerOf(context).scale(valueWidth),
              ),
              child: Text(
                valueLabel,
                textAlign: TextAlign.end,
                style: TypeScale.subhead.copyWith(
                  color: Palette.white,
                  fontWeight: FontWeight.w600,
                  fontFeatures: TypeScale.tabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trang tri o nhap iOS tren kinh: nen trang mo, bo 10, khong vien.
BoxDecoration iosFieldDecoration() => BoxDecoration(
  color: Palette.subtleFill,
  borderRadius: BorderRadius.circular(Radii.field),
);

/// O nhap chu kieu iOS (CupertinoTextField) co nhan nhin thay ben tren.
class IosTextField extends StatelessWidget {
  const IosTextField({
    super.key,
    required this.label,
    this.controller,
    this.placeholder,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.maxLines = 1,
    this.minLines,
    this.autofillHints,
    this.autofocus = false,
    this.enabled = true,
    this.suffix,
    this.maxLength,
    this.autocorrect = true,
  });

  final String label;
  final bool autocorrect;
  final TextEditingController? controller;
  final String? placeholder;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final int? maxLines;
  final int? minLines;
  final Iterable<String>? autofillHints;
  final bool autofocus;
  final bool enabled;
  final Widget? suffix;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          // Nhan thang mep chu cua the / o nhap (khong thut them).
          padding: const EdgeInsets.only(bottom: Space.xs),
          child: Text(
            label,
            style: TypeScale.footnote.copyWith(color: ink.secondary),
          ),
        ),
        CupertinoTextField(
          controller: controller,
          placeholder: placeholder,
          obscureText: obscureText,
          keyboardType: keyboardType,
          autocorrect: autocorrect,
          textInputAction: textInputAction,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          maxLines: obscureText ? 1 : maxLines,
          minLines: minLines,
          maxLength: maxLength,
          autofillHints: autofillHints,
          autofocus: autofocus,
          enabled: enabled,
          suffix: suffix,
          // +1 moi phia: o nhap 1 dong cao 48 (vung cham toi thieu).
          padding: const EdgeInsets.symmetric(
            horizontal: Space.m,
            vertical: Space.m + 1,
          ),
          style: TypeScale.iosBody.copyWith(
            fontFamily: TypeScale.family,
            color: Palette.white,
          ),
          placeholderStyle: TypeScale.iosBody.copyWith(
            fontFamily: TypeScale.family,
            color: ink.secondary,
          ),
          cursorColor: Palette.white,
          decoration: iosFieldDecoration().copyWith(
            border: errorText == null
                ? null
                : Border.all(color: Palette.dangerOnGlass),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(left: Space.xs, top: Space.xs),
            child: Semantics(
              liveRegion: true,
              child: Text(
                errorText!,
                style: TypeScale.footnote.copyWith(
                  color: Palette.dangerOnGlass,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
