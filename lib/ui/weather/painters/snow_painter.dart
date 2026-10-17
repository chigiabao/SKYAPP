import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Trang thai bong tuyet cho 3 lop do sau (xa / giua / gan).
class SnowField {
  SnowField({int? seed}) {
    final math.Random r = math.Random(seed);
    for (int l = 0; l < 3; l++) {
      final int c = perLayer[l];
      final Float32List data = Float32List(c * 5);
      for (int i = 0; i < c; i++) {
        data[i * 5] = r.nextDouble(); // x0
        data[i * 5 + 1] = r.nextDouble(); // pha roi
        data[i * 5 + 2] = randRange(r, 6, 18); // bien do lac (px)
        data[i * 5 + 3] = randRange(r, 0.15, 0.45); // tan so lac (Hz)
        data[i * 5 + 4] = r.nextDouble() * kTau; // pha lac
      }
      flakes.add(data);
      points.add(Float32List(c * 2));
      paints.add(
        Paint()
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true
          ..strokeWidth = _sizes[l]
          ..maskFilter = l == 2
              ? const MaskFilter.blur(BlurStyle.normal, 0.9)
              : null,
      );
    }
  }

  /// So bong moi lop (xa, giua, gan).
  static const List<int> perLayer = [45, 40, 30];
  static const List<double> _sizes = [2.0, 3.2, 4.6];

  final List<Float32List> flakes = [];
  final List<Float32List> points = [];
  final List<Paint> paints = [];
}

/// Tuyet roi 3 lop: lac hinh sin, troi theo gio, lop gan to va nhanh hon.
class SnowPainter extends CustomPainter {
  SnowPainter({
    required this.time,
    required this.field,
    this.windSpeedKmh = 0,
    this.intensity = 1.0,
    this.quality = 1.0,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final SnowField field;
  final double windSpeedKmh;
  final double intensity;
  final double quality;

  static const List<double> _speeds = [22, 38, 60];
  static const List<double> _alphas = [0.5, 0.7, 0.92];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = time.value;
    final double inten = intensity.clamp(0.3, 1.5);
    final double w = size.width;
    final double h = size.height + 12;
    for (int l = 0; l < 3; l++) {
      final Float32List f = field.flakes[l];
      final Float32List p = field.points[l];
      final int c = SnowField.perLayer[l];
      final int n = scaledCount(c, quality);
      final double depth = (l + 1) / 3;
      final double speed = _speeds[l] * (0.7 + 0.3 * inten);
      final double drift = windSpeedKmh * 0.9 * depth;
      for (int i = 0; i < c; i++) {
        if (i >= n) {
          p[i * 2] = -100;
          p[i * 2 + 1] = -100;
          continue;
        }
        final double sway =
            f[i * 5 + 2] *
            depth *
            math.sin(kTau * f[i * 5 + 3] * t + f[i * 5 + 4]);
        p[i * 2] = wrapDouble(f[i * 5] * w + drift * t + sway, w);
        p[i * 2 + 1] = wrapDouble(f[i * 5 + 1] * h + speed * t, h) - 6;
      }
      field.paints[l].color = Color.fromRGBO(255, 255, 255, _alphas[l]);
      canvas.drawRawPoints(ui.PointMode.points, p, field.paints[l]);
    }
  }

  @override
  bool shouldRepaint(SnowPainter old) =>
      old.time != time ||
      old.field != field ||
      old.windSpeedKmh != windSpeedKmh ||
      old.intensity != intensity ||
      old.quality != quality;
}
