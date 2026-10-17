import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Lich chop tat dinh theo seed: moi 5-12 s mot lan, loe 80-150 ms roi tat
/// dan trong 400 ms. Hinh tia set sinh mot lan (toa do tuong doi).
class LightningField {
  LightningField({int? seed}) {
    final math.Random r = math.Random(seed);
    double acc = 0;
    for (int i = 0; i < strikes; i++) {
      acc += randRange(r, 5, 12);
      start[i] = acc;
      flash[i] = randRange(r, 0.08, 0.15);
      doubleFlicker[i] = r.nextBool() ? 1 : 0;
      _bolts.add(_makeBolt(r));
    }
    period = acc + randRange(r, 5, 12);
  }

  /// So lan chop trong mot chu ky lap.
  static const int strikes = 16;

  /// Thoi gian tat dan sau khi loe (s).
  static const double fade = 0.4;

  final Float32List start = Float32List(strikes);
  final Float32List flash = Float32List(strikes);
  final Uint8List doubleFlicker = Uint8List(strikes);
  late final double period;

  /// Moi tia: danh sach polyline (toa do 0..1); polyline dau la than chinh.
  final List<List<Float32List>> _bolts = [];
  final List<Path> _paths = [];
  Size? _size;

  final Paint flashPaint = Paint();
  final Paint glowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 9
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
  final Paint corePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  /// Thoi diem lan chop dau tien (s) - tien cho golden test.
  double get firstStrikeTime => start[0];

  /// Thoi diem bat dau lan chop [i] trong chu ky dau.
  double strikeStart(int i) => start[i];

  /// Chi so lan chop dang hien (loe hoac tat dan) tai [t], null neu khong.
  int? activeStrike(double t) {
    final double tm = wrapDouble(t, period);
    for (int i = 0; i < strikes; i++) {
      if (tm < start[i]) return null;
      if (tm < start[i] + flash[i] + fade) return i;
    }
    return null;
  }

  /// Do sang 0..1 tai [t].
  double brightnessAt(double t) {
    final int? i = activeStrike(t);
    if (i == null) return 0;
    final double u = wrapDouble(t, period) - start[i];
    final double f = flash[i];
    if (u < f) {
      if (doubleFlicker[i] == 1 && u > f * 0.4 && u < f * 0.6) return 0.45;
      return 1;
    }
    final double v = 1 - (u - f) / fade;
    return (v * v).clamp(0.0, 1.0);
  }

  /// Path pixel cua tia [i] o kich thuoc hien tai.
  Path pathOf(int i, Size size) {
    if (_size != size) {
      _size = size;
      _paths.clear();
      for (final List<Float32List> bolt in _bolts) {
        final Path p = Path();
        for (final Float32List line in bolt) {
          for (int j = 0; j < line.length; j += 2) {
            final double x = line[j] * size.width;
            final double y = line[j + 1] * size.height;
            if (j == 0) {
              p.moveTo(x, y);
            } else {
              p.lineTo(x, y);
            }
          }
        }
        _paths.add(p);
      }
    }
    return _paths[i];
  }

  static List<Float32List> _makeBolt(math.Random r) {
    final double sx = randRange(r, 0.15, 0.85);
    final double ex = sx + randRange(r, -0.18, 0.18);
    final double ey = randRange(r, 0.45, 0.62);
    final Float32List main = _displace(r, sx, -0.02, ex, ey, 5, 0.09);
    final List<Float32List> lines = [main];
    final int branches = 1 + r.nextInt(2);
    for (int b = 0; b < branches; b++) {
      final int at = 2 * (6 + r.nextInt(14));
      final double bx = main[at];
      final double by = main[at + 1];
      final double dir = r.nextBool() ? 1 : -1;
      lines.add(
        _displace(
          r,
          bx,
          by,
          bx + dir * randRange(r, 0.08, 0.2),
          by + randRange(r, 0.08, 0.16),
          3,
          0.04,
        ),
      );
    }
    return lines;
  }

  /// Chia doi doan thang de quy, lech ngang ngau nhien -> 2^levels + 1 diem.
  static Float32List _displace(
    math.Random r,
    double x0,
    double y0,
    double x1,
    double y1,
    int levels,
    double rough,
  ) {
    List<double> pts = [x0, y0, x1, y1];
    double amp = rough;
    for (int l = 0; l < levels; l++) {
      final List<double> next = [];
      for (int i = 0; i < pts.length - 2; i += 2) {
        final double mx = (pts[i] + pts[i + 2]) / 2 + randRange(r, -amp, amp);
        final double my = (pts[i + 1] + pts[i + 3]) / 2;
        next.addAll([pts[i], pts[i + 1], mx, my]);
      }
      next.addAll([pts[pts.length - 2], pts[pts.length - 1]]);
      pts = next;
      amp *= 0.55;
    }
    return Float32List.fromList(pts);
  }
}

/// Chop: loe sang toan man hinh + tia set thu tuc.
class LightningPainter extends CustomPainter {
  LightningPainter({
    required this.time,
    required this.field,
    this.intensity = 1.0,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final LightningField field;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = time.value;
    final double a = field.brightnessAt(t) * intensity.clamp(0.3, 1.2);
    if (a <= 0.001) return;
    final int i = field.activeStrike(t)!;
    field.flashPaint.color = Color.fromRGBO(
      214,
      226,
      255,
      (0.32 * a).clamp(0.0, 1.0),
    );
    canvas.drawRect(Offset.zero & size, field.flashPaint);
    final Path bolt = field.pathOf(i, size);
    field.glowPaint.color = Color.fromRGBO(
      170,
      190,
      255,
      (0.55 * a).clamp(0.0, 1.0),
    );
    field.corePaint.color = Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0));
    canvas
      ..drawPath(bolt, field.glowPaint)
      ..drawPath(bolt, field.corePaint);
  }

  @override
  bool shouldRepaint(LightningPainter old) =>
      old.time != time || old.field != field || old.intensity != intensity;
}
