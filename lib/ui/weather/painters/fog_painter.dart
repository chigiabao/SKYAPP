import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';
import 'sprite.dart';

/// Trang thai cac dai suong (4 dai, moi dai 6 khoi mo).
class FogField {
  FogField({int? seed}) {
    final math.Random r = math.Random(seed);
    for (int b = 0; b < bands; b++) {
      y[b] = 0.18 + 0.78 * (b + randRange(r, 0.0, 0.6)) / bands;
      thickness[b] = randRange(r, 0.10, 0.18);
      speed[b] = randRange(r, 3, 9) * (b.isEven ? 1 : -1);
      alpha[b] = randRange(r, 0.10, 0.17);
      breath[b] = r.nextDouble() * kTau;
      for (int p = 0; p < puffs; p++) {
        px[b * puffs + p] = (p + randRange(r, -0.2, 0.2)) / puffs;
        pw[b * puffs + p] = randRange(r, 0.55, 0.85);
        py[b * puffs + p] = randRange(r, -0.25, 0.25);
      }
    }
  }

  static const int bands = 4;
  static const int puffs = 6;

  final Float32List y = Float32List(bands);
  final Float32List thickness = Float32List(bands);
  final Float32List speed = Float32List(bands);
  final Float32List alpha = Float32List(bands);
  final Float32List breath = Float32List(bands);
  final Float32List px = Float32List(bands * puffs);
  final Float32List pw = Float32List(bands * puffs);
  final Float32List py = Float32List(bands * puffs);

  final Paint paint = Paint()..filterQuality = FilterQuality.low;
  double _sigma = -1;
  Size? _size;
  Color? _color;

  /// Sprite moi khoi (oval blur, mau dac); alpha dat qua [paint] moi khung.
  final List<Sprite?> _sprites = List<Sprite?>.filled(bands * puffs, null);

  void ensure(Size size, Color opaque) {
    if (size == _size && opaque == _color) return;
    _size = size;
    _color = opaque;
    _sigma = size.height * 0.022;
    dispose();
  }

  /// Sprite khoi [k] kich thuoc [w] x [h] (tam o goc toa do).
  Sprite spriteOf(int k, double w, double h) => _sprites[k] ??= Sprite.record(
    Rect.fromCenter(
      center: Offset.zero,
      width: w,
      height: h,
    ).inflate(_sigma * 3),
    (c) => c.drawOval(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      Paint()
        ..color = _color!
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, _sigma),
    ),
  );

  /// Giai phong anh sprite.
  void dispose() {
    for (int i = 0; i < _sprites.length; i++) {
      _sprites[i]?.dispose();
      _sprites[i] = null;
    }
  }
}

/// Cac dai suong trong suot truot rat cham. `warm = true` -> mu kho (haze)
/// mau am.
class FogPainter extends CustomPainter {
  FogPainter({
    required this.time,
    required this.field,
    this.warm = false,
    this.color,
    this.windSpeedKmh = 0,
    this.intensity = 1.0,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final FogField field;
  final bool warm;

  /// Mau suong; alpha = do dac toi da cua mot dai. null -> mau mac dinh
  /// (xam lanh, hoac am neu [warm]).
  final Color? color;
  final double windSpeedKmh;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Color base =
        color ?? (warm ? const Color(0x2BECD6B2) : const Color(0x2BE6EBF0));
    field.ensure(size, base.withValues(alpha: 1));
    final double t = time.value;
    final double w = size.width;
    final double span = w * 2;
    final double windBoost = 1 + windSpeedKmh.clamp(0.0, 60.0) / 30;
    final double inten = intensity.clamp(0.3, 1.5);
    for (int band = 0; band < FogField.bands; band++) {
      final double cy = field.y[band] * size.height;
      final double th = field.thickness[band] * size.height;
      final double a =
          base.a *
          field.alpha[band] /
          0.17 *
          math.min(inten, 1.0) *
          (0.85 + 0.15 * math.sin(kTau * t / 14 + field.breath[band]));
      field.paint.color = Color.fromRGBO(0, 0, 0, a.clamp(0.0, 1.0));
      final double shift = field.speed[band] * windBoost * t;
      for (int p = 0; p < FogField.puffs; p++) {
        final int k = band * FogField.puffs + p;
        final double pwPx = field.pw[k] * w;
        final double x = wrapDouble(field.px[k] * span + shift, span) - w * 0.5;
        field
            .spriteOf(k, pwPx, th)
            .paint(canvas, Offset(x, cy + field.py[k] * th), field.paint);
      }
    }
  }

  @override
  bool shouldRepaint(FogPainter old) =>
      old.time != time ||
      old.field != field ||
      old.warm != warm ||
      old.color != color ||
      old.windSpeedKmh != windSpeedKmh ||
      old.intensity != intensity;
}
