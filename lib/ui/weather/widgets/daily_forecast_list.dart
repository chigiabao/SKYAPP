/// The "Dự báo 7 ngày" kieu iOS: thu, icon (+ % mua nho ben duoi), thap,
/// thanh khoang, cao. Luong mua chi tiet nam o man hinh chi tiet ngay.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/weather.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/weather_provider.dart';
import '../../../utils/forecast_format.dart';
import '../../../widgets/source_badge.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_icons.dart';
import '../weather_scene.dart';
import 'glass_card.dart';
import 'temp_range_bar.dart';
import 'ios_sheet.dart';

/// Nguong cu (giu ten cho tuong thich); % mua nay LUON hien khi co.
const int kRainShowPercent = 0;

/// Ma WMO co mua / dong (51-67, 80-82, 95-99).
bool isPrecipCode(int? code) =>
    code != null &&
    ((code >= 51 && code <= 67) || (code >= 80 && code <= 82) || code >= 95);

/// Ngay "xu huong": do tin cay thap HOAC so lieu thong ke nhieu nam.
bool isTrendDay(DailyForecast d) =>
    d.isLowConfidence || d.source == DataSource.climatology;

/// Chu mua duoi icon, NHAT QUAN cho moi ngay:
/// - co xac suat (du bao AI / thong ke) -> luon "P%" (ke ca 0-19 %);
/// - ngay thuc te (khong co xac suat) -> "Có mưa" khi da mua >= 1 mm hoac
///   icon la mua / dong (chu khop icon), nguoc lai khong hien;
/// - khong co xac suat -> "Có mưa" chi khi icon la mua / dong.
String? dailyRainText(DailyForecast d) {
  final code = d.displayWeatherCode ?? wmoForCondition(d.condition);
  if (d.isObserved) {
    return d.observedRainText == 'Có mưa' || isPrecipCode(code)
        ? 'Có mưa'
        : null;
  }
  final int? p = d.rainDayPercent;
  if (p != null) return '$p%';
  return isPrecipCode(code) ? 'Có mưa' : null;
}

/// Do mo cua chu/icon tren hang ngay xu huong.
const double kLowConfidenceOpacity = 0.6;

/// Chu thich cuoi the: tu ngay nao du bao chi con la xu huong. null = khong
/// co ngay nao do tin cay thap (hoac backend cu khong gui `confidence`).
String? confidenceCaption(List<DailyForecast> days) {
  final first = days.indexWhere((d) => d.isLowConfidence);
  if (first < 0) return null;
  const head = 'Dự báo AI Sky Weather';
  const near = 'gần với trung bình nhiều năm';
  const foot = 'không phải cảnh báo chính thức';
  if (first == 0) return '$head · các ngày này $near · $foot';
  final ai = first == 1 ? 'ngày 1' : 'ngày 1–$first';
  return '$head · $ai tin cậy hơn, từ ngày ${first + 1} $near · $foot';
}

/// Giai thich ngan (nut (i) cua the 7 ngay va man chi tiet ngay).
const String kConfidenceExplain =
    'Mô hình AI chỉ dựa trên 48 giờ số liệu gần nhất, không dùng mô hình '
    'số trị (NWP). Trên tập kiểm tra, AI tốt hơn rõ trung bình nhiều năm ở '
    'ngày đầu; từ khoảng ngày thứ 3 sai số gần bằng trung bình nhiều năm.\n\n'
    'Ngày gắn "Xu hướng" được hiện mờ, nhiệt độ ghi dạng khoảng (~) và dùng '
    'icon chung kèm % mưa — chỉ nên xem là xu hướng, không phải dự báo '
    'chi tiết.';

Future<void> showConfidenceInfo(BuildContext context) => showIosInfoSheet(
  context,
  title: 'Độ tin cậy dự báo',
  message: kConfidenceExplain,
);

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
    final caption = confidenceCaption(days);
    double lo = double.infinity;
    double hi = double.negativeInfinity;
    for (final d in days) {
      lo = math.min(lo, math.min(d.tempMin, d.tempMax));
      hi = math.max(hi, math.max(d.tempMin, d.tempMax));
    }

    return GlassCard(
      title: 'Dự báo ${days.length} ngày',
      icon: Icons.calendar_month_outlined,
      trailing: caption == null
          ? null
          : IconButton(
              icon: const Icon(Icons.info_outline_rounded),
              color: GlassInk.of(context).secondary,
              iconSize: 20,
              tooltip: 'Giải thích độ tin cậy',
              onPressed: () => showConfidenceInfo(context),
            ),
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
                isTomorrow:
                    HcmTime.startOfDay(days[i].date) ==
                    HcmTime.startOfDay(today.add(const Duration(hours: 36))),
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
          if (caption != null) ...[
            const SizedBox(height: Space.xs),
            Text(
              caption,
              style: TypeScale.small.copyWith(
                color: GlassInk.of(context).secondary,
              ),
            ),
          ],
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
    this.isTomorrow = false,
    required this.scaleMin,
    required this.scaleMax,
    this.currentTemp,
    this.sourceTag,
    this.onTap,
  });

  final DailyForecast day;
  final bool isToday;

  /// Nhan "Ngày mai" thay cho "T5", khop voi bo chon ngay o man Du bao.
  final bool isTomorrow;
  final double scaleMin;
  final double scaleMax;
  final double? currentTemp;
  final DataSource? sourceTag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final units = PreferencesProvider.unitsOf(context);
    final ink = GlassInk.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final String name = isToday
        ? 'Hôm nay'
        : isTomorrow
        ? 'Ngày mai'
        : ForecastFormat.weekdayShort(day.date);
    final String? rain = dailyRainText(day);
    final bool trend = isTrendDay(day);
    final code = day.displayWeatherCode ?? wmoForCondition(day.condition);
    final icon = WeatherIcon.fromCode(code, isDay: true, size: IconSizes.md);
    final String low = '${units.tempNumber(day.tempMin)}°';
    final String high = '${units.tempNumber(day.tempMax)}°';
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
                        color: trend ? ink.secondary : Palette.white,
                        fontWeight: isToday ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (trend)
                    _fitStart(
                      Container(
                        key: const ValueKey('daily-trend-tag'),
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          border: Border.all(color: ink.secondary),
                        ),
                        child: Text(
                          'Xu hướng',
                          maxLines: 1,
                          style: TypeScale.caption1.copyWith(
                            color: ink.secondary,
                            fontWeight: FontWeight.w600,
                          ),
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
                  trend
                      ? Opacity(opacity: kLowConfidenceOpacity, child: icon)
                      : icon,
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
            if (trend)
              Expanded(
                flex: 5,
                child: _fitEnd(
                  Text(
                    '~${units.tempNumber(day.tempMin)}–$high',
                    maxLines: 1,
                    style: tempStyle.copyWith(color: ink.secondary),
                  ),
                ),
              )
            else ...[
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
          ],
        ),
      ),
    );

    return Semantics(
      button: onTap != null,
      onTap: onTap,
      label:
          '$name ${ForecastFormat.dayMonth(day.date)}: ${icon.scene.label}, '
          'thấp nhất ${units.tempText(day.tempMin)}, '
          'cao nhất ${units.tempText(day.tempMax)}'
          '${currentTemp != null ? ', hiện tại ${units.tempText(currentTemp!)}' : ''}'
          '${rain == null
              ? ''
              : rain.endsWith('%')
              ? ', khả năng mưa $rain'
              : ', $rain'}'
          '${sourceTag != null ? ', ${sourceTag!.shortLabel}' : ''}'
          '${trend ? ', xu hướng, độ tin cậy thấp' : ''}',
      excludeSemantics: true,
      child: onTap == null
          ? row
          : Pressable(onTap: onTap, button: false, child: row),
    );
  }

  static Widget _fitEnd(Widget child) => Align(
    alignment: Alignment.centerRight,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: child,
    ),
  );

  static Widget _fitStart(Widget child) => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: child,
    ),
  );
}
