import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/weather_provider.dart';
import '../utils/constants.dart';
import 'source_badge.dart';
import '../providers/preferences_provider.dart';

/// Single hourly forecast item for horizontal scroll
class HourlyItem extends StatelessWidget {
  final HourlyForecast forecast;
  final bool isNow;
  final double width;

  /// Nhan nguon rieng cho o nay (vd "Thực tế"); null = khong danh dau.
  final DataSource? sourceTag;

  const HourlyItem({
    super.key,
    required this.forecast,
    this.isNow = false,
    this.width = HourlyForecastList.baseTileWidth,
    this.sourceTag,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<WeatherProvider>();
    final isDark = theme.brightness == Brightness.dark;
    // Gio thuc te: hien luong mua da do (mm) thay vi "100%".
    final mm = forecast.precipitationMm;
    final rainText = forecast.isObserved
        ? (mm != null && mm > 0
              ? PreferencesProvider.unitsOf(context).rainText(mm)
              : null)
        : (forecast.rainPercent > 0 ? '${forecast.rainPercent}%' : null);

    return Semantics(
      label:
          '${isNow ? 'Bây giờ' : _formatHour(forecast.time)}: '
          '${provider.formatTemperature(forecast.temperature)}, ${forecast.condition.description}'
          '${rainText == null
              ? ''
              : forecast.isObserved
              ? ', mưa $rainText'
              : ', khả năng mưa $rainText'}'
          '${sourceTag != null ? ', ${sourceTag!.shortLabel}' : ''}',
      excludeSemantics: true,
      child: Container(
        width: width,
        margin: const EdgeInsets.only(right: AppSizes.paddingS),
        padding: const EdgeInsets.symmetric(
          vertical: AppSizes.paddingM,
          horizontal: AppSizes.paddingS,
        ),
        decoration: BoxDecoration(
          color: isNow
              ? (isDark ? const Color(0xFF2E5AAC) : AppColors.primaryDark)
              : theme.cardTheme.color,
          borderRadius: BorderRadius.circular(AppSizes.borderRadius),
          border: isNow
              ? null
              : Border.all(
                  color:
                      theme.dividerTheme.color ??
                      Colors.grey.withValues(alpha: 0.2),
                  width: 1,
                ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Time
            _fit(
              Text(
                isNow ? 'Bây giờ' : _formatHour(forecast.time),
                style: AppTextStyles.bodySmall.copyWith(
                  color: isNow
                      ? Colors.white
                      : theme.textTheme.bodySmall?.color,
                  fontWeight: isNow ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),

            const SizedBox(height: AppSizes.paddingS),

            // Weather icon
            Icon(
              forecast.condition.icon,
              size: AppSizes.iconSizeM,
              color: isNow ? Colors.white : forecast.condition.color,
            ),

            const SizedBox(height: AppSizes.paddingS),

            // Temperature
            _fit(
              Text(
                '${provider.formatTempValue(forecast.temperature)}${provider.tempUnit}',
                style: AppTextStyles.temperatureSmall.copyWith(
                  color: isNow
                      ? Colors.white
                      : theme.textTheme.bodyLarge?.color,
                ),
              ),
            ),

            // Precipitation chance (if > 0)
            if (rainText != null) ...[
              const SizedBox(height: AppSizes.paddingXS),
              _fit(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.water_drop_outlined,
                      size: 12,
                      color: isNow
                          ? Colors.white
                          : AppColors.rainyText(context),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      rainText,
                      style: AppTextStyles.caption.copyWith(
                        color: isNow
                            ? Colors.white
                            : AppColors.rainyText(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Nguon rieng cua o (khi tron nguon / so lieu thuc te)
            if (sourceTag != null) ...[
              const SizedBox(height: AppSizes.paddingXS),
              _fit(
                SourceTag(
                  source: sourceTag!,
                  onColor: isNow ? Colors.white : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _fit(Widget child) =>
      FittedBox(fit: BoxFit.scaleDown, child: child);

  String _formatHour(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:00';
  }
}

/// Horizontal scrollable list of hourly forecasts
class HourlyForecastList extends StatelessWidget {
  static const double baseTileWidth = 70;

  final List<HourlyForecast> forecasts;

  /// Gio hien tai (de test); mac dinh gio TP.HCM tu provider.
  final DateTime? now;

  const HourlyForecastList({super.key, required this.forecasts, this.now});

  static bool _isCurrentHour(DateTime t, DateTime now) =>
      HcmTime.startOfHour(t) == HcmTime.startOfHour(now);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final current = now ?? context.read<WeatherProvider>().nowHcm;
    final summary = SourceSummary.of(forecasts.map((f) => f.source));
    DataSource? tagFor(HourlyForecast f) =>
        summary.marks(f.source) ? (f.source ?? SourceSummary.fallback) : null;
    final anyTag = forecasts.any((f) => tagFor(f) != null);

    // Kich thuoc o theo co chu: phan co dinh (padding, icon, khoang cach)
    // + chieu cao 3 dong chu da scale (he so dong ~1.3).
    const fixedHeight =
        AppSizes.paddingM * 2 +
        AppSizes.iconSizeM +
        AppSizes.paddingS * 2 +
        AppSizes.paddingXS;
    final textHeight =
        1.3 *
            (scaler.scale(AppTextStyles.bodySmall.fontSize!) +
                scaler.scale(AppTextStyles.temperatureSmall.fontSize!) +
                scaler.scale(AppTextStyles.caption.fontSize!) *
                    (anyTag ? 2 : 1)) +
        (anyTag ? AppSizes.paddingXS : 0);
    final tileHeight = fixedHeight + textHeight + 4;
    final tileWidth =
        (AppSizes.paddingS * 2 +
                scaler.scale(AppTextStyles.temperatureSmall.fontSize!) * 2.6)
            .clamp(baseTileWidth, 140.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Theo giờ',
          style: AppTextStyles.heading3.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        SourceSubtitle(summary: summary),
        const SizedBox(height: AppSizes.paddingS),
        SizedBox(
          height: tileHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: forecasts.length,
            itemBuilder: (context, index) {
              final f = forecasts[index];
              return HourlyItem(
                forecast: f,
                width: tileWidth,
                isNow: _isCurrentHour(f.time, current),
                sourceTag: tagFor(f),
              );
            },
          ),
        ),
      ],
    );
  }
}
