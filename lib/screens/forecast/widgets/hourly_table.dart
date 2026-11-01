part of '../forecast_widgets.dart';

class HourlyTable extends StatelessWidget {
  const HourlyTable({
    super.key,
    required this.hours,
    required this.nowIndex,
    required this.place,
    required this.units,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;

  /// Dia diem (ngay / dem cua bieu tuong theo toa do).
  final Place place;
  final UnitPrefs units;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = SourceSummary.of(hours.map((h) => h.source));
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(
            'Bảng chi tiết ${hours.length} giờ',
            style: TypeScale.bodyLarge.copyWith(
              color: theme.textTheme.bodyLarge?.color,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.only(bottom: Space.s),
          children: [
            for (var i = 0; i < hours.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: Space.l,
                  endIndent: Space.l,
                  color: theme.dividerTheme.color,
                ),
              _HourRow(
                hour: hours[i],
                isNow: i == nowIndex,
                place: place,
                units: units,
                sourceTag: summary.marks(hours[i].source)
                    ? (hours[i].source ?? SourceSummary.fallback)
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HourRow extends StatelessWidget {
  const _HourRow({
    required this.hour,
    required this.isNow,
    required this.place,
    required this.units,
    this.sourceTag,
  });

  final HourlyForecast hour;
  final bool isNow;
  final Place place;
  final UnitPrefs units;
  final DataSource? sourceTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rain = hour.isObserved
        ? 'Mưa đã ghi nhận ${PreferencesProvider.unitsOf(context).rainText(hour.precipitationMm)}'
        : hour.rainProbability == null
        ? 'Mưa: --'
        : 'Mưa ${hour.rainPercent}%';
    final mm = hour.precipitationMm ?? hour.precipitationMedian;
    final amount = hour.isObserved || mm == null
        ? ''
        : ' · ${PreferencesProvider.unitsOf(context).rainText(mm)}';
    final hasWind = hour.windSpeed != null || hour.windGusts != null;
    final wind = !hasWind
        ? null
        : 'Gió ${PreferencesProvider.unitsOf(context).windText(hour.windSpeed)}'
              '${hour.windGusts == null ? '' : ' · giật ${PreferencesProvider.unitsOf(context).windText(hour.windGusts)}'}'
              '${hour.windDirection == null ? '' : ' · ${WeatherFormat.compass(hour.windDirection)}'}';
    return Container(
      color: isNow ? Tones.brand.withValues(alpha: 0.10) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: Space.s + 2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${ForecastFormat.hourMinute(hour.time)} · '
                  '${isNow ? 'Bây giờ' : ForecastFormat.weekdayShort(hour.time)}',
                  style: TypeScale.bodyMedium.copyWith(
                    color: theme.textTheme.bodyLarge?.color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  hour.condition.description,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '$rain$amount',
                  style: TypeScale.bodySmall.copyWith(
                    color: AppColors.rainyText(context),
                  ),
                ),
                if (wind != null) Text(wind, style: theme.textTheme.bodySmall),
                if (sourceTag != null) SourceTag(source: sourceTag!),
              ],
            ),
          ),
          const SizedBox(width: Space.s),
          WeatherIcon.fromCode(
            hour.weatherCode ?? wmoForCondition(hour.condition),
            isDay: isDayAt(hour.time, lat: place.lat, lon: place.lon),
            size: IconSizes.row,
          ),
          const SizedBox(width: Space.s),
          Text(
            units.tempText(hour.temperature),
            style: TypeScale.temperatureSmall.copyWith(
              color: theme.textTheme.bodyLarge?.color,
            ),
          ),
        ],
      ),
    );
  }
}
