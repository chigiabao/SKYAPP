import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/weather_provider.dart';
import '../utils/constants.dart';

/// Main current weather display card
class WeatherCard extends StatelessWidget {
  final CurrentWeather weather;

  const WeatherCard({super.key, required this.weather});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<WeatherProvider>();
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSizes.paddingL),
      decoration: BoxDecoration(
        gradient: isDark
            ? AppColors.heroDarkGradient
            : AppColors.heroLightGradient,
        border: isDark
            ? Border.all(color: Colors.white.withValues(alpha: 0.12))
            : null,
        borderRadius: BorderRadius.circular(AppSizes.borderRadiusL),
        boxShadow: [
          BoxShadow(
            color: (isDark ? Colors.black : AppColors.primaryDark).withValues(
              alpha: 0.3,
            ),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Location name
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.location_on_rounded,
                color: AppColors.onHeroSecondary,
                size: AppSizes.iconSizeS,
              ),
              const SizedBox(width: AppSizes.paddingXS),
              Flexible(
                child: Text(
                  weather.locationName,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.heading3.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSizes.paddingL),

          // Weather icon
          Icon(
            weather.condition.icon,
            size: AppSizes.iconSizeXL,
            color: Colors.white,
            semanticLabel: weather.condition.description,
          ),

          const SizedBox(height: AppSizes.paddingM),

          // Temperature
          Semantics(
            label:
                'Nhiệt độ hiện tại: ${provider.formatTemperature(weather.temperature)}',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider.formatTempValue(weather.temperature),
                    style: AppTextStyles.temperatureLarge.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      provider.tempUnit,
                      style: AppTextStyles.temperatureMedium.copyWith(
                        color: AppColors.onHeroSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppSizes.paddingS),

          // Weather condition description
          Text(
            weather.condition.description,
            textAlign: TextAlign.center,
            style: AppTextStyles.heading2.copyWith(color: Colors.white),
          ),

          const SizedBox(height: AppSizes.paddingM),

          // Data timestamp (thoi diem cua du lieu, khong phai luc tai)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSizes.paddingS,
            runSpacing: AppSizes.paddingXS,
            children: [
              Text(
                'Cập nhật: ${DateFormat('dd/MM HH:mm').format(weather.lastUpdated)}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.onHeroSecondary,
                ),
              ),
              if (provider.isStale) const StaleBadge(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Badge canh bao du lieu cu (> 3 gio hoac dang dung cache offline).
class StaleBadge extends StatelessWidget {
  const StaleBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Dữ liệu cũ',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.paddingS,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: Colors.orange.shade700,
          borderRadius: BorderRadius.circular(AppSizes.borderRadiusS),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history_rounded, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              'Dữ liệu cũ',
              style: AppTextStyles.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
