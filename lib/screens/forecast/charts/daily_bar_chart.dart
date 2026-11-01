import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../utils/formatters.dart';
import '../../../utils/forecast_format.dart';
import '../../../providers/preferences_provider.dart';
import 'chart_common.dart';

class DailyBarChart extends StatelessWidget {
  const DailyBarChart({
    super.key,
    required this.days,
    required this.values,
    required this.selectedIndex,
    required this.nowHcm,
    required this.color,
    required this.unitSuffix,
    required this.semanticsLabel,
    required this.onSelect,
    this.fixedMaxY,
    this.legend,
    this.secondaryValues,
    this.secondaryColor,
    this.secondaryLabel = '',
    this.toAxis,
    this.format,
  });

  /// Doi gia tri goc sang don vi truc / chu tooltip; null = theo [unitSuffix]
  /// ('%' giu nguyen, con lai la gio km/h).
  final double Function(double)? toAxis;
  final String Function(double)? format;

  final List<DailyForecast> days;
  final List<double?> values;

  /// Cot thu hai canh cot chinh (vd gio giat); null = khong ve.
  final List<double?>? secondaryValues;
  final Color? secondaryColor;
  final String secondaryLabel; // tien to tooltip, vd 'Giật'
  final int selectedIndex;
  final DateTime nowHcm;
  final Color color;
  final String unitSuffix; // '%' hoac don vi gio, vd ' km/h'
  final String semanticsLabel;
  final ValueChanged<int> onSelect;
  final double? fixedMaxY;
  final Widget? legend;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final second = secondaryValues;
    final shortUnit = unitSuffix.trim();
    // Cot gio ve theo don vi truc; tooltip dung so goc (km/h).
    final u = PreferencesProvider.unitsOf(context);
    double axis(double v) =>
        toAxis?.call(v) ?? (shortUnit == '%' ? v : u.windAxisValue(v));
    final present = [
      ...values.whereType<double>(),
      ...?second?.whereType<double>(),
    ].map(axis).toList();
    final maxValue = present.isEmpty ? 0.0 : present.reduce(math.max);
    final double maxY;
    final double interval;
    if (fixedMaxY != null) {
      maxY = fixedMaxY!;
      interval = maxY / 2;
    } else {
      interval = maxValue <= 2
          ? 0.5
          : maxValue <= 20
          ? 5
          : (maxValue <= 50 ? 10 : 20);
      maxY = math.max(
        ((maxValue * 1.15) / interval).ceil() * interval,
        interval * 2,
      );
    }

    return ChartFrame(
      height: 150,
      semanticsLabel: semanticsLabel,
      footer: legend,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final plotWidth = math.max(constraints.maxWidth - 40, 1.0);
          final barWidth =
              (plotWidth / days.length * 0.5 / (second == null ? 1 : 2)).clamp(
                second == null ? 8.0 : 5.0,
                28.0,
              );
          return BarChart(
            duration: p.duration,
            curve: kChartCurve,
            BarChartData(
              minY: 0,
              maxY: maxY.toDouble(),
              alignment: BarChartAlignment.spaceAround,
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: interval.toDouble(),
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: p.grid, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: chartTitles(
                left: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: interval.toDouble(),
                  getTitlesWidget: (value, meta) => SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      shortUnit == '%'
                          ? '${value.round()}%'
                          : interval < 1
                          ? value.toStringAsFixed(1).replaceAll('.', ',')
                          : '${value.round()}',
                      style: p.axisStyle,
                    ),
                  ),
                ),
                bottom: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  getTitlesWidget: (value, meta) {
                    final i = value.round();
                    if (i < 0 || i >= days.length) {
                      return const SizedBox.shrink();
                    }
                    return dayAxisLabel(
                      meta,
                      days,
                      i,
                      selectedIndex,
                      nowHcm,
                      p,
                    );
                  },
                ),
              ),
              barGroups: [
                for (var i = 0; i < days.length; i++)
                  BarChartGroupData(
                    x: i,
                    barsSpace: 2,
                    barRods: [
                      BarChartRodData(
                        toY: axis(values[i] ?? 0),
                        width: barWidth,
                        color: i == selectedIndex
                            ? color
                            : color.withValues(alpha: 0.5),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                      if (second != null)
                        BarChartRodData(
                          toY: axis(second[i] ?? 0),
                          width: barWidth,
                          color: i == selectedIndex
                              ? (secondaryColor ?? color)
                              : (secondaryColor ?? color).withValues(
                                  alpha: 0.5,
                                ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4),
                          ),
                        ),
                    ],
                  ),
              ],
              barTouchData: BarTouchData(
                touchCallback: (event, response) {
                  final spot = response?.spot;
                  if (event is FlTapUpEvent && spot != null) {
                    onSelect(spot.touchedBarGroupIndex);
                  }
                },
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => p.tooltipBg,
                  tooltipRoundedRadius: 8,
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItem: (group, gi, rod, ri) {
                    final isSecond = ri == 1 && second != null;
                    final v = isSecond ? second[group.x] : values[group.x];
                    final text = v == null
                        ? 'chưa có số liệu'
                        : format != null
                        ? format!(v)
                        : shortUnit == '%'
                        ? WeatherFormat.percent(v)
                        : u.windText(v);
                    return BarTooltipItem(
                      isSecond
                          ? '$secondaryLabel $text'
                          : '${ForecastFormat.title(days[group.x].date)}\n$text',
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
