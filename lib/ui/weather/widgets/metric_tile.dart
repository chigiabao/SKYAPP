/// O chi so trong luoi "Chi tiết" + cac hinh ve nho (thang mau, la ban,
/// dong ho ap suat, cung mat troi).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import 'glass_card.dart';

/// Chu hien khi chi so khong co (KHONG bia so).
const String kNoData = 'Không có dữ liệu';

/// O chi so kinh: tieu de nho viet hoa, gia tri lon, nhan ngan, MOT cau
/// giai thich, hinh ve tuy chon. Ca o la mot nut doc ([semanticsLabel]).
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.title,
    required this.icon,
    required this.value,
    this.unit,
    this.label,
    this.sentence,
    this.visual,
    this.semanticsLabel,
    this.footer,
  });

  final String title;
  final IconData icon;

  /// Gia tri chinh; null -> "Không có dữ liệu".
  final String? value;
  final String? unit;

  /// Nhan ngan duoi gia tri ("Trung bình").
  final String? label;

  /// Mot cau giai thich tu so lieu.
  final String? sentence;

  /// Hinh ve them (thanh thang mau, la ban...).
  final Widget? visual;
  final String? semanticsLabel;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final GlassInk ink = GlassInk.of(context);
    final bool missing = value == null;
    final String sem =
        semanticsLabel ??
        (missing
            ? '$title: $kNoData'
            : '$title: $value${unit == null ? '' : ' $unit'}'
                  '${label == null ? '' : ', $label'}'
                  '${sentence == null ? '' : '. $sentence'}');
    return GlassCard(
      title: title,
      icon: icon,
      semanticsLabel: sem,
      footer: footer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (missing)
            Text(kNoData, style: TypeScale.label.copyWith(color: ink.secondary))
          else
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: value, style: TypeScale.bigValue),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: TypeScale.label.copyWith(fontFeatures: kTabular),
                    ),
                ],
              ),
              style: const TextStyle(color: Palette.white),
            ),
          if (!missing && label != null) ...[
            const SizedBox(height: 2),
            Text(label!, style: TypeScale.label),
          ],
          if (!missing && visual != null) ...[
            const SizedBox(height: Space.m),
            visual!,
          ],
          if (!missing && sentence != null) ...[
            const SizedBox(height: Space.s),
            Text(
              sentence!,
              style: TypeScale.body.copyWith(color: ink.secondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Thanh thang chi so (AQI, UV) kieu "bullet": gradient + vach tron trang
/// tai [marker] (0..1). Hai dau thang ghi [startLabel] / [endLabel].
class IndexScaleBar extends StatelessWidget {
  const IndexScaleBar({
    super.key,
    required this.colors,
    required this.stops,
    required this.marker,
    required this.startLabel,
    required this.endLabel,
  });

  final List<Color> colors;
  final List<double> stops;
  final double marker;
  final String startLabel;
  final String endLabel;

  @override
  Widget build(BuildContext context) {
    final Color c = GlassInk.of(context).secondary;
    final TextStyle end = TypeScale.small.copyWith(
      color: c,
      fontFeatures: kTabular,
    );
    return Semantics(
      label: 'Thang từ $startLabel đến $endLabel',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 12,
            child: CustomPaint(
              painter: _IndexScalePainter(
                colors,
                stops,
                marker.clamp(0.0, 1.0),
              ),
            ),
          ),
          const SizedBox(height: 2),
          ExcludeSemantics(
            child: Row(
              children: [
                Text(startLabel, style: end),
                const Spacer(),
                Text(endLabel, style: end),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IndexScalePainter extends CustomPainter {
  _IndexScalePainter(this.colors, this.stops, this.marker);

  final List<Color> colors;
  final List<double> stops;
  final double marker;

  @override
  void paint(Canvas canvas, Size size) {
    const double h = 4;
    final double cy = size.height / 2;
    final Rect r = Rect.fromLTRB(0, cy - h / 2, size.width, cy + h / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(Radii.bar)),
      Paint()
        ..shader = LinearGradient(colors: colors, stops: stops).createShader(r),
    );
    const double dr = 5;
    final double x = dr + marker * (size.width - 2 * dr);
    canvas.drawCircle(Offset(x, cy), dr, Paint()..color = Palette.white);
    canvas.drawCircle(
      Offset(x, cy),
      dr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Palette.dotRing,
    );
  }

  @override
  bool shouldRepaint(_IndexScalePainter old) =>
      old.marker != marker || old.colors != colors || old.stops != stops;
}

/// La ban gio: vach B/Đ/N/T, mui ten chi huong gio THOI TOI (nguoc huong
/// gio den), toc do o giua.
class CompassDial extends StatelessWidget {
  const CompassDial({
    super.key,
    required this.degrees,
    this.centerText,
    this.size = 112,
  });

  /// Huong gio den (do, 0 = Bac).
  final double degrees;
  final String? centerText;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _CompassPainter(
            degrees,
            GlassInk.of(context).secondary,
            centerText,
          ),
        ),
      ),
    );
  }
}

void _paintText(Canvas canvas, String text, Offset center, TextStyle style) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout();
  tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  tp.dispose();
}

class _CompassPainter extends CustomPainter {
  _CompassPainter(this.degrees, this.secondary, this.centerText);

  final double degrees;
  final Color secondary;
  final String? centerText;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 1;
    final Paint tick = Paint()
      ..strokeWidth = 1
      ..color = Palette.track;
    final Paint major = Paint()
      ..strokeWidth = 2
      ..color = Palette.white;
    for (int i = 0; i < 72; i++) {
      final double a = i * math.pi / 36;
      final bool isMajor = i % 18 == 0;
      final double len = isMajor ? 8 : 4;
      final Offset d = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c + d * (r - len), c + d * r, isMajor ? major : tick);
    }
    final TextStyle ls = TextStyle(
      color: secondary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      fontFamily: TypeScale.family,
    );
    const List<String> names = ['B', 'Đ', 'N', 'T'];
    for (int i = 0; i < 4; i++) {
      final double a = i * math.pi / 2;
      final Offset d = Offset(math.sin(a), -math.cos(a));
      _paintText(
        canvas,
        names[i],
        c + d * (r - 16),
        i == 0 ? ls.copyWith(color: Palette.white) : ls,
      );
    }

    // Mui ten: huong thoi toi = huong den + 180.
    final double a = (degrees + 180) * math.pi / 180;
    final Offset d = Offset(math.sin(a), -math.cos(a));
    final Offset tip = c + d * (r - 4);
    final Offset tail = c - d * (r - 6);
    final Paint arrow = Paint()
      ..color = Palette.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    // Co chu o giua: mui ten chi ve tren vanh ngoai (hai doan) de khong de
    // len chu.
    final double inner = centerText == null ? 0 : r * 0.55;
    canvas.drawLine(tail, c - d * inner, arrow);
    canvas.drawLine(c + d * inner, tip - d * 6, arrow);
    final Offset n = Offset(-d.dy, d.dx);
    final Path head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((tip - d * 10 + n * 5.5).dx, (tip - d * 10 + n * 5.5).dy)
      ..lineTo((tip - d * 10 - n * 5.5).dx, (tip - d * 10 - n * 5.5).dy)
      ..close();
    canvas.drawPath(head, Paint()..color = Palette.white);
    canvas.drawCircle(tail, 3.5, Paint()..color = Palette.white);
    if (centerText != null) {
      _paintText(
        canvas,
        centerText!,
        c,
        const TextStyle(
          color: Palette.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFamily: TypeScale.family,
          fontFeatures: TypeScale.tabular,
          height: 1.1,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_CompassPainter old) =>
      old.degrees != degrees ||
      old.secondary != secondary ||
      old.centerText != centerText;
}

/// Dong ho ap suat: cung 270°, thang [min]..[max] hPa, vach tai [hpa].
class PressureGauge extends StatelessWidget {
  const PressureGauge({
    super.key,
    required this.hpa,
    this.min = 970,
    this.max = 1050,
    this.size = 96,
  });

  final double hpa;
  final double min;
  final double max;
  final double size;

  /// Vi tri 0..1 cua [hpa] tren thang.
  double get fraction => ((hpa - min) / (max - min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _GaugePainter(fraction)),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.f);

  final double f;

  static const double _start = math.pi * 0.75;
  static const double _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 6;
    final Rect rect = Rect.fromCircle(center: c, radius: r);
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Palette.track;
    canvas.drawArc(rect, _start, _sweep, false, track);
    final Paint tick = Paint()
      ..strokeWidth = 1
      ..color = Palette.track;
    for (int i = 0; i <= 16; i++) {
      final double a = _start + _sweep * i / 16;
      final Offset d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r - 10), c + d * (r - 6), tick);
    }
    final double a = _start + _sweep * f;
    canvas.drawArc(
      rect,
      _start,
      _sweep * f,
      false,
      track..color = const Color(0x99FFFFFF),
    );
    final Offset m = c + Offset(math.cos(a), math.sin(a)) * r;
    canvas.drawCircle(m, 6, Paint()..color = Palette.white);
    canvas.drawCircle(
      m,
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Palette.dotRing,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.f != f;
}

/// Cung mat troi: duong chan troi, cung tu moc den lan, cham mat troi tai
/// [progress] (0 = moc, 1 = lan; null = ban dem, khong ve cham).
class SunArc extends StatelessWidget {
  const SunArc({super.key, required this.progress, this.height = 56});

  final double? progress;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _SunArcPainter(progress)),
      ),
    );
  }
}

class _SunArcPainter extends CustomPainter {
  _SunArcPainter(this.p);

  final double? p;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double horizon = size.height * 0.72;
    double yAt(double x) {
      final double t = x / w;
      return horizon - math.sin(t * math.pi) * (horizon - 6);
    }

    final Path arc = Path()..moveTo(0, yAt(0));
    for (int i = 1; i <= 48; i++) {
      final double x = w * i / 48;
      arc.lineTo(x, yAt(x));
    }
    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Palette.track,
    );
    canvas.drawLine(
      Offset(0, horizon),
      Offset(w, horizon),
      Paint()
        ..strokeWidth = 1
        ..color = const Color(0x80FFFFFF),
    );
    final double? q = p;
    if (q != null) {
      final double x = w * q.clamp(0.0, 1.0);
      final Path done = Path()..moveTo(0, yAt(0));
      for (int i = 1; i <= 48; i++) {
        final double xi = x * i / 48;
        done.lineTo(xi, yAt(xi));
      }
      canvas.drawPath(
        done,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Palette.white,
      );
      final Offset sun = Offset(x, yAt(x));
      canvas.drawCircle(sun, 9, Paint()..color = const Color(0x40FFD45C));
      canvas.drawCircle(sun, 5.5, Paint()..color = const Color(0xFFFFD45C));
    }
  }

  @override
  bool shouldRepaint(_SunArcPainter old) => old.p != p;
}
