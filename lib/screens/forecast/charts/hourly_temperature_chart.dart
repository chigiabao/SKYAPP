import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../models/units.dart';
import '../../../utils/forecast_format.dart';
import '../../../widgets/ai_forecast_card.dart' show intervalLevelLabel;
import 'chart_common.dart';

/// Nhiet do theo gio (du 24 diem, nhan moi 3 gio), vach "Bây giờ" va vach
/// qua ngay moi. Gio AI co khoang p10-p90 -> dai mo "khoảng 80%" (muc bat
/// dinh, khong phai do chinh xac); gio khong co khoang thi khong ve.
class HourlyTemperatureChart extends StatelessWidget {
  const HourlyTemperatureChart({
    super.key,
    required this.hours,
    required this.nowIndex,
    required this.units,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;
  final UnitPrefs units;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final temps = [for (final h in hours) units.tempValue(h.temperature)];
    final unit = units.tempUnit;
    final lo10 = <FlSpot>[];
    final hi90 = <FlSpot>[];
    for (var i = 0; i < hours.length; i++) {
      final h = hours[i];
      if (h.hasTemperatureInterval) {
        lo10.add(FlSpot(i.toDouble(), units.tempValue(h.temperatureP10!)));
        hi90.add(FlSpot(i.toDouble(), units.tempValue(h.temperatureP90!)));
      } else {
        lo10.add(FlSpot.nullSpot);
        hi90.add(FlSpot.nullSpot);
      }
    }
    final hasBand = lo10.where((s) => !s.isNull()).length >= 2;
    final level = hours
        .where((h) => h.hasTemperatureInterval)
        .firstOrNull
        ?.intervalLevel;
    final bandLabel = 'Dải ${intervalLevelLabel(level)}';
    final (minY, maxY, step) = tempAxis([
      ...temps,
      for (final s in [...lo10, ...hi90])
        if (hasBand && !s.isNull()) s.y,
    ]);
    final main = hasBand ? 2 : 0;
    LineChartBarData edge(List<FlSpot> spots) => LineChartBarData(
      spots: spots,
      color: Colors.transparent,
      barWidth: 0,
      dotData: const FlDotData(show: false),
    );

    final verticalLines = <VerticalLine>[
      for (var i = 1; i < hours.length; i++)
        if (hours[i].time.hour == 0)
          VerticalLine(
            x: i.toDouble(),
            color: p.axisText.withValues(alpha: 0.6),
            strokeWidth: 1,
            dashArray: const [3, 3],
            label: VerticalLineLabel(
              show: true,
              // Nhan ngay o day bieu do de khong de len nhan "Bây giờ".
              alignment: Alignment.bottomRight,
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              style: p.axisStyle.copyWith(fontWeight: FontWeight.w600),
              labelResolver: (_) => ForecastFormat.weekdayShort(hours[i].time),
            ),
          ),
      if (nowIndex != null)
        VerticalLine(
          x: nowIndex!.toDouble(),
          color: p.marker,
          strokeWidth: 2,
          label: VerticalLineLabel(
            show: true,
            alignment: nowIndex! > hours.length - 4
                ? Alignment.topLeft
                : Alignment.topRight,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            style: p.axisStyle.copyWith(
              color: p.marker,
              fontWeight: FontWeight.w700,
            ),
            labelResolver: (_) => 'Bây giờ',
          ),
        ),
    ];

    final lo = temps.reduce(math.min).round();
    final hi = temps.reduce(math.max).round();
    return ChartFrame(
      semanticsLabel:
          'Biểu đồ nhiệt độ ${hours.length} giờ, từ $lo$unit đến $hi$unit'
          '${hasBand ? ', có $bandLabel (mức bất định, không phải độ chính xác)' : ''}',
      footer: hasBand
          ? ChartLegend(
              items: [
                (p.high, 'Dự báo AI', false),
                (
                  p.high.withValues(alpha: 0.3),
                  '$bandLabel (mức bất định)',
                  false,
                ),
              ],
            )
          : null,
      child: LineChart(
        duration: p.duration,
        curve: kChartCurve,
        LineChartData(
          minX: 0,
          maxX: (hours.length - 1).toDouble(),
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.horizontal(),
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
          extraLinesData: ExtraLinesData(verticalLines: verticalLines),
          betweenBarsData: hasBand
              ? [
                  BetweenBarsData(
                    fromIndex: 0,
                    toIndex: 1,
                    color: p.high.withValues(alpha: 0.22),
                  ),
                ]
              : const [],
          lineBarsData: [
            if (hasBand) ...[edge(lo10), edge(hi90)],
            LineChartBarData(
              spots: [
                for (var i = 0; i < temps.length; i++)
                  FlSpot(i.toDouble(), temps[i]),
              ],
              isCurved: true,
              preventCurveOverShooting: true,
              color: p.high,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(
                show: true,
                checkToShowDot: (spot, _) => spot.x.round() == nowIndex,
                getDotPainter: (spot, percent, bar, index) =>
                    FlDotCirclePainter(
                      radius: 5,
                      color: p.marker,
                      strokeWidth: 2,
                      strokeColor: p.tooltipBg,
                    ),
              ),
              belowBarData: BarAreaData(
                show: !hasBand,
                color: p.high.withValues(alpha: 0.12),
              ),
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
                  s.barIndex != main
                      ? null
                      : LineTooltipItem(
                          '${ForecastFormat.hourMinute(hours[s.x.round()].time)}\n'
                          '${s.y.round()}$unit'
                          '${_rangeText(hours[s.x.round()], unit)}',
                          p.tooltipStyle,
                        ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "\nkhoảng 80%: 26–29°C" cho gio co khoang; rong neu khong co.
  String _rangeText(HourlyForecast h, String unit) {
    if (!h.hasTemperatureInterval) return '';
    return '\n${intervalLevelLabel(h.intervalLevel)}: '
        '${units.tempValue(h.temperatureP10!).round()}–'
        '${units.tempValue(h.temperatureP90!).round()}$unit';
  }
}

/// Luong mua theo gio (mm hoac in theo cai dat). Gio thuc te / du bao dung
/// `precipitation`; thieu -> trung vi; thieu ca hai -> khong cot (khong bia 0).
