import 'package:flutter/material.dart';

// Weather condition enum with icons
enum WeatherCondition {
  sunny,
  partlyCloudy,
  cloudy,
  drizzle,
  rainy,
  showers,
  thunderstorm,
  foggy,
  windy,
}

/// Map WMO weather code (Open-Meteo) sang WeatherCondition.
/// null hoac ma khong ho tro -> cloudy (trung tinh).
WeatherCondition conditionFromWmo(int? code) {
  if (code == null) return WeatherCondition.cloudy;
  if (code == 0) return WeatherCondition.sunny;
  if (code == 1 || code == 2) return WeatherCondition.partlyCloudy;
  if (code == 3) return WeatherCondition.cloudy;
  if (code == 45 || code == 48) return WeatherCondition.foggy;
  if (code >= 51 && code <= 57) return WeatherCondition.drizzle;
  if (code >= 61 && code <= 67) return WeatherCondition.rainy;
  if (code >= 80 && code <= 82) return WeatherCondition.showers;
  if (code >= 95 && code <= 99) return WeatherCondition.thunderstorm;
  return WeatherCondition.cloudy;
}

extension WeatherConditionExtension on WeatherCondition {
  String get description {
    switch (this) {
      case WeatherCondition.sunny:
        return 'Trời quang';
      case WeatherCondition.partlyCloudy:
        return 'Có mây';
      case WeatherCondition.cloudy:
        return 'Nhiều mây';
      case WeatherCondition.drizzle:
        return 'Mưa phùn';
      case WeatherCondition.rainy:
        return 'Có mưa';
      case WeatherCondition.showers:
        return 'Mưa rào';
      case WeatherCondition.thunderstorm:
        return 'Dông bão';
      case WeatherCondition.foggy:
        return 'Sương mù';
      case WeatherCondition.windy:
        return 'Gió lớn';
    }
  }

  IconData get icon {
    switch (this) {
      case WeatherCondition.sunny:
        return Icons.wb_sunny_rounded;
      case WeatherCondition.partlyCloudy:
        return Icons.wb_cloudy_rounded;
      case WeatherCondition.cloudy:
        return Icons.cloud_rounded;
      case WeatherCondition.drizzle:
        return Icons.grain_rounded;
      case WeatherCondition.rainy:
        return Icons.water_drop_rounded;
      case WeatherCondition.showers:
        return Icons.umbrella_rounded;
      case WeatherCondition.thunderstorm:
        return Icons.thunderstorm_rounded;
      case WeatherCondition.foggy:
        return Icons.foggy;
      case WeatherCondition.windy:
        return Icons.air_rounded;
    }
  }

  Color get color {
    switch (this) {
      case WeatherCondition.sunny:
        return const Color(0xFFFFB74D);
      case WeatherCondition.partlyCloudy:
        return const Color(0xFF90CAF9);
      case WeatherCondition.cloudy:
        return const Color(0xFF90A4AE);
      case WeatherCondition.drizzle:
        return const Color(0xFF81D4FA);
      case WeatherCondition.rainy:
        return const Color(0xFF4FC3F7);
      case WeatherCondition.showers:
        return const Color(0xFF29B6F6);
      case WeatherCondition.thunderstorm:
        return const Color(0xFF7E57C2);
      case WeatherCondition.foggy:
        return const Color(0xFFBDBDBD);
      case WeatherCondition.windy:
        return const Color(0xFF80DEEA);
    }
  }
}
