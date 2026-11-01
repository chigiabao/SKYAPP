import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/units.dart';
import '../../models/weather.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../widgets/ai_forecast_card.dart';
import '../forecast/forecast_charts.dart';
import '../../utils/forecast_format.dart';

/// Du bao (net dut) so voi thuc te (net lien) tai cac moc; dai mo = khoang
/// cua ban du bao goc (neu tai duoc; khong co thi khong ve).
class VerifyChart extends StatelessWidget {
  const VerifyChart({
    super.key,
    required this.data,
    required this.issued,
    required this.units,
  });

  final AIVerification data;
  final AIForecast? issued;
  final UnitPrefs units;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final u = units.tempValue;
    final items = data.horizons;

    final pred = <FlSpot>[];
    final act = <FlSpot>[];
    final lo = <FlSpot>[];
    final hi = <FlSpot>[];
    final all = <double>[];
    for (var i = 0; i < items.length; i++) {
      final h = items[i];
      final x = i.toDouble();
      if (h.predictedTemperature case final v?) {
        pred.add(FlSpot(x, u(v)));
        all.add(u(v));
      } else {
        pred.add(FlSpot.nullSpot);
      }
      if (h.actualTemperature case final v?) {
        act.add(FlSpot(x, u(v)));
        all.add(u(v));
      } else {
        act.add(FlSpot.nullSpot);
      }
      final b = issued?.predictions
          .where((pr) => pr.timeLabel == h.horizon && pr.hasInterval)
          .firstOrNull;
      if (b != null) {
        lo.add(FlSpot(x, u(b.intervalLow!)));
        hi.add(FlSpot(x, u(b.intervalHigh!)));
        all
          ..add(u(b.intervalLow!))
          ..add(u(b.intervalHigh!));
      } else {
        lo.add(FlSpot.nullSpot);
        hi.add(FlSpot.nullSpot);
      }
    }
    final minY = (all.reduce(math.min) - 1).floorToDouble();
    final maxY = (all.reduce(math.max) + 1).ceilToDouble();
    final hasBand = lo.where((spot) => !spot.isNull()).length >= 2;
    final level = issued?.predictions
        .where((x) => x.hasInterval)
        .firstOrNull
        ?.effectiveIntervalLevel;
    final bandLabel = 'Dải ${intervalLevelLabel(level)}';
    final bandColor = (GlassThemeMarker.inkOf(context)?.accent ?? p.low)
        .withValues(alpha: 0.28);
    final actualColor = p.isDark || GlassThemeMarker.isGlass(context)
        ? Colors.white
        : Palette.ink;

    LineChartBarData edge(List<FlSpot> s) => LineChartBarData(
      spots: s,
      color: Colors.transparent,
      barWidth: 0,
      dotData: const FlDotData(show: false),
    );
    FlDotData dots(Color color) => FlDotData(
      getDotPainter: (s, _, _, _) =>
          FlDotCirclePainter(radius: 4, color: color, strokeWidth: 0),
    );

    return ChartFrame(
      height: 200,
      semanticsLabel:
          'Biểu đồ dự báo AI so với số liệu đã ghi nhận tại ${items.length} mốc'
          '${hasBand ? ', có $bandLabel' : ''}',
      footer: ChartLegend(
        items: [
          (p.high, 'Dự báo AI (nét đứt)', true),
          (actualColor, 'Đã ghi nhận', false),
          if (hasBand) (bandColor, bandLabel, false),
        ],
      ),
      child: LineChart(
        duration: p.duration,
        curve: kChartCurve,
        LineChartData(
          minX: -0.3,
          maxX: items.length - 0.7,
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: 1,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: p.grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 1,
                getTitlesWidget: (v, meta) =>
                    v == meta.min || v == meta.max || v != v.roundToDouble()
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text('${v.round()}°', style: p.axisStyle),
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (v != i || i < 0 || i >= items.length) {
                    return const SizedBox.shrink();
                  }
                  final t = items[i].targetTime;
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      '${t == null ? '' : ForecastFormat.hourMinute(t)}\n'
                      'sau ${items[i].horizon}',
                      textAlign: TextAlign.center,
                      style: p.axisStyle,
                    ),
                  );
                },
              ),
            ),
          ),
          betweenBarsData: hasBand
              ? [BetweenBarsData(fromIndex: 0, toIndex: 1, color: bandColor)]
              : const [],
          lineBarsData: [
            edge(hasBand ? lo : const []),
            edge(hasBand ? hi : const []),
            LineChartBarData(
              spots: pred,
              color: p.high,
              barWidth: 2.5,
              dashArray: const [6, 4],
              dotData: dots(p.high),
            ),
            LineChartBarData(
              spots: act,
              color: actualColor,
              barWidth: 2.5,
              dotData: dots(actualColor),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => p.tooltipBg,
              tooltipRoundedRadius: 8,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  s.barIndex < 2
                      ? null
                      : LineTooltipItem(
                          '${s.barIndex == 2 ? 'Dự báo' : 'Đã ghi nhận'} '
                          '${s.y.toStringAsFixed(1).replaceAll('.', ',')}°',
                          p.tooltipStyle,
                        ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
