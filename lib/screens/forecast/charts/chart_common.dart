import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../models/weather.dart';
import '../../../providers/preferences_provider.dart';
import '../../../ui/weather/design_tokens.dart';
import '../../../ui/weather/widgets/glass_page.dart';
import '../../../utils/constants.dart';
import '../../../utils/forecast_format.dart';

class ChartPalette {
  ChartPalette(BuildContext context)
    : duration = chartMotionOff(context) ? Duration.zero : kChartDuration,
      isDark = Theme.of(context).brightness == Brightness.dark,
      axisText =
          GlassThemeMarker.inkOf(context)?.secondary ??
          Theme.of(context).textTheme.bodySmall?.color ??
          Tones.secondaryOnLight,
      grid = GlassThemeMarker.isGlass(context)
          ? Colors.white.withValues(alpha: 0.16)
          : Theme.of(context).brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.08),
      tooltipBg = GlassThemeMarker.isGlass(context)
          ? Palette.chartTooltip
          : Theme.of(context).brightness == Brightness.dark
          ? Tones.navySurface
          : Colors.white,
      tooltipText = Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : Colors.black87,
      high = AppColors.statIcon(context, StatTone.warm),
      low = AppColors.statIcon(context, StatTone.air),
      rain = AppColors.rainyText(context),
      wind = Theme.of(context).brightness == Brightness.dark
          ? Tones.tealOnDark
          : Tones.windOnLight,
      marker = Theme.of(context).brightness == Brightness.dark
          ? Tones.markerOnDark
          : Tones.markerOnLight;

  /// Thoi gian chuyen du lieu cua fl_chart (0 khi giam chuyen dong).
  final Duration duration;
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

  TextStyle get axisStyle => TypeScale.caption.copyWith(color: axisText);

  TextStyle get tooltipStyle => TextStyle(
    color: tooltipText,
    fontWeight: FontWeight.w600,
    fontSize: TypeScale.caption1.fontSize,
  );
}

/// Bieu do ve dan / doi du lieu: 700 ms, easeOutCubic.
const kChartDuration = Duration(milliseconds: 700);
const kChartCurve = Curves.easeOutCubic;

/// Giam chuyen dong: he thong hoac cai dat app (PreferencesProvider cung day
/// vao MediaQuery.disableAnimations, kiem tra ca hai cho chac).
bool chartMotionOff(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
    (PreferencesProvider.maybeOf(context, listen: false)?.reduceMotion ??
        false);

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
        padding: const EdgeInsets.fromLTRB(Space.s, Space.l, Space.l, Space.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: semanticsLabel,
              child: ExcludeSemantics(
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: SizedBox(
                    height: height,
                    child: ChartReveal(child: child),
                  ),
                ),
              ),
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.only(left: Space.s, top: Space.s),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}

/// Lan dau hien: bieu do lo dan tu trai sang phai (700 ms, easeOutCubic).
/// Giam chuyen dong -> hien ngay.
class ChartReveal extends StatelessWidget {
  const ChartReveal({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (chartMotionOff(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kChartDuration,
      curve: kChartCurve,
      child: child,
      builder: (context, t, child) =>
          t >= 1 ? child! : ClipRect(clipper: _RevealClipper(t), child: child),
    );
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  _RevealClipper(this.t);
  final double t;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * t, size.height);

  @override
  bool shouldReclip(_RevealClipper old) => old.t != t;
}

/// Chu thich nho: mau + nhan.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});

  final List<(Color, String, bool)> items; // (mau, nhan, net dut)

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontSize: TypeScale.caption1.fontSize);
    return Wrap(
      spacing: Space.l,
      runSpacing: Space.xs,
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

FlTitlesData chartTitles({
  required SideTitles left,
  required SideTitles bottom,
}) => FlTitlesData(
  leftTitles: AxisTitles(sideTitles: left),
  bottomTitles: AxisTitles(sideTitles: bottom),
  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
);

/// Truc nhiet do: buoc tron, toi da ~5 vach.
(double, double, double) tempAxis(Iterable<double> values) {
  final lo = values.reduce(math.min);
  final hi = values.reduce(math.max);
  final span = math.max(hi - lo, 4.0);
  final step = span <= 8 ? 2.0 : (span <= 20 ? 5.0 : 10.0);
  final minY = (lo / step).floor() * step - step;
  final maxY = (hi / step).ceil() * step + step;
  return (minY, maxY, step);
}

Widget dayAxisLabel(
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

/// Buoc nhan truc gio: it cot (vd. chi con 21h-23h cuoi ngay) -> nhan MOI
/// cot; vua -> moi 2 gio; day ngay -> 3 gio; > 30 cot -> 6 gio. Luon co nhan
/// cho moi cot khi <= 8 cot (khong chi mot nhan "21h").
int hourLabelEvery(int count) => count <= 8
    ? 1
    : count <= 16
    ? 2
    : count > 30
    ? 6
    : 3;
