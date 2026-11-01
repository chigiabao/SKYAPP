import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../utils/forecast_format.dart';
import '../../../models/units.dart';
import '../../../providers/preferences_provider.dart';
import 'chart_common.dart';

class HourlyRainChart extends StatelessWidget {
  const HourlyRainChart({
    super.key,
    required this.hours,
    required this.nowIndex,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;

  /// Luong mua cua gio (mm); null = chua co so lieu.
  static double? mmOf(HourlyForecast h) =>
      h.precipitationMm ?? h.precipitationMedian;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final u = PreferencesProvider.unitsOf(context);
    final inch = u.precip == PrecipUnit.inch;
    double axis(double mm) => inch ? UnitConvert.mmToInch(mm) : mm;
    final mms = [for (final h in hours) mmOf(h)];
    final missing = mms.where((v) => v == null).length;
    final present = mms.whereType<double>();
    final maxMm = present.isEmpty ? 0.0 : present.reduce(math.max);
    // Truc toi thieu 2 mm de mua phun khong bi phong to thanh "mua lon".
    final raw = axis(math.max(maxMm * 1.15, 2.0));
    // Buoc tron (2 vach): 13,6 mm -> truc 0/10/20 thay vi 0/6,8/13,6.
    const steps = [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0];
    final interval = steps.firstWhere(
      (s) => s * 2 >= raw,
      orElse: () => (raw / 2).ceilToDouble(),
    );
    final maxAxis = interval * 2;
    final rainy = present.where((v) => v >= 0.1).length;

    return ChartFrame(
      height: 170,
      semanticsLabel:
          'Biểu đồ lượng mưa theo giờ: $rainy giờ có mưa, '
          'nhiều nhất ${u.rainText(maxMm)} trong một giờ',
      footer: ChartLegend(
        items: [
          (p.rain, 'Lượng mưa trong giờ (${u.precip.label})', false),
          if (nowIndex != null) (p.marker, 'Cột viền: giờ hiện tại', true),
          if (missing > 0) (p.grid, 'Không cột: chưa có số liệu', true),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final plotWidth = math.max(constraints.maxWidth - 40, 1.0);
          final barWidth = (plotWidth / hours.length * 0.6).clamp(2.0, 18.0);
          final labelEvery = hourLabelEvery(hours.length);
          return BarChart(
            duration: p.duration,
            curve: kChartCurve,
            BarChartData(
              maxY: maxAxis,
              minY: 0,
              alignment: BarChartAlignment.spaceAround,
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
                  getTitlesWidget: (value, meta) => SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      value == 0
                          ? '0'
                          : value
                                .toStringAsFixed(
                                  interval >= 1 ? 0 : (interval < 0.1 ? 2 : 1),
                                )
                                .replaceAll('.', ','),
                      style: p.axisStyle,
                    ),
                  ),
                ),
                bottom: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  getTitlesWidget: (value, meta) {
                    final i = value.round();
                    if (i < 0 || i >= hours.length || i % labelEvery != 0) {
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
              barGroups: [
                for (var i = 0; i < hours.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: axis(mms[i] ?? 0),
                        width: barWidth,
                        color: p.rain,
                        borderSide: i == nowIndex
                            ? BorderSide(color: p.marker, width: 2)
                            : BorderSide.none,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3),
                        ),
                        backDrawRodData: BackgroundBarChartRodData(
                          show: i == nowIndex,
                          toY: maxAxis,
                          color: p.marker.withValues(alpha: 0.14),
                        ),
                      ),
                    ],
                  ),
              ],
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => p.tooltipBg,
                  tooltipRoundedRadius: 8,
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItem: (group, gi, rod, ri) {
                    final h = hours[group.x];
                    final mm = mmOf(h);
                    final amount = mm == null
                        ? 'chưa có số liệu'
                        : u.rainText(mm);
                    final chance = h.isObserved || h.rainProbability == null
                        ? ''
                        : '\nKhả năng ${h.rainPercent}%';
                    return BarTooltipItem(
                      '${ForecastFormat.hourMinute(h.time)}\n$amount$chance',
                      p.tooltipStyle,
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Gio theo gio (truc theo don vi da chon): toc do (net lien) va gio giat (net dut). Gio thieu
/// so lieu -> dut doan (khong bia so).
