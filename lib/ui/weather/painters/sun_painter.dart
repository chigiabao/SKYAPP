import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Bo nho dem cua [SunPainter]: Paint / Path / shader chi tao lai khi kich
/// thuoc thay doi, khong cap phat moi khung hinh.
class SunPaintCache {
  Size? _size;
  double _radius = 0;
  final Paint glowPaint = Paint();
  final Paint rayPaint = Paint();
  final Paint corePaint = Paint();
  final Paint rimPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
  final Path rays = Path();

  /// So tia sang.
  static const int rayCount = 12;

  void ensure(Size size, double radius) {
    if (_size == size && _radius == radius) return;
    _size = size;
    _radius = radius;
    final double r = radius;
    glowPaint.shader = ui.Gradient.radial(
      Offset.zero,
      r * 4.2,
      const [Color(0x8CFFF4CC), Color(0x40FFE08A), Color(0x00FFE08A)],
      const [0.0, 0.35, 1.0],
    );
    rayPaint.shader = ui.Gradient.radial(
      Offset.zero,
      r * 2.6,
      const [Color(0x66FFF3C4), Color(0x33FFE6A0), Color(0x00FFE6A0)],
      const [0.4, 0.65, 1.0],
    );
    corePaint.shader = ui.Gradient.radial(
      Offset(-r * 0.25, -r * 0.25),
      r * 1.3,
      const [Color(0xFFFFFFFF), Color(0xFFFFF2B8), Color(0xFFFFD45C)],
      const [0.0, 0.45, 1.0],
    );
    rimPaint.color = const Color(0x66FFF6D8);
    rays.reset();
    for (int i = 0; i < rayCount; i++) {
      final double a = kTau * i / rayCount;
      const double half = 0.06;
      final double inner = r * 1.15;
      final double outer = r * (i.isEven ? 2.55 : 2.0);
      rays
        ..moveTo(math.cos(a - half) * inner, math.sin(a - half) * inner)
        ..lineTo(math.cos(a) * outer, math.sin(a) * outer)
        ..lineTo(math.cos(a + half) * inner, math.sin(a + half) * inner)
        ..close();
    }
  }
}

/// Mat troi: quang sang "tho" 1.0 - 1.08 chu ky 6 s, tia xoay 60 s/vong.
class SunPainter extends CustomPainter {
  SunPainter({
    required this.time,
    required this.cache,
    this.anchor = const Offset(0.80, 0.12),
    this.radiusFactor = 0.085,
    this.opacity = 1.0,
    this.centerPx,
    this.radiusPx,
  }) : super(repaint: time);

  /// Ghi de vi tri tam (px) - vd. de mat troi tranh chu o dau trang.
  final Offset? centerPx;

  /// Ghi de ban kinh (px).
  final double? radiusPx;

  /// Thoi gian (giay). Dung ValueNotifier co dinh de ve mot khung (golden).
  final ValueListenable<double> time;
  final SunPaintCache cache;

  /// Vi tri tam (ty le theo kich thuoc).
  final Offset anchor;

  /// Ban kinh = radiusFactor * chieu rong.
  final double radiusFactor;

  /// Do mo tong the (vd mat troi mo trong mu).
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;
    final double r = radiusPx ?? size.width * radiusFactor;
    cache.ensure(size, r);
    final double t = time.value;
    final double breath = 1.04 + 0.04 * math.sin(kTau * t / 6);
    final double rot = kTau * wrapDouble(t, 60) / 60;

    final bool faded = opacity < 1;
    if (faded) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    canvas
      ..save()
      ..translate(
        centerPx?.dx ?? size.width * anchor.dx,
        centerPx?.dy ?? size.height * anchor.dy,
      )
      ..save()
      ..scale(breath)
      ..drawCircle(Offset.zero, r * 4.2, cache.glowPaint)
      ..restore()
      ..save()
      ..rotate(rot)
      ..drawPath(cache.rays, cache.rayPaint)
      ..restore()
      ..drawCircle(Offset.zero, r * 1.06, cache.rimPaint)
      ..drawCircle(Offset.zero, r, cache.corePaint)
      ..restore();
    if (faded) canvas.restore();
  }

  @override
  bool shouldRepaint(SunPainter old) =>
      old.time != time ||
      old.cache != cache ||
      old.anchor != anchor ||
      old.radiusFactor != radiusFactor ||
      old.opacity != opacity ||
      old.centerPx != centerPx ||
      old.radiusPx != radiusPx;
}
