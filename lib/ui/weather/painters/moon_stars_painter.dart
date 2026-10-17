import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'painter_math.dart';

/// Trang thai bau troi sao: tao MOT lan (mang co dinh), dung lai moi khung.
class StarField {
  StarField({int? seed, this.count = 110}) {
    final math.Random r = math.Random(seed);
    for (int i = 0; i < count; i++) {
      x[i] = r.nextDouble();
      // Day sao hon o phia tren.
      y[i] = math.pow(r.nextDouble(), 1.35).toDouble() * 0.72;
      final double big = r.nextDouble();
      radius[i] = big > 0.93 ? randRange(r, 1.4, 1.9) : randRange(r, 0.5, 1.2);
      phase[i] = r.nextDouble() * kTau;
      period[i] = randRange(r, 1.0, 4.0);
      base[i] = randRange(r, 0.45, 0.95);
    }
  }

  /// So sao toi da (80-120).
  final int count;
  late final Float32List x = Float32List(count);
  late final Float32List y = Float32List(count);
  late final Float32List radius = Float32List(count);
  late final Float32List phase = Float32List(count);
  late final Float32List period = Float32List(count);
  late final Float32List base = Float32List(count);

  final Paint starPaint = Paint()..isAntiAlias = true;
  final Paint haloPaint = Paint()..isAntiAlias = true;
  final Paint moonHalo = Paint();
  final Paint moonBody = Paint();
  final Paint crater = Paint()..color = const Color(0x2E8E8670);
  final Paint shade = Paint()..color = const Color(0x2E1B2A55);
  final Path moonClip = Path();
  Size? _size;
  double _moonR = 0;

  void ensure(Size size, double moonR) {
    if (_size == size && _moonR == moonR) return;
    _size = size;
    _moonR = moonR;
    moonHalo.shader = ui.Gradient.radial(
      Offset.zero,
      moonR * 5,
      const [Color(0x40DCE4FF), Color(0x14B9C6FF), Color(0x00B9C6FF)],
      const [0.0, 0.4, 1.0],
    );
    moonBody.shader = ui.Gradient.radial(
      Offset(-moonR * 0.3, -moonR * 0.35),
      moonR * 1.4,
      const [Color(0xFFFFFDF4), Color(0xFFEDE8D6), Color(0xFFD8D2BE)],
      const [0.0, 0.6, 1.0],
    );
    moonClip
      ..reset()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: moonR));
  }
}

/// Sao lap lanh (chu ky ngau nhien 1-4 s) + trang co quang.
class MoonStarsPainter extends CustomPainter {
  MoonStarsPainter({
    required this.time,
    required this.field,
    this.quality = 1.0,
    this.showMoon = true,
    this.moonAnchor = const Offset(0.76, 0.13),
    this.starOpacity = 1.0,
    this.moonCenterPx,
    this.moonRadiusPx,
    this.moonOpacity = 1.0,
  }) : super(repaint: time);

  /// Ghi de vi tri / ban kinh trang (px) va do mo cua trang.
  final Offset? moonCenterPx;
  final double? moonRadiusPx;
  final double moonOpacity;

  final ValueListenable<double> time;
  final StarField field;
  final double quality;
  final bool showMoon;
  final Offset moonAnchor;

  /// Giam do sang sao (vd khi co may).
  final double starOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double moonR = moonRadiusPx ?? size.width * 0.062;
    field.ensure(size, moonR);
    final double t = time.value;
    final int n = math.max(
      (field.count * 0.73).round(),
      scaledCount(field.count, quality),
    );
    final Paint p = field.starPaint;
    final Paint h = field.haloPaint;
    for (int i = 0; i < n; i++) {
      final double tw =
          0.55 + 0.45 * math.sin(kTau * t / field.period[i] + field.phase[i]);
      final double a = (field.base[i] * tw * starOpacity).clamp(0.0, 1.0);
      final Offset c = Offset(
        field.x[i] * size.width,
        field.y[i] * size.height,
      );
      final double r = field.radius[i];
      if (r > 1.3) {
        h.color = Color.fromRGBO(220, 228, 255, a * 0.22);
        canvas.drawCircle(c, r * 3, h);
      }
      p.color = Color.fromRGBO(255, 255, 255, a);
      canvas.drawCircle(c, r, p);
    }

    if (!showMoon || moonOpacity <= 0) return;
    final bool fadedMoon = moonOpacity < 1;
    if (fadedMoon) {
      canvas.saveLayer(
        null,
        Paint()..color = Color.fromRGBO(0, 0, 0, moonOpacity),
      );
    }
    final double breath = 1 + 0.03 * math.sin(kTau * t / 8);
    canvas
      ..save()
      ..translate(
        moonCenterPx?.dx ?? size.width * moonAnchor.dx,
        moonCenterPx?.dy ?? size.height * moonAnchor.dy,
      )
      ..save()
      ..scale(breath)
      ..drawCircle(Offset.zero, moonR * 5, field.moonHalo)
      ..restore()
      ..drawCircle(Offset.zero, moonR, field.moonBody)
      ..save()
      ..clipPath(field.moonClip)
      ..drawCircle(
        Offset(moonR * 0.28, moonR * 0.1),
        moonR * 0.22,
        field.crater,
      )
      ..drawCircle(
        Offset(-moonR * 0.35, moonR * 0.38),
        moonR * 0.14,
        field.crater,
      )
      ..drawCircle(
        Offset(-moonR * 0.1, -moonR * 0.42),
        moonR * 0.1,
        field.crater,
      )
      ..drawCircle(
        Offset(moonR * 0.45, -moonR * 0.4),
        moonR * 0.08,
        field.crater,
      )
      // Bong toi nhe phia duoi trai tao cam giac khoi.
      ..drawCircle(Offset(moonR * 0.55, moonR * 0.55), moonR * 1.1, field.shade)
      ..restore()
      ..restore();
    if (fadedMoon) canvas.restore();
  }

  @override
  bool shouldRepaint(MoonStarsPainter old) =>
      old.time != time ||
      old.field != field ||
      old.quality != quality ||
      old.showMoon != showMoon ||
      old.moonAnchor != moonAnchor ||
      old.starOpacity != starOpacity ||
      old.moonCenterPx != moonCenterPx ||
      old.moonRadiusPx != moonRadiusPx ||
      old.moonOpacity != moonOpacity;
}

/// Lich sao bang tat dinh theo seed: moi 8-15 s mot vet, keo dai 0.9 s.
class ShootingStarSchedule {
  ShootingStarSchedule({int? seed}) {
    final math.Random r = math.Random(seed);
    double acc = 0;
    for (int i = 0; i < events; i++) {
      acc += randRange(r, 8, 15);
      start[i] = acc;
      x[i] = randRange(r, 0.25, 0.95);
      y[i] = randRange(r, 0.03, 0.30);
      angle[i] = randRange(r, 2.55, 2.85); // huong xuong - trai (rad)
      length[i] = randRange(r, 0.28, 0.42);
    }
    period = acc + randRange(r, 8, 15);
  }

  /// So su kien trong mot chu ky lap.
  static const int events = 24;

  /// Thoi luong mot vet (s).
  static const double duration = 0.9;

  final Float32List start = Float32List(events);
  final Float32List x = Float32List(events);
  final Float32List y = Float32List(events);
  final Float32List angle = Float32List(events);
  final Float32List length = Float32List(events);
  late final double period;

  final Paint paint = Paint()
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
  final Paint headPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

  /// Chi so su kien dang chay tai [t] (giay), null neu khong co.
  int? activeAt(double t) {
    final double tm = wrapDouble(t, period);
    for (int i = 0; i < events; i++) {
      final double s = start[i];
      if (tm < s) return null;
      if (tm < s + duration) return i;
    }
    return null;
  }

  /// Thoi diem bat dau su kien [i] trong chu ky dau.
  double startOf(int i) => start[i];
}

/// Ve sao bang theo [ShootingStarSchedule].
class ShootingStarPainter extends CustomPainter {
  ShootingStarPainter({required this.time, required this.schedule})
    : super(repaint: time);

  final ValueListenable<double> time;
  final ShootingStarSchedule schedule;

  static const int _segments = 7;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t = time.value;
    final int? i = schedule.activeAt(t);
    if (i == null) return;
    final double tm = wrapDouble(t, schedule.period);
    final double prog =
        ((tm - schedule.start[i]) / ShootingStarSchedule.duration).clamp(
          0.0,
          1.0,
        );
    final double eased = 1 - (1 - prog) * (1 - prog);
    final double dx = math.cos(schedule.angle[i]);
    final double dy = math.sin(schedule.angle[i]);
    final double travel = schedule.length[i] * size.width;
    final double hx = schedule.x[i] * size.width + dx * travel * eased;
    final double hy = schedule.y[i] * size.height + dy * travel * eased;
    final double tail = travel * 0.45 * math.min(1.0, prog * 3);
    final double fade = prog < 0.75 ? 1.0 : (1 - prog) / 0.25;
    final Paint p = schedule.paint;
    for (int s = 0; s < _segments; s++) {
      final double a0 = s / _segments;
      final double a1 = (s + 1) / _segments;
      p
        ..strokeWidth = 2.2 * (1 - a0 * 0.8)
        ..color = Color.fromRGBO(255, 255, 255, 0.85 * (1 - a0) * fade);
      canvas.drawLine(
        Offset(hx - dx * tail * a0, hy - dy * tail * a0),
        Offset(hx - dx * tail * a1, hy - dy * tail * a1),
        p,
      );
    }
    schedule.headPaint.color = Color.fromRGBO(255, 255, 255, 0.9 * fade);
    canvas.drawCircle(Offset(hx, hy), 2.2, schedule.headPaint);
  }

  @override
  bool shouldRepaint(ShootingStarPainter old) =>
      old.time != time || old.schedule != schedule;
}
