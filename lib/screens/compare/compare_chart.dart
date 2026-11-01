part of '../compare_screen.dart';

/// Chu giai: mau + kieu net + hinh diem + ten.
class CompareLegend extends StatelessWidget {
  const CompareLegend({super.key, required this.series});

  final List<CompareSeries> series;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.l,
      runSpacing: Space.xs,
      children: [
        for (final s in series)
          Semantics(
            label: '${s.place.name}: ${s.style.shapeName}',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendSwatch(style: s.style),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    s.place.name,
                    style: TypeScale.small.copyWith(color: Palette.white),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.style});

  final CompareSeriesStyle style;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(28, 12), painter: _SwatchPainter(style));
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.style);

  final CompareSeriesStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = style.color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final dash = style.dash;
    if (dash == null) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    } else {
      var x = 0.0;
      while (x < size.width) {
        final x2 = math.min(size.width, x + dash[0]);
        canvas.drawLine(Offset(x, y), Offset(x2, y), p);
        x = x2 + dash[1];
      }
    }
    _drawShape(canvas, style.shape, Offset(size.width / 2, y), 4, style.color);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.style != style;
}

void _drawShape(Canvas c, CompareDotShape s, Offset o, double r, Color color) {
  final fill = Paint()..color = color;
  final stroke = Paint()
    ..color = Palette.chartInk
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;
  switch (s) {
    case CompareDotShape.circle:
      c.drawCircle(o, r, fill);
      c.drawCircle(o, r, stroke);
    case CompareDotShape.square:
      final rect = Rect.fromCenter(center: o, width: 2 * r, height: 2 * r);
      c.drawRect(rect, fill);
      c.drawRect(rect, stroke);
    case CompareDotShape.triangle:
      final path = Path()
        ..moveTo(o.dx, o.dy - r - 1)
        ..lineTo(o.dx + r + 1, o.dy + r)
        ..lineTo(o.dx - r - 1, o.dy + r)
        ..close();
      c.drawPath(path, fill);
      c.drawPath(path, stroke);
  }
}

class _ShapeDotPainter extends FlDotPainter {
  _ShapeDotPainter(this.shape, this.color);

  final CompareDotShape shape;
  final Color color;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) =>
      _drawShape(canvas, shape, offsetInCanvas, 4, color);

  @override
  Size getSize(FlSpot spot) => const Size(10, 10);

  @override
  Color get mainColor => color;

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) => b;

  @override
  List<Object?> get props => [shape, color];
}

/// Bieu do nhiet do 24 gio toi cua cac dia diem tren cung truc.
class CompareChart extends StatelessWidget {
  const CompareChart({
    super.key,
    required this.series,
    required this.nowHcm,
    required this.units,
  });

  final List<CompareSeries> series;

  /// Gio TP.HCM "hien tai" cua app (moc dau truc).
  final DateTime nowHcm;
  final UnitPrefs units;

  /// Co chu toi da cua nhan truc (lon hon nua thi giu 200 %).
  static const double maxAxisTextScale = 2;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final start = HcmTime.startOfHour(nowHcm);
    final conv = units.tempValue;
    final bars = <LineChartBarData>[];
    final drawn = <CompareSeries>[];
    final all = <double>[];
    for (final s in series) {
      final hours = s.data?.hourlyForecast ?? const <HourlyForecast>[];
      final spots = <FlSpot>[];
      for (final h in hours) {
        final x = h.time.difference(start).inMinutes / 60;
        if (x < 0 || x > 23) continue;
        final y = conv(h.temperature);
        spots.add(FlSpot(x, y));
        all.add(y);
      }
      if (spots.isEmpty) continue;
      drawn.add(s);
      bars.add(
        LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: s.style.color,
          barWidth: 2.5,
          dashArray: s.style.dash,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            checkToShowDot: (spot, _) => spot.x.round() % 4 == 0,
            getDotPainter: (spot, p, bar, i) =>
                _ShapeDotPainter(s.style.shape, s.style.color),
          ),
        ),
      );
    }
    if (bars.isEmpty) {
      return Center(
        child: Text(
          'Chưa có dữ liệu theo giờ để vẽ biểu đồ.',
          style: TypeScale.body.copyWith(color: Palette.white),
        ),
      );
    }
    final minT = all.reduce(math.min);
    final maxT = all.reduce(math.max);
    final lo = (minT - 1).floorToDouble();
    final hi = (maxT + 1).ceilToDouble();
    final step = math.max(1, ((hi - lo) / 4).ceil()).toDouble();
    final axis = TypeScale.small.copyWith(color: ink.secondary);
    const unit = '°';
    // Nhan truc phong theo co chu (toi da 200 %): cho trong tinh theo chu
    // that, khong co dinh 36 / 26 (tranh bi cat khi chu lon).
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: maxAxisTextScale);
    final dir = Directionality.of(context);
    Size measure(String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: axis),
        textDirection: dir,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final size = tp.size;
      tp.dispose();
      return size;
    }

    var labelW = 0.0;
    for (var v = lo; v <= hi; v += step) {
      labelW = math.max(labelW, measure('${v.round()}°').width);
    }
    final leftReserve = math.max(36.0, (labelW + Space.s).ceilToDouble());
    final bottomReserve = math.max(
      26.0,
      (measure('23h').height + Space.s).ceilToDouble(),
    );
    return Semantics(
      // Doc khoang nhiet do that (khong phai mien truc da noi rong 1°).
      label:
          'Biểu đồ nhiệt độ 24 giờ tới của ${series.length} địa điểm, '
          'từ ${minT.round()}$unit đến ${maxT.round()}$unit',
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: 23,
          minY: lo,
          maxY: hi,
          clipData: const FlClipData.horizontal(),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: step,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: Palette.chartGrid, strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: leftReserve,
                interval: step,
                getTitlesWidget: (v, meta) => v == meta.min || v == meta.max
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          '${v.round()}°',
                          style: axis,
                          textScaler: scaler,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: bottomReserve,
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (v != i || i % 4 != 0) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      ForecastFormat.hourShort(start.add(Duration(hours: i))),
                      style: axis,
                      textScaler: scaler,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => Palette.chartTooltip,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${drawn[s.barIndex].place.name}: '
                    '${s.y.round()}°',
                    TypeScale.small.copyWith(color: Palette.white),
                  ),
              ],
            ),
          ),
          lineBarsData: bars,
        ),
      ),
    );
  }
}
