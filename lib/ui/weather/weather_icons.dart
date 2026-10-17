/// Icon thoi tiet ve bang CustomPainter, dong bo mau voi [SceneTheme].
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'weather_scene.dart';

/// Icon thoi tiet theo canh. Ve trong luoi 24x24 roi phong to, net o 16-64 px.
///
/// [color] != null -> icon mot mau; null -> nhieu mau: may / trang theo
/// [SceneTheme.iconColor], hat mua theo [SceneTheme.accent], mat troi vang.
class WeatherIcon extends StatelessWidget {
  const WeatherIcon({
    super.key,
    required this.scene,
    this.size = 28,
    this.color,
    this.semanticLabel,
  });

  /// Icon tu ma WMO (dung chung [resolveScene], khong co gio / tam nhin).
  WeatherIcon.fromCode(
    int? code, {
    super.key,
    required bool isDay,
    this.size = 28,
    this.color,
    this.semanticLabel,
  }) : scene = resolveScene(weatherCode: code, isDay: isDay);

  final WeatherScene scene;
  final double size;
  final Color? color;

  /// Nhan doc cho trinh doc man hinh (mac dinh: [WeatherSceneX.label]).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final SceneTheme th = SceneTheme.of(scene);
    return Semantics(
      label: semanticLabel ?? scene.label,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: WeatherIconPainter(
          scene: scene,
          primary: color ?? th.iconColor,
          accent:
              color ??
              (scene == WeatherScene.thunderstorm
                  // Accent cua canh dong la mau tia set; giot mua dung xanh.
                  ? const Color(0xFF7CC4FF)
                  : th.accent),
          sun: color ?? const Color(0xFFFFD45C),
          bolt: color ?? const Color(0xFFFFE066),
        ),
      ),
    );
  }
}

/// Painter cua [WeatherIcon] (cong khai de dung trong canvas khac).
class WeatherIconPainter extends CustomPainter {
  WeatherIconPainter({
    required this.scene,
    required this.primary,
    required this.accent,
    required this.sun,
    required this.bolt,
  });

  final WeatherScene scene;
  final Color primary;
  final Color accent;
  final Color sun;
  final Color bolt;

  final Paint _fill = Paint()..isAntiAlias = true;
  final Paint _stroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _knock = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..blendMode = BlendMode.clear;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double s = size.shortestSide / 24;
    canvas
      ..save()
      ..translate((size.width - 24 * s) / 2, (size.height - 24 * s) / 2)
      ..scale(s)
      ..saveLayer(const Rect.fromLTWH(-2, -2, 28, 28), Paint());
    // Net toi thieu ~1.2 px vat ly khi icon nho.
    final double minStroke = 1.2 / s;
    double sw(double v) => math.max(v, minStroke);

    switch (scene) {
      case WeatherScene.clearDay:
        _sun(canvas, const Offset(12, 12), 4.6, 2.2, 8.6, sw(1.8));
      case WeatherScene.clearNight:
        _moon(canvas, const Offset(12, 12), 7.5);
      case WeatherScene.partlyCloudyDay:
        _sun(canvas, const Offset(9, 8.5), 3.4, 1.6, 6.6, sw(1.5));
        _cloud(canvas, const Rect.fromLTWH(6, 9, 16, 9.6));
      case WeatherScene.partlyCloudyNight:
        _moon(canvas, const Offset(9, 8.5), 5.4);
        _cloud(canvas, const Rect.fromLTWH(6, 9, 16, 9.6));
      case WeatherScene.cloudy:
        _cloud(canvas, const Rect.fromLTWH(2, 6, 20, 12));
      case WeatherScene.overcast:
        _cloud(
          canvas,
          const Rect.fromLTWH(8, 3, 14, 8.4),
          color: primary.withValues(alpha: primary.a * 0.6),
        );
        _cloud(canvas, const Rect.fromLTWH(2, 8, 19, 11.4));
      case WeatherScene.drizzle:
        _cloud(canvas, const Rect.fromLTWH(2, 2.5, 20, 12));
        _fill.color = accent;
        for (final Offset o in const [
          Offset(8, 18),
          Offset(12, 20.5),
          Offset(16, 18),
        ]) {
          canvas.drawCircle(o, math.max(1.25, minStroke * 0.6), _fill);
        }
      case WeatherScene.rain:
        _cloud(canvas, const Rect.fromLTWH(2, 2.5, 20, 12));
        _drops(canvas, 3, 3.4, sw(1.7));
      case WeatherScene.heavyRain:
        _cloud(canvas, const Rect.fromLTWH(2, 2, 20, 12));
        _drops(canvas, 4, 5, sw(1.7));
      case WeatherScene.thunderstorm:
        _cloud(canvas, const Rect.fromLTWH(2, 2, 20, 12));
        _bolt(canvas);
        _stroke
          ..color = accent
          ..strokeWidth = sw(1.5);
        canvas
          ..drawLine(const Offset(7.5, 16.5), const Offset(6.6, 19), _stroke)
          ..drawLine(const Offset(17.5, 16.5), const Offset(16.6, 19), _stroke);
      case WeatherScene.snow:
        _cloud(canvas, const Rect.fromLTWH(2, 2.5, 20, 12));
        _flake(canvas, const Offset(8, 18.6), 2.3, sw(1.3));
        _flake(canvas, const Offset(16, 18.6), 2.3, sw(1.3));
        _flake(canvas, const Offset(12, 21.2), 1.8, sw(1.2));
      case WeatherScene.sleet:
        _cloud(canvas, const Rect.fromLTWH(2, 2.5, 20, 12));
        _stroke
          ..color = accent
          ..strokeWidth = sw(1.7);
        canvas.drawLine(const Offset(9, 16.5), const Offset(8, 20.5), _stroke);
        _flake(canvas, const Offset(15.5, 18.8), 2.3, sw(1.3));
      case WeatherScene.fog:
        _cloud(canvas, const Rect.fromLTWH(4, 2, 16, 9.6));
        _lines(canvas, const [14.5, 18, 21.5], sw(1.8));
      case WeatherScene.haze:
        _sun(canvas, const Offset(12, 9), 4, 1.6, 7.2, sw(1.5));
        _knockLines(canvas, const [15, 18.5, 22], sw(1.8));
        _lines(canvas, const [15, 18.5, 22], sw(1.8));
      case WeatherScene.windy:
        _wind(canvas, sw(1.8));
    }
    canvas
      ..restore()
      ..restore();
  }

  void _sun(
    Canvas canvas,
    Offset c,
    double r,
    double gap,
    double rayEnd,
    double width,
  ) {
    _fill.color = sun;
    canvas.drawCircle(c, r, _fill);
    _stroke
      ..color = sun
      ..strokeWidth = width;
    for (int i = 0; i < 8; i++) {
      final double a = math.pi / 4 * i;
      final Offset d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r + gap), c + d * rayEnd, _stroke);
    }
  }

  void _moon(Canvas canvas, Offset c, double r) {
    final Path moon = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: c, radius: r)),
      Path()..addOval(
        Rect.fromCircle(
          center: c + Offset(r * 0.55, -r * 0.45),
          radius: r * 0.85,
        ),
      ),
    );
    _fill.color = primary;
    canvas.drawPath(moon, _fill);
  }

  /// May: hop cua 3 hinh tron + day bo goc, nonZero -> khong chong alpha.
  Path _cloudPath(Rect r) {
    final double w = r.width;
    final double h = r.height;
    return Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(r.left + w * 0.30, r.top + h * 0.62),
          radius: h * 0.36,
        ),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(r.left + w * 0.56, r.top + h * 0.45),
          radius: h * 0.45,
        ),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(r.left + w * 0.78, r.top + h * 0.66),
          radius: h * 0.32,
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            r.left + w * 0.06,
            r.top + h * 0.6,
            r.right - w * 0.02,
            r.bottom,
          ),
          Radius.circular(h * 0.2),
        ),
      );
  }

  void _cloud(Canvas canvas, Rect r, {Color? color}) {
    final Path p = _cloudPath(r);
    // Khoet vien de tach may khoi mat troi / may phia sau.
    canvas.drawPath(p, _knock);
    _fill.color = color ?? primary;
    canvas.drawPath(p, _fill);
  }

  void _drops(Canvas canvas, int n, double len, double width) {
    _stroke
      ..color = accent
      ..strokeWidth = width;
    final double step = 12 / (n - 1);
    for (int i = 0; i < n; i++) {
      final double x = 6.5 + step * i;
      final double y0 = 16.5 + (i.isOdd ? 1.2 : 0);
      canvas.drawLine(Offset(x, y0), Offset(x - len * 0.3, y0 + len), _stroke);
    }
  }

  void _bolt(Canvas canvas) {
    final Path p = Path()
      ..moveTo(13.2, 11)
      ..lineTo(9.2, 17.4)
      ..lineTo(12, 17.4)
      ..lineTo(10.6, 23)
      ..lineTo(15.4, 15.6)
      ..lineTo(12.6, 15.6)
      ..lineTo(14.2, 11)
      ..close();
    canvas.drawPath(p, _knock);
    _fill.color = bolt;
    canvas.drawPath(p, _fill);
  }

  void _flake(Canvas canvas, Offset c, double r, double width) {
    _stroke
      ..color = accent
      ..strokeWidth = width;
    for (int i = 0; i < 3; i++) {
      final double a = math.pi / 3 * i + math.pi / 2;
      final Offset d = Offset(math.cos(a), math.sin(a)) * r;
      canvas.drawLine(c - d, c + d, _stroke);
    }
  }

  void _lines(Canvas canvas, List<double> ys, double width) {
    _stroke
      ..color = primary
      ..strokeWidth = width;
    for (int i = 0; i < ys.length; i++) {
      final double inset = i.isOdd ? 4 : 2.5;
      canvas.drawLine(
        Offset(inset, ys[i]),
        Offset(24 - inset - 1, ys[i]),
        _stroke,
      );
    }
  }

  void _knockLines(Canvas canvas, List<double> ys, double width) {
    final Paint k = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width + 2.4
      ..blendMode = BlendMode.clear;
    for (int i = 0; i < ys.length; i++) {
      final double inset = i.isOdd ? 4 : 2.5;
      canvas.drawLine(Offset(inset, ys[i]), Offset(24 - inset - 1, ys[i]), k);
    }
  }

  void _wind(Canvas canvas, double width) {
    _stroke
      ..color = primary
      ..strokeWidth = width;
    final Path p = Path()
      ..moveTo(3, 9)
      ..lineTo(15, 9)
      ..arcToPoint(
        const Offset(15, 4),
        radius: const Radius.circular(2.5),
        clockwise: false,
      )
      ..moveTo(3, 13.5)
      ..lineTo(19, 13.5)
      ..arcToPoint(
        const Offset(19, 7.5),
        radius: const Radius.circular(3),
        clockwise: false,
      )
      ..moveTo(3, 18)
      ..lineTo(13, 18)
      ..arcToPoint(const Offset(13, 22.5), radius: const Radius.circular(2.25));
    canvas.drawPath(p, _stroke);
  }

  @override
  bool shouldRepaint(WeatherIconPainter old) =>
      old.scene != scene ||
      old.primary != primary ||
      old.accent != accent ||
      old.sun != sun ||
      old.bolt != bolt;
}
