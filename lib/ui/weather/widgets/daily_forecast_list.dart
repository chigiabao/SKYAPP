/// The "Dự báo 7 ngày" kieu iOS: thu, icon (+ % mua nho ben duoi), thap,
/// thanh khoang, cao. Luong mua chi tiet nam o man hinh chi tiet ngay.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/weather.dart';
import '../../../providers/weather_provider.dart';
import '../../../screens/forecast/forecast_format.dart';
import '../../../widgets/source_badge.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_icons.dart';
import '../weather_scene.dart';
import 'glass_card.dart';
import 'temp_range_bar.dart';

/// Nguong hien % mua duoi icon.
const int kRainShowPercent = 20;

/// Chu mua nho duoi icon theo nguon: du bao / thong ke -> "P%" khi
/// P >= 20; thuc te -> "Có mưa" khi ngay do co mua >= 1 mm. null = khong hien.
String? dailyRainText(DailyForecast d) {
  if (d.isObserved) {
    return d.observedRainText == 'Có mưa' ? 'Có mưa' : null;
  }
  final int? p = d.rainDayPercent;
  if (p == null || p < kRainShowPercent) return null;
  return '$p%';
}

/// Tag Hero cua mot ngay, dung chung voi man chi tiet ngay
/// (DaySummaryCard.heroTag): "day-yyyy-MM-dd".
String dayHeroTag(DateTime d) =>
    'day-${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The 7 ngay. [currentTemp] (°C): cham trang tren hang "Hôm nay".
class DailyForecastCard extends StatelessWidget {
  const DailyForecastCard({
    super.key,
    required this.days,
    this.currentTemp,
    this.onDayTap,
    this.nowHcm,
    this.heroes = false,
  });

  /// Boc moi hang trong Hero [dayHeroTag] (chuyen canh sang chi tiet ngay).
  final bool heroes;
  final List<DailyForecast> days;
  final double? currentTemp;
  final ValueChanged<DailyForecast>? onDayTap;
  final DateTime? nowHcm;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final DateTime today = HcmTime.startOfDay(nowHcm ?? provider.nowHcm);
    final summary = SourceSummary.of(days.map((d) => d.source));
    final minority = minoritySources(days.map((d) => d.source));
    double lo = double.infinity;
    double hi = double.negativeInfinity;
    for (final d in days) {
      lo = math.min(lo, math.min(d.tempMin, d.tempMax));
      hi = math.max(hi, math.max(d.tempMin, d.tempMax));
    }

    return GlassCard(
      title: 'Dự báo ${days.length} ngày',
      icon: Icons.calendar_month_outlined,
      padding: const EdgeInsets.fromLTRB(
        Space.cardPadding,
        Space.cardPadding,
        Space.cardPadding,
        Space.cardPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < days.length; i++) ...[
            const Divider(height: 1, color: Palette.divider),
            _hero(
              context,
              days[i],
              DailyRow(
                day: days[i],
                isToday: HcmTime.startOfDay(days[i].date) == today,
                scaleMin: lo,
                scaleMax: hi,
                currentTemp: HcmTime.startOfDay(days[i].date) == today
                    ? currentTemp
                    : null,
                sourceTag:
                    minority.contains(days[i].source ?? SourceSummary.fallback)
                    ? (days[i].source ?? SourceSummary.fallback)
                    : null,
                onTap: onDayTap == null ? null : () => onDayTap!(days[i]),
              ),
            ),
          ],
          const Divider(height: 1, color: Palette.divider),
          const SizedBox(height: Space.s),
          SourceSubtitle(summary: summary),
        ],
      ),
    );
  }
}

extension on DailyForecastCard {
  Widget _hero(BuildContext context, DailyForecast d, Widget row) {
    if (!heroes || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return row;
    }
    return Hero(
      tag: dayHeroTag(d.date),
      // Bay tren overlay: giu nen trong suot, chu theo kieu rieng.
      child: Material(type: MaterialType.transparency, child: row),
    );
  }
}

/// Mot hang ngay.
class DailyRow extends StatelessWidget {
  const DailyRow({
    super.key,
    required this.day,
    required this.isToday,
    required this.scaleMin,
    required this.scaleMax,
    this.currentTemp,
    this.sourceTag,
    this.onTap,
  });

  final DailyForecast day;
  final bool isToday;
  final double scaleMin;
  final double scaleMax;
  final double? currentTemp;
  final DataSource? sourceTag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final String name = isToday
        ? 'Hôm nay'
        : ForecastFormat.weekdayShort(day.date);
    final String? rain = dailyRainText(day);
    final code = day.weatherCode ?? wmoForCondition(day.condition);
    final icon = WeatherIcon.fromCode(code, isDay: true, size: IconSizes.md);
    final String low = '${provider.formatTempValue(day.tempMin)}°';
    final String high = '${provider.formatTempValue(day.tempMax)}°';
    final double tempW = scaler.scale(17) * 1.9;
    final TextStyle tempStyle = TypeScale.label.copyWith(
      color: Palette.white,
      fontFeatures: kTabular,
    );

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _fitStart(
                    Text(
                      name,
                      maxLines: 1,
                      style: TypeScale.label.copyWith(
                        color: Palette.white,
                        fontWeight: isToday ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (sourceTag != null)
                    _fitStart(SourceTag(source: sourceTag!)),
                ],
              ),
            ),
            SizedBox(
              width: 48,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  if (rain != null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        rain,
                        maxLines: 1,
                        style: TypeScale.small.copyWith(
                          fontWeight: FontWeight.w700,
                          color: ink.rain,
                          fontFeatures: kTabular,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: tempW,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  low,
                  style: tempStyle.copyWith(color: ink.secondary),
                ),
              ),
            ),
            const SizedBox(width: Space.s),
            Expanded(
              flex: 5,
              child: TempRangeBar(
                geometry: TempRangeGeometry(
                  scaleMin: scaleMin,
                  scaleMax: scaleMax,
                  low: day.tempMin,
                  high: day.tempMax,
                  current: currentTemp,
                ),
              ),
            ),
            const SizedBox(width: Space.s),
            SizedBox(
              width: tempW,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(high, style: tempStyle),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      button: onTap != null,
      label:
          '$name ${ForecastFormat.dayMonth(day.date)}: ${icon.scene.label}, '
          'thấp nhất ${provider.formatTemperature(day.tempMin)}, '
          'cao nhất ${provider.formatTemperature(day.tempMax)}'
          '${currentTemp != null ? ', hiện tại ${provider.formatTemperature(currentTemp!)}' : ''}'
          '${rain == null
              ? ''
              : day.isObserved
              ? ', $rain'
              : ', khả năng mưa $rain'}'
          '${sourceTag != null ? ', ${sourceTag!.shortLabel}' : ''}',
      excludeSemantics: true,
      child: onTap == null
          ? row
          : Pressable(onTap: onTap, button: false, child: row),
    );
  }

  static Widget _fitStart(Widget child) => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: child,
    ),
  );
}
