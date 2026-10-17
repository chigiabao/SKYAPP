/// Hieu ung "lap lanh" nhe tren so lieu khi dang tai lai.
library;

import 'package:flutter/material.dart';

/// Phu mot dai sang chay ngang len [child] khi [enabled].
///
/// Giam chuyen dong (`MediaQuery.disableAnimations`): khong chay, chi lam mo
/// [child] (0.6) de van bao hieu dang tai.
class Shimmer extends StatefulWidget {
  const Shimmer({
    super.key,
    required this.enabled,
    required this.child,
    this.period = const Duration(milliseconds: 1400),
  });

  final bool enabled;
  final Widget child;
  final Duration period;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(Shimmer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final bool run = widget.enabled && !_reduce;
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    if (_reduce) return Opacity(opacity: 0.6, child: widget.child);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final double t = _c.value;
        return ShaderMask(
          blendMode: BlendMode.modulate,
          shaderCallback: (Rect r) => LinearGradient(
            begin: Alignment(-1.0 + 3 * t - 1, 0),
            end: Alignment(1.0 + 3 * t - 1, 0),
            colors: const [
              Color(0x99FFFFFF),
              Color(0xFFFFFFFF),
              Color(0x99FFFFFF),
            ],
            stops: const [0.25, 0.5, 0.75],
          ).createShader(r),
          child: child,
        );
      },
    );
  }
}

/// Khoi xam mo (placeholder) khi chua co so lieu - khong phai so gia.
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0x40FFFFFF),
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}
