import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Trang thai cac vet gio (mang co dinh, tao mot lan).
class WindField {
  WindField({int? seed, this.count = 18}) {
    final math.Random r = math.Random(seed);
    for (int i = 0; i < count; i++) {
      y[i] = randRange(r, 0.08, 0.92);
      length[i] = randRange(r, 0.18, 0.38);
      speed[i] = randRange(r, 0.7, 1.3);
      phase[i] = r.nextDouble();
      amp[i] = randRange(r, 3, 9);
      width[i] = randRange(r, 1.0, 2.0);
    }
  }

  final int count;
  late final Float32List y = Float32List(count);
  late final Float32List length = Float32List(count);
  late final Float32List speed = Float32List(count);
  late final Float32List phase = Float32List(count);
  late final Float32List amp = Float32List(count);
  late final Float32List width = Float32List(count);

  final Path path = Path();
  final Paint paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
}

/// Vet gio mong luon song, toc do ty le voi gio.
class WindPainter extends CustomPainter {
  WindPainter({
    required this.time,
    required this.field,
    this.windSpeedKmh = 40,
    this.quality = 1.0,
    this.color = const Color(0xFFFFFFFF),
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final WindField field;
  final double windSpeedKmh;
  final double quality;
  final Color color;

  static const int _samples = 9;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = time.value;
    final double wind = windSpeedKmh.clamp(10.0, 120.0);
    final int n = scaledCount(field.count, quality);
    final Path path = field.path;
    final Paint p = field.paint;
    for (int i = 0; i < n; i++) {
      final double len = field.length[i] * size.width;
      final double span = size.width + len * 2;
      final double v = (90 + wind * 5) * field.speed[i];
      final double head = wrapDouble(field.phase[i] * span + v * t, span) - len;
      final double prog = (head + len) / span;
      final double env = math.sin(math.pi * prog.clamp(0.0, 1.0));
      if (env <= 0.02) continue;
      final double y0 = field.y[i] * size.height;
      path.reset();
      for (int s = 0; s <= _samples; s++) {
        final double f = s / _samples;
        final double x = head - len * (1 - f);
        final double y =
            y0 +
            field.amp[i] *
                math.sin(kTau * (x / size.width) * 1.4 + field.phase[i] * kTau);
        if (s == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      p
        ..strokeWidth = field.width[i]
        ..color = color.withValues(alpha: 0.28 * env);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(WindPainter old) =>
      old.time != time ||
      old.field != field ||
      old.windSpeedKmh != windSpeedKmh ||
      old.quality != quality ||
      old.color != color;
}
