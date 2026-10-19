/// Chuyen dong cua Home: the hien so le, so nhiet do dem len, giot mua khi
/// keo de lam moi. Giam chuyen dong (MediaQuery.disableAnimations - da gom
/// cong tac trong PreferencesProvider): chi fade 150 ms hoac bo qua.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

bool _reduced(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const Duration _reducedFade = Duration(milliseconds: 150);

/// The hien so le: tre 40 ms moi the, 280 ms, easeOutQuart, truot len 12 px
/// + fade. Chi chay khi duoc tao trong [window] ke tu [startedAt] (lan dau
/// vao man) - the bi huy / tao lai khi cuon khong chay lai.
class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.startedAt,
    required this.child,
  });

  final int index;

  /// Thoi diem bat dau hieu ung vao man (null = khong chay).
  final DateTime? startedAt;
  final Widget child;

  static const Duration step = Duration(milliseconds: 40);
  static const Duration duration = Duration(milliseconds: 280);
  static const int maxStaggered = 8;
  static const Duration window = Duration(milliseconds: 900);

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _reduce = false;

  @override
  void initState() {
    super.initState();
    final s = widget.startedAt;
    if (s != null &&
        widget.index < StaggerIn.maxStaggered &&
        DateTime.now().difference(s) < StaggerIn.window) {
      _c = AnimationController(
        vsync: this,
        duration: StaggerIn.duration + StaggerIn.step * widget.index,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = _reduced(context);
    final c = _c;
    if (reduce && !_reduce && c != null && c.isAnimating) {
      c.value = 1;
    }
    _reduce = reduce;
    if (c != null && !c.isAnimating && c.value == 0) {
      if (_reduce) c.duration = _reducedFade;
      c.forward();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || c.isCompleted) return widget.child;
    if (_reduce) {
      return FadeTransition(opacity: c, child: widget.child);
    }
    final double start =
        (StaggerIn.step * widget.index).inMicroseconds /
        c.duration!.inMicroseconds;
    final Animation<double> t = CurvedAnimation(
      parent: c,
      curve: Interval(start, 1, curve: Curves.easeOutQuart),
    );
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - t.value)),
          child: child,
        ),
      ),
    );
  }
}

/// So nhiet do ("26°") dem len 600 ms easeOutCubic khi gia tri / dia diem
/// doi. Nho gia tri da hien theo [memoryKey] de khong dem lai khi dau trang
/// bi dung lai (cuon len xuong). Giam chuyen dong: fade 150 ms.
class CountUpTemperature extends StatefulWidget {
  const CountUpTemperature({
    super.key,
    required this.text,
    required this.memoryKey,
    required this.style,
  });

  final String text;
  final String memoryKey;
  final TextStyle style;

  static final Map<String, int> _shown = {};

  /// Xoa bo nho (test).
  @visibleForTesting
  static void reset() => _shown.clear();

  @override
  State<CountUpTemperature> createState() => _CountUpTemperatureState();
}

class _CountUpTemperatureState extends State<CountUpTemperature> {
  int? _value;
  int? _from;
  int _run = 0;

  static int? _parse(String t) =>
      int.tryParse(RegExp(r'^-?\d+').stringMatch(t) ?? '');

  void _start(int? from) {
    final v = _value;
    if (v == null) return;
    CountUpTemperature._shown[widget.memoryKey] = v;
    if (from == v) return;
    _from = from ?? v - math.min(8, v.abs() + 1);
    _run++;
  }

  @override
  void initState() {
    super.initState();
    _value = _parse(widget.text);
    _start(CountUpTemperature._shown[widget.memoryKey]);
  }

  @override
  void didUpdateWidget(CountUpTemperature old) {
    super.didUpdateWidget(old);
    final v = _parse(widget.text);
    if (old.memoryKey != widget.memoryKey) {
      _value = v;
      _start(CountUpTemperature._shown[widget.memoryKey]);
    } else if (v != _value) {
      final prev = _value;
      _value = v;
      _start(prev);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final from = _from;
    if (_reduced(context) || v == null || from == null) {
      return AnimatedSwitcher(
        duration: _reducedFade,
        child: Text(
          widget.text,
          key: ValueKey(widget.text),
          style: widget.style,
        ),
      );
    }
    final String suffix = widget.text.substring('$v'.length);
    return TweenAnimationBuilder<double>(
      key: ValueKey(_run),
      tween: Tween(begin: from.toDouble(), end: v.toDouble()),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      onEnd: () => _from = null,
      builder: (context, x, _) =>
          Text('${x.round()}$suffix', style: widget.style),
    );
  }
}

/// Keo de lam moi: RefreshIndicator + mot dot giot mua roi ~900 ms o phia
/// tren (CustomPainter nhe). Giam chuyen dong: khong ve giot.
class RainRefresh extends StatefulWidget {
  const RainRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    required this.backgroundColor,
    this.edgeOffset = 0,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final Color backgroundColor;
  final double edgeOffset;

  @override
  State<RainRefresh> createState() => _RainRefreshState();
}

class _RainRefreshState extends State<RainRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced(context)) _c.reset();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _refresh() {
    if (!_reduced(context)) _c.forward(from: 0);
    return widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _refresh,
          color: Palette.white,
          backgroundColor: widget.backgroundColor,
          edgeOffset: widget.edgeOffset,
          child: widget.child,
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: widget.edgeOffset + 180,
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => _c.isAnimating
                    ? CustomPaint(painter: RainDropsPainter(_c.value))
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 14 giot mua (vi tri co dinh theo chi so) roi tu tren xuong, mo dan.
class RainDropsPainter extends CustomPainter {
  RainDropsPainter(this.t);

  /// 0..1.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    for (var i = 0; i < 14; i++) {
      // Gia ngau nhien on dinh theo i.
      final double fx = ((i * 0.618034) % 1);
      final double delay = ((i * 0.381966) % 1) * 0.35;
      final double local = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (local <= 0 || local >= 1) continue;
      final double eased = Curves.easeInQuad.transform(local);
      final double x = size.width * (0.06 + 0.88 * fx);
      final double y = size.height * eased;
      final double len = 8 + 10 * eased;
      paint.color = Palette.rain.withValues(alpha: 0.75 * (1 - local));
      canvas.drawLine(Offset(x, y - len), Offset(x, y), paint);
    }
  }

  @override
  bool shouldRepaint(RainDropsPainter old) => old.t != t;
}
