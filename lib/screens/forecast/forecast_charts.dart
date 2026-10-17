import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/weather.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../utils/constants.dart';
import '../../utils/formatters.dart';
import 'forecast_format.dart';
import '../../providers/preferences_provider.dart';

/// Mau va chu dung chung cho cac bieu do (theo theme sang/toi).
class ChartPalette {
  ChartPalette(BuildContext context)
    : isDark = Theme.of(context).brightness == Brightness.dark,
      axisText =
          GlassThemeMarker.inkOf(context)?.secondary ??
          Theme.of(context).textTheme.bodySmall?.color ??
          AppColors.textSecondaryLight,
      grid = GlassThemeMarker.isGlass(context)
          ? Colors.white.withValues(alpha: 0.16)
          : Theme.of(context).brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.08),
      tooltipBg = GlassThemeMarker.isGlass(context)
          ? const Color(0xF0141C2B)
          : Theme.of(context).brightness == Brightness.dark
          ? AppColors.darkSurface
          : Colors.white,
      tooltipText = Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : Colors.black87,
      high = AppColors.statIcon(context, StatTone.warm),
      low = AppColors.statIcon(context, StatTone.air),
      rain = AppColors.rainyText(context),
      wind = Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF80CBC4)
          : const Color(0xFF00796B),
      marker = Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFFD54F)
          : const Color(0xFFC62828);

  final bool isDark;
  final Color axisText;
  final Color grid;
  final Color tooltipBg;
  final Color tooltipText;
  final Color high;
  final Color low;
  final Color rain;
  final Color wind;

  /// Vach "Bây giờ" / ngay dang chon.
  final Color marker;

  TextStyle get axisStyle => AppTextStyles.caption.copyWith(color: axisText);

  TextStyle get tooltipStyle =>
      TextStyle(color: tooltipText, fontWeight: FontWeight.w600, fontSize: 12);
}

double _toUnit(double celsius, bool isCelsius) =>
    isCelsius ? celsius : celsius * 9 / 5 + 32;

/// Khung chung: card + chieu cao co dinh + chu truc gioi han co chu (1.3x)
/// de nhan truc khong de len nhau khi phong chu he thong lon.
class ChartFrame extends StatelessWidget {
  const ChartFrame({
    super.key,
    required this.semanticsLabel,
    required this.child,
    this.height = 190,
    this.footer,
  });

  final String semanticsLabel;
  final Widget child;
  final double height;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.paddingS,
          AppSizes.paddingM,
          AppSizes.paddingM,
          AppSizes.paddingS,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: semanticsLabel,
              child: ExcludeSemantics(
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: SizedBox(height: height, child: child),
                ),
              ),
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSizes.paddingS,
                  top: AppSizes.paddingS,
                ),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}

/// Chu thich nho: mau + nhan.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});

  final List<(Color, String, bool)> items; // (mau, nhan, net dut)

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12);
    return Wrap(
      spacing: AppSizes.paddingM,
      runSpacing: AppSizes.paddingXS,
      children: [
        for (final (color, label, dashed) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: dashed ? 2 : 4,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(child: Text(label, style: style)),
            ],
          ),
      ],
    );
  }
}

FlTitlesData _titles({required SideTitles left, required SideTitles bottom}) =>
    FlTitlesData(
      leftTitles: AxisTitles(sideTitles: left),
      bottomTitles: AxisTitles(sideTitles: bottom),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    );

/// Truc nhiet do: buoc tron, toi da ~5 vach.
(double, double, double) _tempAxis(Iterable<double> values) {
  final lo = values.reduce(math.min);
  final hi = values.reduce(math.max);
  final span = math.max(hi - lo, 4.0);
  final step = span <= 8 ? 2.0 : (span <= 20 ? 5.0 : 10.0);
  final minY = (lo / step).floor() * step - step;
  final maxY = (hi / step).ceil() * step + step;
  return (minY, maxY, step);
}

// ---------------------------------------------------------------------------
// Theo gio
// ---------------------------------------------------------------------------

/// Nhiet do theo gio (du 24 diem, nhan moi 3 gio), vach "Bây giờ" va vach
/// qua ngay moi.
class HourlyTemperatureChart extends StatelessWidget {
  const HourlyTemperatureChart({
    super.key,
    required this.hours,
    required this.nowIndex,
    required this.provider,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final c = provider.isCelsius;
    final temps = [for (final h in hours) _toUnit(h.temperature, c)];
    final (minY, maxY, step) = _tempAxis(temps);
    final unit = provider.tempUnit;

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
          'Biểu đồ nhiệt độ ${hours.length} giờ, từ $lo$unit đến $hi$unit',
      child: LineChart(
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
          titlesData: _titles(
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
                if (value != i || i < 0 || i >= hours.length || i % 3 != 0) {
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
          lineBarsData: [
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
                show: true,
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
                  LineTooltipItem(
                    '${ForecastFormat.hourMinute(hours[s.x.round()].time)}\n'
                    '${s.y.round()}$unit',
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

/// Kha nang mua theo gio (%), du 24 cot; cot gio hien tai co nen danh dau.
class HourlyRainChart extends StatelessWidget {
  const HourlyRainChart({
    super.key,
    required this.hours,
    required this.nowIndex,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final missing = hours.where((h) => h.rainProbability == null).length;
    final maxPct = hours
        .where((h) => h.rainProbability != null)
        .fold<int>(0, (m, h) => math.max(m, h.rainPercent));

    return ChartFrame(
      height: 170,
      semanticsLabel:
          'Biểu đồ khả năng mưa theo giờ, cao nhất $maxPct phần trăm',
      footer: ChartLegend(
        items: [
          (p.rain, 'Khả năng mưa', false),
          if (nowIndex != null) (p.marker, 'Cột viền: giờ hiện tại', true),
          if (missing > 0) (p.grid, 'Không cột: chưa có số liệu', true),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final plotWidth = math.max(constraints.maxWidth - 40, 1.0);
          final barWidth = (plotWidth / hours.length * 0.6).clamp(3.0, 18.0);
          return BarChart(
            BarChartData(
              maxY: 100,
              minY: 0,
              alignment: BarChartAlignment.spaceAround,
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: 25,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: p.grid, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: _titles(
                left: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: 50,
                  getTitlesWidget: (value, meta) => SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text('${value.round()}%', style: p.axisStyle),
                  ),
                ),
                bottom: SideTitles(
                  showTitles: true,
                  reservedSize: 28,
                  getTitlesWidget: (value, meta) {
                    final i = value.round();
                    if (i < 0 || i >= hours.length || i % 3 != 0) {
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
                        toY: hours[i].rainProbability == null
                            ? 0
                            : hours[i].rainPercent.toDouble(),
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
                          toY: 100,
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
                    final value = h.rainProbability == null
                        ? 'chưa có số liệu'
                        : '${h.rainPercent}%';
                    return BarTooltipItem(
                      '${ForecastFormat.hourMinute(h.time)}\n$value',
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
    final gustColor = p.isDark
        ? const Color(0xFFFFCC80)
        : const Color(0xFFB45309);
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
          titlesData: _titles(
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
                if (value != i || i < 0 || i >= hours.length || i % 3 != 0) {
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

Widget _dayAxisLabel(
  TitleMeta meta,
  List<DailyForecast> days,
  int i,
  int selectedIndex,
  DateTime nowHcm,
  ChartPalette p,
) {
  final d = days[i].date;
  final label = ForecastFormat.sameDay(d, nowHcm)
      ? 'Nay'
      : ForecastFormat.weekdayShort(d);
  final selected = i == selectedIndex;
  return SideTitleWidget(
    axisSide: meta.axisSide,
    child: Text(
      label,
      style: p.axisStyle.copyWith(
        fontWeight: selected ? FontWeight.w800 : FontWeight.w400,
        color: selected ? p.tooltipText : p.axisText,
        decoration: selected ? TextDecoration.underline : null,
      ),
    ),
  );
}

/// Duong cao nhat / thap nhat 7 ngay; cham vao mot ngay de chon ngay do.
class DailyTemperatureChart extends StatelessWidget {
  const DailyTemperatureChart({
    super.key,
    required this.days,
    required this.selectedIndex,
    required this.provider,
    required this.onSelect,
  });

  final List<DailyForecast> days;
  final int selectedIndex;
  final WeatherProvider provider;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final c = provider.isCelsius;
    final unit = provider.tempUnit;
    final highs = [for (final d in days) _toUnit(d.tempMax, c)];
    final lows = [for (final d in days) _toUnit(d.tempMin, c)];
    final (minY, maxY, step) = _tempAxis([...highs, ...lows]);

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
          titlesData: _titles(
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
                return _dayAxisLabel(
                  meta,
                  days,
                  i,
                  selectedIndex,
                  provider.nowHcm,
                  p,
                );
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
  });

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
    double axis(double v) => shortUnit == '%' ? v : u.windAxisValue(v);
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
      interval = maxValue <= 20 ? 5 : (maxValue <= 50 ? 10 : 20);
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
              titlesData: _titles(
                left: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: interval.toDouble(),
                  getTitlesWidget: (value, meta) => SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      shortUnit == '%'
                          ? '${value.round()}%'
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
                    return _dayAxisLabel(
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
