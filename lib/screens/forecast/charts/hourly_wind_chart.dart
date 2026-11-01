import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../ui/weather/design_tokens.dart';
import '../../../utils/forecast_format.dart';
import '../../../providers/preferences_provider.dart';
import 'chart_common.dart';

class HourlyWindChart extends StatelessWidget {
  const HourlyWindChart({
    super.key,
    required this.hours,
    required this.nowIndex,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final u = PreferencesProvider.unitsOf(context);
    final gustColor = p.isDark ? Tones.gustOnDark : Tones.amberOnLight;
    // Ve theo don vi truc; tooltip / mo ta doc lai so goc (km/h).
    final present = [
      for (final h in hours) ...[?h.windSpeed, ?h.windGusts],
    ].map(u.windAxisValue).toList();
    final maxValue = present.isEmpty ? 0.0 : present.reduce(math.max);
    final interval = maxValue <= 20 ? 5.0 : (maxValue <= 50 ? 10.0 : 20.0);
    final maxY = math.max(
      ((maxValue * 1.15) / interval).ceil() * interval,
      interval * 2,
    );
    final hasGusts = hours.any((h) => h.windGusts != null);
    final maxSpeed = hours
        .where((h) => h.windSpeed != null)
        .fold<double>(0, (m, h) => math.max(m, h.windSpeed!));

    List<FlSpot> spots(double? Function(HourlyForecast) value) => [
      for (var i = 0; i < hours.length; i++)
        value(hours[i]) == null
            ? FlSpot.nullSpot
            : FlSpot(i.toDouble(), u.windAxisValue(value(hours[i])!)),
    ];

    LineChartBarData line(List<FlSpot> s, Color color, {bool dashed = false}) =>
        LineChartBarData(
          spots: s,
          isCurved: true,
          preventCurveOverShooting: true,
          color: color,
          barWidth: dashed ? 2 : 3,
          dashArray: dashed ? const [6, 4] : null,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: !dashed,
            checkToShowDot: (spot, _) => spot.x.round() == nowIndex,
            getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
              radius: 5,
              color: p.marker,
              strokeWidth: 2,
              strokeColor: p.tooltipBg,
            ),
          ),
        );

    final maxGust = hours
        .where((h) => h.windGusts != null)
        .fold<double>(maxSpeed, (m, h) => math.max(m, h.windGusts!));
    return ChartFrame(
      height: 170,
      semanticsLabel:
          'Biểu đồ gió theo giờ (trục ${u.windAxisUnit.label}), tốc độ lớn nhất '
          '${u.windText(maxSpeed.toDouble())}'
          '${hasGusts ? ', gió giật lớn nhất ${u.windText(maxGust)}' : ''}',
      footer: ChartLegend(
        items: [
          (p.wind, 'Tốc độ gió', false),
          if (hasGusts) (gustColor, 'Gió giật', true),
        ],
      ),
      child: LineChart(
        duration: p.duration,
        curve: kChartCurve,
        LineChartData(
          minX: 0,
          maxX: (hours.length - 1).toDouble(),
          minY: 0,
          maxY: maxY,
          clipData: const FlClipData.horizontal(),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: interval,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: p.grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: chartTitles(
            left: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: interval,
              getTitlesWidget: (value, meta) {
                if (value == meta.max) return const SizedBox.shrink();
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text('${value.round()}', style: p.axisStyle),
                );
              },
            ),
            bottom: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (value != i ||
                    i < 0 ||
                    i >= hours.length ||
                    i % hourLabelEvery(hours.length) != 0) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    ForecastFormat.hourShort(hours[i].time),
                    style: p.axisStyle,
                  ),
                );
              },
            ),
          ),
          extraLinesData: ExtraLinesData(
            verticalLines: [
              if (nowIndex != null)
                VerticalLine(
                  x: nowIndex!.toDouble(),
                  color: p.marker.withValues(alpha: 0.7),
                  strokeWidth: 1.5,
                  dashArray: const [3, 3],
                ),
            ],
          ),
          lineBarsData: [
            line(spots((h) => h.windSpeed), p.wind),
            if (hasGusts)
              line(spots((h) => h.windGusts), gustColor, dashed: true),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => p.tooltipBg,
              tooltipRoundedRadius: 8,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    s.barIndex == 0
                        ? '${ForecastFormat.hourMinute(hours[s.x.round()].time)}\n'
                              'Gió ${u.windText(hours[s.x.round()].windSpeed)}'
                        : 'Giật ${u.windText(hours[s.x.round()].windGusts)}',
                    p.tooltipStyle.copyWith(
                      color: s.barIndex == 0 ? p.wind : gustColor,
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

// ---------------------------------------------------------------------------
// Theo ngay (dung DailyForecast truc tiep)
// ---------------------------------------------------------------------------
