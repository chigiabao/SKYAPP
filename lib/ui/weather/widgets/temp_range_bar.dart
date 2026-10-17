/// Thanh khoang nhiet do kieu iOS: ray mo + doan mau tu thap nhat den cao
/// nhat cua ngay, tren thang chung [scaleMin]..[scaleMax] cua ca 7 ngay.
library;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Toan hoc cua thanh (tach rieng de test).
@immutable
class TempRangeGeometry {
  const TempRangeGeometry({
    required this.scaleMin,
    required this.scaleMax,
    required this.low,
    required this.high,
    this.current,
  });

  final double scaleMin;
  final double scaleMax;
  final double low;
  final double high;
  final double? current;

  /// Vi tri 0..1 cua [v] tren thang. Thang suy bien (min == max) -> 0.5.
  double fraction(double v) {
    final double span = scaleMax - scaleMin;
    if (span <= 0) return 0.5;
    return ((v - scaleMin) / span).clamp(0.0, 1.0);
  }

  /// Dau doan (0..1).
  double get start => fraction(low < high ? low : high);

  /// Cuoi doan (0..1).
  double get end => fraction(low < high ? high : low);

  /// Vi tri cham "hien tai" (0..1), null neu khong co. Gioi han trong doan
  /// cua ngay de cham luon nam tren doan mau.
  double? get dot {
    final double? c = current;
    if (c == null) return null;
    final double f = fraction(c);
    return f.clamp(start, end);
  }

  /// Toa do x (px) cua [f] tren thanh rong [width], tinh ca ban kinh dau tron
  /// [inset] o hai dau.
  static double xFor(double f, double width, double inset) =>
      inset + f * (width - 2 * inset);
}

/// Mau theo nhiet do (°C) tren thang chung: mat -> diu -> am -> nong ->
/// rat nong.
Color colorForTemp(double c) {
  const List<(double, Color)> stops = [
    (18, Palette.tempCool),
    (23, Palette.tempMild),
    (28, Palette.tempWarm),
    (32, Palette.tempHot),
    (36, Palette.tempVeryHot),
  ];
  if (c <= stops.first.$1) return stops.first.$2;
  for (int i = 1; i < stops.length; i++) {
    if (c <= stops[i].$1) {
      final (double t0, Color c0) = stops[i - 1];
      final (double t1, Color c1) = stops[i];
      return Color.lerp(c0, c1, (c - t0) / (t1 - t0))!;
    }
  }
  return stops.last.$2;
}

/// Thanh khoang nhiet do. Nhiet do truyen vao luon la °C (mau theo °C).
class TempRangeBar extends StatelessWidget {
  const TempRangeBar({
    super.key,
    required this.geometry,
    this.height = 4,
    this.semanticsLabel,
  });

  final TempRangeGeometry geometry;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final double h = height + 8;
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: SizedBox(
        height: h,
        width: double.infinity,
        child: CustomPaint(
          painter: _TempRangePainter(geometry: geometry, barHeight: height),
        ),
      ),
    );
  }
}

class _TempRangePainter extends CustomPainter {
  _TempRangePainter({required this.geometry, required this.barHeight});

  final TempRangeGeometry geometry;
  final double barHeight;

  final Paint _track = Paint()..color = Palette.track;
  final Paint _seg = Paint();
  final Paint _dot = Paint()..color = Palette.white;
  final Paint _dotRing = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = Palette.dotRing;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = barHeight / 2;
    final double cy = size.height / 2;
    final RRect track = RRect.fromLTRBR(
      0,
      cy - r,
      size.width,
      cy + r,
      Radius.circular(r),
    );
    canvas.drawRRect(track, _track);

    final double x0 = TempRangeGeometry.xFor(geometry.start, size.width, r);
    final double x1 = TempRangeGeometry.xFor(geometry.end, size.width, r);
    final Rect segRect = Rect.fromLTRB(x0 - r, cy - r, x1 + r, cy + r);
    // Gradient theo nhiet do thuc: mau o hai dau = mau cua low / high.
    final double lo = geometry.low < geometry.high
        ? geometry.low
        : geometry.high;
    final double hi = geometry.low < geometry.high
        ? geometry.high
        : geometry.low;
    _seg.shader = LinearGradient(
      colors: [colorForTemp(lo), colorForTemp((lo + hi) / 2), colorForTemp(hi)],
    ).createShader(segRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(segRect, Radius.circular(r)),
      _seg,
    );

    final double? d = geometry.dot;
    if (d != null) {
      final double x = TempRangeGeometry.xFor(d, size.width, r);
      final double dr = r + 1.5;
      canvas.drawCircle(Offset(x, cy), dr, _dot);
      canvas.drawCircle(Offset(x, cy), dr, _dotRing);
    }
  }

  @override
  bool shouldRepaint(_TempRangePainter old) =>
      old.geometry.scaleMin != geometry.scaleMin ||
      old.geometry.scaleMax != geometry.scaleMax ||
      old.geometry.low != geometry.low ||
      old.geometry.high != geometry.high ||
      old.geometry.current != geometry.current ||
      old.barHeight != barHeight;
}
