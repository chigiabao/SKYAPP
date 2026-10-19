import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';
import 'sprite.dart';

/// Trang thai cac dam may: hinh dang sinh mot lan theo seed (don vi tuong
/// doi), Path pixel chi dung lai khi kich thuoc man hinh doi. Moi dam may
/// (than + vet sang, da blur) duoc ve san thanh [Sprite]; moi khung chi dich
/// chuyen anh.
class CloudField {
  CloudField({int? seed, this.maxLayers = 4, this.maxPerLayer = 4}) {
    final math.Random r = math.Random(seed);
    final int n = maxLayers * maxPerLayer;
    baseX = Float32List(n);
    baseY = Float32List(n);
    scale = Float32List(n);
    for (int l = 0; l < maxLayers; l++) {
      for (int i = 0; i < maxPerLayer; i++) {
        final int k = l * maxPerLayer + i;
        // Rai deu theo hang ngang, them nhieu de khong thang hang.
        baseX[k] = (i + randRange(r, 0.0, 0.7)) / maxPerLayer;
        baseY[k] = randRange(r, 0.0, 1.0);
        scale[k] = randRange(r, 0.8, 1.2);
        final List<double> puffs = <double>[];
        final int count = 5 + r.nextInt(3);
        for (int p = 0; p < count; p++) {
          final double fx = 0.12 + 0.76 * p / (count - 1);
          final double mid = 1 - (fx - 0.5).abs() * 1.6;
          final double rad = (0.13 + 0.14 * mid) * randRange(r, 0.85, 1.15);
          puffs
            ..add(fx + randRange(r, -0.04, 0.04))
            ..add(0.30 - rad * randRange(r, 0.35, 0.75))
            ..add(rad);
        }
        _shapes.add(Float32List.fromList(puffs));
      }
    }
  }

  final int maxLayers;
  final int maxPerLayer;
  late final Float32List baseX;
  late final Float32List baseY;
  late final Float32List scale;
  final List<Float32List> _shapes = [];

  final List<Path> _paths = [];
  final List<double> _widths = [];
  final Paint bodyPaint = Paint();
  final Paint lightPaint = Paint();
  Size? _size;
  double _dense = -1;

  final List<Sprite?> _sprites = [];
  Color? _spriteColor;
  int _spriteLayers = -1;

  /// Xoa sprite (khi doi kich thuoc / mau / so lop).
  void _clearSprites() {
    for (final Sprite? s in _sprites) {
      s?.dispose();
    }
    _sprites.clear();
  }

  /// Giai phong anh sprite.
  void dispose() => _clearSprites();

  /// Sprite cua may [k] (ve mot lan, cache den khi doi kich thuoc / mau).
  Sprite spriteOf(int k, Color color, int nLayers, double sigma) {
    if (_spriteColor != color || _spriteLayers != nLayers) {
      _clearSprites();
      _spriteColor = color;
      _spriteLayers = nLayers;
    }
    if (_sprites.isEmpty) {
      _sprites.addAll(List<Sprite?>.filled(maxLayers * maxPerLayer, null));
    }
    return _sprites[k] ??= _record(k, sigma);
  }

  Sprite _record(int k, double sigma) {
    final double w = _widths[k];
    final Path path = _paths[k];
    final Rect b = path.getBounds();
    final Rect lb = Rect.fromLTRB(
      b.left * 0.92,
      b.top * 0.92 - w * 0.045,
      b.right * 0.92,
      b.bottom * 0.92 - w * 0.045,
    );
    final Rect bounds = b.expandToInclude(lb).inflate(sigma * 1.4 * 3);
    return Sprite.record(bounds, (c) {
      c
        ..drawPath(path, bodyPaint)
        ..translate(0, -w * 0.045)
        ..scale(0.92)
        ..drawPath(path, lightPaint);
    });
  }

  /// Chieu rong (px) cua may [k] o kich thuoc hien tai.
  double widthOf(int k) => _widths[k];

  /// Path (px, goc tai mep trai-tren cua may) cua may [k].
  Path pathOf(int k) => _paths[k];

  /// Dung lai Path khi kich thuoc / do day thay doi.
  void ensure(Size size, double denseFactor) {
    if (_size == size && _dense == denseFactor) return;
    _size = size;
    _dense = denseFactor;
    _paths.clear();
    _widths.clear();
    _clearSprites();
    for (int l = 0; l < maxLayers; l++) {
      for (int i = 0; i < maxPerLayer; i++) {
        final int k = l * maxPerLayer + i;
        final double w =
            size.width *
            (0.48 + 0.16 * l) *
            scale[k] *
            (0.85 + 0.35 * denseFactor);
        final Path path = Path();
        final Float32List s = _shapes[k];
        for (int p = 0; p < s.length; p += 3) {
          path.addOval(
            Rect.fromCircle(
              center: Offset(s[p] * w, s[p + 1] * w),
              radius: s[p + 2] * w,
            ),
          );
        }
        // De phang phia duoi.
        path.addRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.08, w * 0.17, w * 0.84, w * 0.15),
            Radius.circular(w * 0.075),
          ),
        );
        _paths.add(path);
        _widths.add(w);
      }
    }
  }
}

/// May mem nhieu lop parallax. Lop xa nho, mo, cham; lop gan lon, dac, nhanh.
/// Toc do ty le voi gio.
class CloudLayerPainter extends CustomPainter {
  CloudLayerPainter({
    required this.time,
    required this.field,
    required this.color,
    this.layers = 3,
    this.density = 0.6,
    this.windSpeedKmh = 0,
    this.quality = 1.0,
    this.top = 0.02,
    this.bottom = 0.55,
  }) : assert(layers >= 1 && layers <= 4),
       super(repaint: time);

  final ValueListenable<double> time;
  final CloudField field;

  /// Mau may; alpha = do dac toi da cua mot lop.
  final Color color;

  /// So lop parallax (1-4).
  final int layers;

  /// Mat do 0..1 (so may moi lop + kich thuoc).
  final double density;
  final double windSpeedKmh;
  final double quality;

  /// Vung doc chua may (ty le chieu cao).
  final double top;
  final double bottom;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || color.a == 0) return;
    final double d = density.clamp(0.0, 1.0);
    field.ensure(size, d);
    final double t = time.value;
    final int perLayer = math
        .max(1, (field.maxPerLayer * d * quality.clamp(0.35, 1.0)).ceil())
        .clamp(1, field.maxPerLayer);
    final double wind = windSpeedKmh.clamp(0.0, 120.0);
    final int nLayers = layers.clamp(1, field.maxLayers);

    for (int l = 0; l < nLayers; l++) {
      final double depth = nLayers == 1 ? 1.0 : l / (nLayers - 1);
      final double alpha = color.a * (0.55 + 0.45 * depth);
      final double speed = (4 + wind * 0.6) * (0.5 + 0.7 * depth);
      final double sigma = size.width * (0.022 - 0.01 * depth);
      field.bodyPaint
        ..color = color.withValues(alpha: alpha * 0.75)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);
      field.lightPaint
        ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha * 0.32)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma * 1.4);
      final double bandTop =
          size.height * (top + (bottom - top) * depth * 0.55);
      final double bandH = size.height * (bottom - top) * 0.45;
      for (int i = 0; i < perLayer; i++) {
        final int k = l * field.maxPerLayer + i;
        final double w = field.widthOf(k);
        final double span = size.width + w * 1.2;
        final double x =
            wrapDouble(field.baseX[k] * span + speed * t, span) - w * 0.6;
        final double y = bandTop + field.baseY[k] * bandH - w * 0.12;
        field.spriteOf(k, color, nLayers, sigma).paint(canvas, Offset(x, y));
      }
    }
  }

  @override
  bool shouldRepaint(CloudLayerPainter old) =>
      old.time != time ||
      old.field != field ||
      old.color != color ||
      old.layers != layers ||
      old.density != density ||
      old.windSpeedKmh != windSpeedKmh ||
      old.quality != quality ||
      old.top != top ||
      old.bottom != bottom;
}
