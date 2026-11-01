import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../models/units.dart';
import 'chart_common.dart';

class DailyTemperatureChart extends StatelessWidget {
  const DailyTemperatureChart({
    super.key,
    required this.days,
    required this.selectedIndex,
    required this.nowHcm,
    required this.units,
    required this.onSelect,
  });

  final List<DailyForecast> days;
  final int selectedIndex;

  /// Gio TP.HCM "hien tai" cua app (nhan "Hôm nay").
  final DateTime nowHcm;
  final UnitPrefs units;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final unit = units.tempUnit;
    final highs = [for (final d in days) units.tempValue(d.tempMax)];
    final lows = [for (final d in days) units.tempValue(d.tempMin)];
    final (minY, maxY, step) = tempAxis([...highs, ...lows]);

    LineChartBarData line(List<double> v, Color color, {bool dashed = false}) =>
        LineChartBarData(
          spots: [
            for (var i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i]),
          ],
          isCurved: true,
          preventCurveOverShooting: true,
          color: color,
          barWidth: dashed ? 2 : 3,
          dashArray: dashed ? const [6, 4] : null,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
              radius: index == selectedIndex ? 5 : 3,
              color: color,
              strokeWidth: index == selectedIndex ? 2 : 0,
              strokeColor: p.tooltipBg,
            ),
          ),
        );

    return ChartFrame(
      semanticsLabel:
          'Biểu đồ nhiệt độ cao nhất và thấp nhất ${days.length} ngày',
      footer: ChartLegend(
        items: [(p.high, 'Cao nhất', false), (p.low, 'Thấp nhất', true)],
      ),
      child: LineChart(
        duration: p.duration,
        curve: kChartCurve,
        LineChartData(
          minX: -0.4,
          maxX: days.length - 0.6,
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: step,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: p.grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: chartTitles(
            left: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: step,
              getTitlesWidget: (value, meta) {
                if (value == meta.min || value == meta.max) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text('${value.round()}°', style: p.axisStyle),
                );
              },
            ),
            bottom: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (value != i || i < 0 || i >= days.length) {
                  return const SizedBox.shrink();
                }
                return dayAxisLabel(meta, days, i, selectedIndex, nowHcm, p);
              },
            ),
          ),
          extraLinesData: ExtraLinesData(
            extraLinesOnTop: false,
            verticalLines: [
              VerticalLine(
                x: selectedIndex.toDouble(),
                color: p.axisText.withValues(alpha: 0.35),
                strokeWidth: 1,
                dashArray: const [3, 3],
              ),
            ],
          ),
          lineBarsData: [line(highs, p.high), line(lows, p.low, dashed: true)],
          lineTouchData: LineTouchData(
            touchCallback: (event, response) {
              final spots = response?.lineBarSpots;
              if (event is FlTapUpEvent && spots != null && spots.isNotEmpty) {
                onSelect(spots.first.x.round());
              }
            },
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => p.tooltipBg,
              tooltipRoundedRadius: 8,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${s.barIndex == 0 ? 'Cao' : 'Thấp'} ${s.y.round()}$unit',
                    p.tooltipStyle.copyWith(
                      color: s.barIndex == 0 ? p.high : p.low,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cot theo ngay (kha nang mua %, gio manh nhat km/h). Gia tri null -> khong
/// ve cot (khong bia so 0). Ngay dang chon dam mau, cac ngay khac nhat hon.
