/// Khoi kinh dung chung: be mat kinh, the co tieu de, vien "pill", phan hoi
/// khi cham, hieu ung xuat hien, va so dang ky vi tri the cho giot mua.
library;

import 'dart:ui' show ImageFilter, FontFeature;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_background.dart' show WeatherBackground;
import '../weather_scene.dart';
import '../app_scene.dart';

/// Ten cu (giu cho code goi): mau co dinh tren kinh.
abstract final class GlassColors {
  static const Color text = Palette.white;
  static const Color border = Palette.border;
  static const Color divider = Palette.divider;
}

/// Chu so co dinh do rong.
const List<FontFeature> kTabular = TypeScale.tabular;

/// Thong so the kinh.
abstract final class GlassSpec {
  static const double radius = Radii.card;
  static const double blurSigma = 20;
  static const double gap = Space.cardGap;
}

/// Be mat kinh: blur + [SceneTheme.glassColor] + vien 1 px trang 0.18 +
/// vet sang 1 px o canh tren (trang 0.25 -> 0).
///
/// Hieu nang: blur dung chung mot backdrop voi cac the khac duoi cung
/// [BackdropGroup] (WeatherBackground cung cap); khi may cham (chat luong nen
/// o muc thap nhat) thi bo blur, chi giu tint (tuong phan khong doi).
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = Radii.card,
    this.blur = true,
    this.padding = EdgeInsets.zero,
    this.tint,
  });

  final Widget child;
  final double radius;
  final bool blur;
  final EdgeInsetsGeometry padding;

  /// Ghi de mau kinh (mac dinh theo canh hien tai).
  final Color? tint;

  static final ImageFilter _blur = ImageFilter.blur(
    sigmaX: GlassSpec.blurSigma,
    sigmaY: GlassSpec.blurSigma,
  );

  @override
  Widget build(BuildContext context) {
    Color color = tint ?? AppScene.of(context).theme.glassColor;
    // Tuong phan cao (he thong hoac trong app): kinh dac + toi hon, vien ro.
    final bool hc = MediaQuery.maybeHighContrastOf(context) ?? false;
    if (hc) {
      color = Color.alphaBlend(
        const Color(0x59000000),
        color.withValues(alpha: color.a < 0.8 ? 0.8 : color.a),
      );
    }
    final BorderRadius br = BorderRadius.circular(radius);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: br,
        border: hc
            ? Border.all(color: Palette.secondary, width: 1.5)
            : Border.all(color: Palette.border),
      ),
      position: DecorationPosition.background,
      child: Stack(
        children: [
          Padding(padding: padding, child: child),
          Positioned(
            top: 0,
            left: radius / 2,
            right: radius / 2,
            height: 1,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0x00FFFFFF),
                      Palette.highlight,
                      Color(0x00FFFFFF),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (blur) {
      final Widget tinted = box;
      box = ValueListenableBuilder<double>(
        valueListenable: WeatherBackground.qualityScale,
        child: tinted,
        builder: (context, q, child) => q <= WeatherBackground.qualitySteps.last
            ? child!
            : BackdropFilter.grouped(filter: _blur, child: child),
      );
    }
    return ClipRRect(borderRadius: br, child: box);
  }
}

/// The kinh: tieu de nho viet hoa (tuy chon), noi dung, dong nguon cuoi the.
///
/// [semanticsLabel] != null -> ca the la MOT nut doc voi cau day du (noi
/// dung con bi an khoi trinh doc man hinh). Dung cho the khong co nut bam.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.all(Space.cardPadding),
    this.semanticsLabel,
    this.splashTarget = true,
    this.footer,
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final String? semanticsLabel;
  final bool splashTarget;

  /// Dong chu thich cuoi the (vd. nguon so lieu).
  final String? footer;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  SplashRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final SplashRegistry? r = widget.splashTarget
        ? SplashTargets.maybeOf(context)
        : null;
    if (r != _registry) {
      _registry?.unregister(this);
      _registry = r;
      _registry?.register(this);
    }
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? title = widget.title;
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          GlassCardTitle(
            title: title,
            icon: widget.icon,
            trailing: widget.trailing,
          ),
          const SizedBox(height: Space.s),
        ],
        widget.child,
        if (widget.footer != null) GlassFootnote(widget.footer!),
      ],
    );
    content = widget.semanticsLabel != null
        ? Semantics(
            container: true,
            label: widget.semanticsLabel,
            excludeSemantics: true,
            child: content,
          )
        : Semantics(container: true, child: content);
    return DefaultTextStyle.merge(
      style: const TextStyle(color: Palette.white),
      child: GlassSurface(padding: widget.padding, child: content),
    );
  }
}

/// Dong tieu de nho viet hoa (icon + chu, 12 sp, letterSpacing 0.6).
class GlassCardTitle extends StatelessWidget {
  const GlassCardTitle({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Color c = GlassInk.of(context).title;
    // Chu rat lon (>= 1,8x): dua [trailing] xuong dong rieng de khong tran.
    final bool stack =
        trailing != null && MediaQuery.textScalerOf(context).scale(10) >= 18;
    final Widget row = Row(
      children: [
        if (icon != null) ...[
          ExcludeSemantics(
            child: Icon(icon, size: IconSizes.sm, color: c),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: TypeScale.cardTitle.copyWith(color: c),
          ),
        ),
        if (!stack) ?trailing,
      ],
    );
    return Semantics(
      header: true,
      child: stack
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                const SizedBox(height: Space.xs),
                trailing!,
              ],
            )
          : row,
    );
  }
}

/// Dong nguon / chu thich nho cuoi the, co vach mo phia tren.
class GlassFootnote extends StatelessWidget {
  const GlassFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final Color c = GlassInk.of(context).secondary;
    return Padding(
      padding: const EdgeInsets.only(top: Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1, color: Palette.divider),
          const SizedBox(height: Space.s),
          Text(text, style: TypeScale.small.copyWith(color: c)),
        ],
      ),
    );
  }
}

/// Vien nho dang "pill" bang kinh ("Cập nhật 12:00", "Dữ liệu cũ").
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.label,
    this.icon,
    this.iconColor,
    this.semanticsLabel,
  });

  final String label;
  final IconData? icon;

  /// Mau icon (tin hieu phu); chu luon trang.
  final Color? iconColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel ?? label,
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
            if (icon != null) ...[
              Icon(icon, size: 14, color: iconColor ?? Palette.white),
              const SizedBox(width: Space.xs),
            ],
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

/// Phan hoi khi cham: mo 0.7 trong 120 ms, khong doi bo cuc.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.semanticsLabel,
    this.button = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticsLabel;
  final bool button;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null || widget.onLongPress != null;
    return Semantics(
      container: widget.semanticsLabel != null,
      button: widget.button && enabled,
      label: widget.semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedOpacity(
          opacity: _down ? Opacities.pressed : 1,
          duration: _down ? Motion.micro : Motion.shortExit,
          curve: _down ? Motion.enter : Motion.exit,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Nut icon kinh >= 48 dp, co nhan, phan hoi mo khi cham.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Pressable(
        onTap: onPressed,
        semanticsLabel: tooltip,
        child: SizedBox.square(
          dimension: Touch.min,
          child: Icon(
            icon,
            size: IconSizes.md,
            color: onPressed == null
                ? Palette.white.withValues(alpha: 0.5)
                : Palette.white,
          ),
        ),
      ),
    );
  }
}

/// Xuat hien lan dau: mo dan + troi len 12 px, tre [index] x 50 ms (toi da
/// 6 the). Giam chuyen dong / [animate] = false -> hien ngay.
class EntranceFade extends StatefulWidget {
  const EntranceFade({
    super.key,
    required this.index,
    required this.animate,
    required this.child,
  });

  final int index;
  final bool animate;
  final Widget child;

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    if (widget.animate && widget.index < Motion.maxStaggered) {
      final Duration delay = Motion.stagger * widget.index;
      _c = AnimationController(vsync: this, duration: Motion.medium + delay);
      _c!.forward();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? c = _c;
    if (c == null || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.child;
    }
    final double start =
        (Motion.stagger * widget.index).inMicroseconds /
        c.duration!.inMicroseconds;
    final Animation<double> t = CurvedAnimation(
      parent: c,
      curve: Interval(start, 1, curve: Motion.enter),
    );
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(
          offset: Offset(0, Motion.riseOffset * (1 - t.value)),
          child: child,
        ),
      ),
    );
  }
}

/// So dang ky vi tri cac the kinh -> danh sach Rect (toa do cua
/// [backgroundKey]) cho `WeatherBackground.splashTargets`.
class SplashRegistry {
  SplashRegistry();

  /// Key cua widget nen (WeatherBackground) - goc toa do cua Rect.
  final GlobalKey backgroundKey = GlobalKey(debugLabel: 'splash-bg');

  /// Gia tri dua vao `WeatherBackground.splashTargets`.
  final ValueNotifier<List<Rect>> rects = ValueNotifier<List<Rect>>(
    const <Rect>[],
  );

  final Set<State> _cards = <State>{};

  void register(State s) => _cards.add(s);

  void unregister(State s) => _cards.remove(s);

  /// Tinh lai Rect cua cac the dang hien (goi sau khi cuon / doi bo cuc).
  void update() {
    final RenderObject? bg = backgroundKey.currentContext?.findRenderObject();
    if (bg is! RenderBox || !bg.hasSize || !bg.attached) return;
    final List<Rect> out = <Rect>[];
    for (final State s in _cards) {
      if (!s.mounted) continue;
      final RenderObject? ro = s.context.findRenderObject();
      if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
      final Offset o = ro.localToGlobal(Offset.zero, ancestor: bg);
      final Rect r = o & ro.size;
      if (r.bottom < 0 || r.top > bg.size.height) continue;
      out.add(r);
    }
    if (!_sameRects(out, rects.value)) rects.value = out;
  }

  /// Xoa vi tri (canh khong mua).
  void clear() {
    if (rects.value.isNotEmpty) rects.value = const <Rect>[];
  }

  void dispose() => rects.dispose();

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Dua [SplashRegistry] xuong cac [GlassCard].
class SplashTargets extends InheritedWidget {
  const SplashTargets({
    super.key,
    required this.registry,
    required super.child,
  });

  final SplashRegistry registry;

  static SplashRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SplashTargets>()?.registry;

  @override
  bool updateShouldNotify(SplashTargets oldWidget) =>
      oldWidget.registry != registry;
}

/// Canh co giot mua roi trung the (mua / mua to / dong / mua tuyet).
bool sceneHasSplashes(WeatherScene s) => const {
  WeatherScene.rain,
  WeatherScene.heavyRain,
  WeatherScene.thunderstorm,
  WeatherScene.sleet,
}.contains(s);
