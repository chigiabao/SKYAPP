import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Loai mua.
enum RainKind {
  /// Mua phun: 60 hat ngan, cham, khong gon song.
  drizzle,

  /// Mua: 140 hat + gon song.
  rain,

  /// Mua to: 280 hat dai, nhanh + gon song.
  heavy,

  /// Mua tuyet: vet mua ngan xen hat bang.
  sleet,
}

/// Canh nao cua cac o chu nhat trong `splashTargets` duoc coi la mat "cham".
enum SplashEdge { top, bottom }

/// Trang thai hat mua: mang co dinh tao mot lan, bo dem ve dung lai.
class RainField {
  RainField({required this.kind, int? seed}) : maxCount = countFor(kind) {
    final math.Random r = math.Random(seed);
    x0 = Float32List(maxCount);
    phase = Float32List(maxCount);
    lenF = Float32List(maxCount);
    bucket = Uint8List(maxCount);
    slot = Uint16List(maxCount);
    final List<int> perBucket = [0, 0, 0];
    for (int i = 0; i < maxCount; i++) {
      x0[i] = r.nextDouble();
      phase[i] = r.nextDouble();
      lenF[i] = randRange(r, 0.75, 1.25);
      final int b = i % 3;
      bucket[i] = b;
      slot[i] = perBucket[b]++;
    }
    lines = [for (final int c in perBucket) Float32List(c * 4)];
    pellets = Float32List(maxCount * 2);
    droplets = Float32List(maxCount * 4);
    for (int b = 0; b < 3; b++) {
      linePaints[b]
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
    }
  }

  /// So hat toi da theo loai (60 / 140 / 280 / 130).
  static int countFor(RainKind kind) {
    switch (kind) {
      case RainKind.drizzle:
        return 60;
      case RainKind.rain:
        return 140;
      case RainKind.heavy:
        return 280;
      case RainKind.sleet:
        return 130;
    }
  }

  final RainKind kind;
  final int maxCount;
  late final Float32List x0;
  late final Float32List phase;
  late final Float32List lenF;
  late final Uint8List bucket;
  late final Uint16List slot;

  /// Bo dem toa do vach (4 float / hat) cho 3 lop do sau.
  late final List<Float32List> lines;
  late final Float32List pellets;
  late final Float32List droplets;

  final List<Paint> linePaints = [Paint(), Paint(), Paint()];
  final Paint pelletPaint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2.6
    ..color = const Color(0xD9F2F8FF);
  final Paint dropletPaint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.6;
  final Paint ripplePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.1;
}

/// Mua xien theo gio, gon song nho khi hat cham day man hinh hoac mep cac
/// the (`splashTargets`).
class RainPainter extends CustomPainter {
  RainPainter({
    required this.time,
    required this.field,
    this.windSpeedKmh = 0,
    this.intensity = 1.0,
    this.quality = 1.0,
    this.splashTargets,
    this.splashEdge = SplashEdge.bottom,
    this.color = const Color(0xFFDDEBFF),
  }) : super(
         repaint: splashTargets == null
             ? time
             : Listenable.merge([time, splashTargets]),
       );

  final ValueListenable<double> time;
  final RainField field;
  final double windSpeedKmh;

  /// 0.3 - 1.5: tang toc do, do dai va do dac vet mua.
  final double intensity;
  final double quality;

  /// Cac o chu nhat (toa do cua painter) ma mot phan hat mua se "cham" vao.
  final ValueListenable<List<Rect>>? splashTargets;
  final SplashEdge splashEdge;
  final Color color;

  static const double _splashDur = 0.3;

  double get _kindSpeed => switch (field.kind) {
    RainKind.drizzle => 0.5,
    RainKind.rain => 1.0,
    RainKind.heavy => 1.3,
    RainKind.sleet => 0.8,
  };

  double get _kindLen => switch (field.kind) {
    RainKind.drizzle => 11,
    RainKind.rain => 24,
    RainKind.heavy => 36,
    RainKind.sleet => 14,
  };

  /// Do xien dx/dy theo gio (gio duong -> hat nghieng sang phai).
  static double slopeFor(double windKmh) =>
      math.tan((windKmh / 80 * 0.45).clamp(-0.5, 0.5));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double w = size.width;
    final double h = size.height;
    final double t = time.value;
    final double inten = intensity.clamp(0.3, 1.5);
    final double k = slopeFor(windSpeedKmh);
    final double extra = k.abs() * h;
    final int n = scaledCount(field.maxCount, quality);
    final bool splashes = field.kind != RainKind.drizzle;
    final List<Rect>? targets = splashTargets?.value;

    for (int b = 0; b < 3; b++) {
      final double depth = b / 2;
      field.linePaints[b]
        ..strokeWidth =
            (field.kind == RainKind.drizzle ? 0.9 : 1.0) + depth * 0.9
        ..color = color.withValues(
          alpha: ((0.22 + 0.28 * depth) * (0.75 + 0.25 * inten)).clamp(
            0.0,
            1.0,
          ),
        );
    }

    int pelletN = 0;
    int dropletN = 0;
    final Float32List pel = field.pellets;
    final Float32List drp = field.droplets;

    for (int i = 0; i < field.maxCount; i++) {
      final int b = field.bucket[i];
      final Float32List buf = field.lines[b];
      final int o = field.slot[i] * 4;
      // Mac dinh: day ra ngoai man hinh (khong cap phat, kich thuoc co dinh).
      buf[o] = -100;
      buf[o + 1] = -100;
      buf[o + 2] = -100;
      buf[o + 3] = -100;
      if (i >= n) continue;

      final double depth = b / 2;
      final bool pellet = field.kind == RainKind.sleet && i.isOdd;
      final double speed =
          h *
          (0.9 + 0.7 * depth) *
          _kindSpeed *
          (0.6 + 0.4 * inten) *
          (pellet ? 0.75 : 1);
      final double len = pellet
          ? 0
          : _kindLen *
                (0.6 + 0.4 * depth) *
                (0.7 + 0.3 * inten) *
                field.lenF[i];
      final double xBase = field.x0[i] * (w + extra) - (k > 0 ? extra : 0);

      double impactY = h;
      if (targets != null && splashes && i % 3 == 0) {
        for (final Rect r in targets) {
          final double edgeY = splashEdge == SplashEdge.bottom
              ? r.bottom
              : r.top;
          if (edgeY <= 0 || edgeY >= impactY) continue;
          final double xi = xBase + edgeY * k;
          if (xi >= r.left && xi <= r.right) impactY = edgeY;
        }
      }
      final double fallDur = impactY / speed;
      final double cycle = fallDur + (splashes ? _splashDur : 0);
      final double local = wrapDouble(t + field.phase[i] * cycle, cycle);

      if (local < fallDur) {
        final double head = local * speed;
        if (pellet) {
          pel[pelletN * 2] = xBase + head * k;
          pel[pelletN * 2 + 1] = head;
          pelletN++;
        } else {
          final double tail = head - len;
          buf[o] = xBase + tail * k;
          buf[o + 1] = tail;
          buf[o + 2] = xBase + head * k;
          buf[o + 3] = head;
        }
      } else if (splashes) {
        final double age = (local - fallDur) / _splashDur;
        final double cx = xBase + impactY * k;
        final double a = (1 - age) * (0.35 + 0.25 * depth);
        final double rw = (3 + 11 * age) * (0.7 + 0.3 * inten);
        field.ripplePaint.color = color.withValues(alpha: a);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx, impactY),
            width: rw * 2,
            height: rw * 0.6,
          ),
          field.ripplePaint,
        );
        final double lift = 16 * age * (1 - age) * (0.6 + 0.4 * inten);
        drp[dropletN * 4] = cx - rw * 0.8;
        drp[dropletN * 4 + 1] = impactY - lift;
        drp[dropletN * 4 + 2] = cx + rw * 0.8;
        drp[dropletN * 4 + 3] = impactY - lift * 0.8;
        dropletN++;
      }
    }

    for (int b = 0; b < 3; b++) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        field.lines[b],
        field.linePaints[b],
      );
    }
    // Phan con lai cua bo dem diem duoc day ra ngoai man hinh.
    for (int j = pelletN * 2; j < pel.length; j++) {
      pel[j] = -100;
    }
    for (int j = dropletN * 4; j < drp.length; j++) {
      drp[j] = -100;
    }
    if (pelletN > 0) {
      canvas.drawRawPoints(ui.PointMode.points, pel, field.pelletPaint);
    }
    if (dropletN > 0) {
      field.dropletPaint.color = color.withValues(alpha: 0.5);
      canvas.drawRawPoints(ui.PointMode.points, drp, field.dropletPaint);
    }
  }

  @override
  bool shouldRepaint(RainPainter old) =>
      old.time != time ||
      old.field != field ||
      old.windSpeedKmh != windSpeedKmh ||
      old.intensity != intensity ||
      old.quality != quality ||
      old.splashTargets != splashTargets ||
      old.splashEdge != splashEdge ||
      old.color != color;
}
