import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/weather_provider.dart';
import '../utils/constants.dart';
import 'source_badge.dart';
import '../providers/preferences_provider.dart';

/// Single daily forecast item
class DailyItem extends StatelessWidget {
  final DailyForecast forecast;
  final bool isToday;
  final VoidCallback? onTap;

  /// Nhan nguon rieng cho ngay nay; null = khong danh dau.
  final DataSource? sourceTag;

  const DailyItem({
    super.key,
    required this.forecast,
    this.isToday = false,
    this.onTap,
    this.sourceTag,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<WeatherProvider>();

    return Semantics(
      button: onTap != null,
      label:
          '${isToday ? 'Hôm nay' : _formatDay(forecast.date)} ${_formatDate(forecast.date)}: '
          '${forecast.condition.description}, '
          '${provider.formatTemperature(forecast.tempMin)} đến ${provider.formatTemperature(forecast.tempMax)}, '
          '${forecast.observedRainText != null
              ? '${forecast.observedRainText}, '
              : forecast.rainDayPercent != null
              ? 'khả năng mưa ${forecast.rainDayPercent}%, '
              : ''}'
          'lượng mưa ${PreferencesProvider.unitsOf(context).rainText(_rainAmount)}'
          '${sourceTag != null ? ', ${sourceTag!.shortLabel}' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSizes.borderRadiusS),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSizes.paddingM,
            horizontal: AppSizes.paddingM,
          ),
          child: Row(
            children: [
              // Cot dung flex (khong co dinh px) de can hang giua cac dong
              // va co gian theo co chu; FittedBox chong tran o co chu lon.
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _fitStart(
                      Text(
                        isToday ? 'Hôm nay' : _formatDay(forecast.date),
                        maxLines: 1,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: theme.textTheme.bodyLarge?.color,
                          fontWeight: isToday
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (sourceTag != null)
                      _fitStart(SourceTag(source: sourceTag!)),
                  ],
                ),
              ),

              const SizedBox(width: AppSizes.paddingS),

              // Kha nang mua trong ngay (%) + luong mua trung vi (mm)
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (forecast.rainDayPercent != null)
                      _fitStart(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.water_drop_rounded,
                              size: 14,
                              color: AppColors.rainyText(context),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              forecast.observedRainText ??
                                  '${forecast.rainDayPercent}%',
                              maxLines: 1,
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.rainyText(context),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    _fitStart(
                      Text(
                        PreferencesProvider.unitsOf(context)
                            .rainText(_rainAmount),
                        maxLines: 1,
                        style: AppTextStyles.caption.copyWith(
                          color: forecast.rainDayPercent != null
                              ? theme.textTheme.bodySmall?.color
                              : AppColors.rainyText(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Weather icon
              Expanded(
                flex: 2,
                child: Center(
                  child: Icon(
                    forecast.condition.icon,
                    size: AppSizes.iconSizeM,
                    color: forecast.condition.color,
                  ),
                ),
              ),

              // Temperature range
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          provider.formatTempValue(forecast.tempMin),
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                        const SizedBox(width: AppSizes.paddingS),
                        Text(
                          '${provider.formatTempValue(forecast.tempMax)}${provider.tempUnit}',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: theme.textTheme.bodyLarge?.color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Arrow icon for navigation
              if (onTap != null) ...[
                const SizedBox(width: AppSizes.paddingS),
                Icon(
                  Icons.chevron_right_rounded,
                  size: AppSizes.iconSizeS,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Uu tien trung vi (trung binh bi keo cao boi vai nam mua lon).
  double? get _rainAmount =>
      forecast.precipitationMedian ?? forecast.precipitationMm;

  static Widget _fitStart(Widget child) => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: child,
    ),
  );

  String _formatDay(DateTime date) {
    // Vietnamese day names
    final dayNames = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
    return dayNames[date.weekday % 7];
  }

  String _formatDate(DateTime date) {
    return DateFormat('dd/MM').format(date);
  }
}

/// List of daily forecasts
class DailyForecastList extends StatelessWidget {
  final List<DailyForecast> forecasts;
  final Function(DailyForecast)? onItemTap;

  const DailyForecastList({super.key, required this.forecasts, this.onItemTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = HcmTime.startOfDay(context.read<WeatherProvider>().nowHcm);
    final summary = SourceSummary.of(forecasts.map((f) => f.source));

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSizes.paddingM,
              AppSizes.paddingM,
              AppSizes.paddingM,
              AppSizes.paddingS,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '7 ngày tới',
                  style: AppTextStyles.heading3.copyWith(
                    color: theme.textTheme.titleLarge?.color,
                  ),
                ),
                SourceSubtitle(summary: summary),
              ],
            ),
          ),
          const Divider(height: 1),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: forecasts.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              indent: AppSizes.paddingM,
              endIndent: AppSizes.paddingM,
              color: theme.dividerTheme.color?.withValues(alpha: 0.5),
            ),
            itemBuilder: (context, index) {
              return DailyItem(
                forecast: forecasts[index],
                isToday: HcmTime.startOfDay(forecasts[index].date) == today,
                onTap: onItemTap != null
                    ? () => onItemTap!(forecasts[index])
                    : null,
                sourceTag: summary.marks(forecasts[index].source)
                    ? (forecasts[index].source ?? SourceSummary.fallback)
                    : null,
              );
            },
          ),
        ],
      ),
    );
  }
}
