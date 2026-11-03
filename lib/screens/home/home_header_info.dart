import '../../models/place.dart';

export '../../models/place.dart' show friendlyRegion;
import '../../models/units.dart';
import '../../models/weather.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/weather_insights.dart';
import '../../ui/weather/widgets/collapsing_header.dart';
import '../../utils/forecast_format.dart';

/// Thong tin dau trang: ten, nhiet do, tom tat mua, nguon va do moi.
WeatherHeaderInfo homeHeaderInfo(
  WeatherProvider provider,
  CurrentWeather? c, {
  required Place location,
  required UnitPrefs units,
  String? label,
}) {
  final d = friendlyRegion(location.detail);
  final detail = label == null ? d : '$label · $d';

  if (c == null) {
    return WeatherHeaderInfo(city: location.name, detail: detail);
  }
  String t(double v) => '${units.tempNumber(v)}°';
  final today = provider.todayForecast;
  final summary = heroRainSummary(
    provider.hourlyForecast,
    nowHcm: provider.nowHcm,
    isStale: provider.isStale || provider.weatherData?.forecastError != null,
  );
  final hiLo = [
    if (today != null) 'Cao ${t(today.tempMax)} · Thấp ${t(today.tempMin)}',
    if (c.feelsLike != null &&
        !c.fieldSources.containsKey('apparent_temperature'))
      'Cảm giác ${t(c.feelsLike!)}',
  ];
  final updatedAt = c.lastUpdated;
  final sameDay = ForecastFormat.sameDay(updatedAt, provider.nowHcm);
  final cachedAt = provider.cachedAt;
  return WeatherHeaderInfo(
    city: location.name,
    detail: detail,
    temperature: t(c.temperature),
    condition: switch (c.source) {
      DataSource.ai => 'AI dự báo: ${c.condition.description}',
      DataSource.observed => 'Ước tính: ${c.condition.description}',
      _ => c.condition.description,
    },
    // Mot dong: Cao · Thap · Cam giac.
    highLow: hiLo.isEmpty ? null : hiLo.join(' · '),
    today:
        summary ??
        (provider.hourlyForecast.isEmpty
            ? null
            : provider.isStale
            ? 'Dữ liệu cũ; chưa thể kết luận về mưa'
            : 'Chưa đủ dữ liệu để kết luận về mưa'),
    todayRain:
        summary != null &&
        !summary.contains('không mưa') &&
        !summary.startsWith('Không mưa'),
    refreshing: provider.isRefreshing && provider.isFromCache,
    updated: c.source == DataSource.ai
        ? 'Dự báo cho ${sameDay ? ForecastFormat.hourMinute(updatedAt) : ForecastFormat.dateTime(updatedAt)}'
        : provider.isRefreshing && provider.isFromCache && cachedAt != null
        ? 'Cập nhật lúc ${ForecastFormat.hourMinute(cachedAt)}'
        : 'Cập nhật ${sameDay ? ForecastFormat.hourMinute(updatedAt) : ForecastFormat.dateTime(updatedAt)}',
    isStale: provider.isStale,
    staleAt: provider.isStale
        ? 'Lúc ${ForecastFormat.dateTime(updatedAt)}'
        : null,
    sourceLabel: switch (c.source) {
      null => null,
      DataSource.observed => 'ước tính mô hình theo giờ',
      DataSource.forecast => 'dự báo mô hình',
      DataSource.ai => 'AI của nhóm · theo giờ',
      DataSource.climatology => 'trung bình nhiều năm',
    },
    cachedNote: provider.isFromCache && cachedAt != null
        ? 'Đã lưu ${ForecastFormat.dateTime(cachedAt)}'
        : null,
    semanticsTemp: provider.isStale
        ? 'Nhiệt độ lúc ${ForecastFormat.dateTime(updatedAt)} '
              '(dữ liệu cũ): ${units.tempText(c.temperature)}'
        : 'Nhiệt độ hiện tại: ${units.tempText(c.temperature)}',
  );
}
