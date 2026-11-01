part of '../forecast_widgets.dart';

class DaySummaryCard extends StatelessWidget {
  const DaySummaryCard({super.key, required this.day, this.hours = const []});

  final DailyForecast day;

  /// Cac gio cua ngay [day] (de dem so gio co mua); rong = chua co.
  final List<HourlyForecast> hours;

  /// Tag Hero dung chung voi danh sach 7 ngay o Home.
  static String heroTag(DateTime date) =>
      'day-${DateFormat('yyyy-MM-dd').format(date)}';

  /// Khung gio co so lieu: du 24 gio -> "cả ngày", thieu -> "21:00–23:00";
  /// khong co gio nao -> null.
  static String? hoursWindow(List<HourlyForecast> dayHours) {
    if (dayHours.isEmpty) return null;
    if (dayHours.length >= 24) return 'cả ngày';
    return '${ForecastFormat.hourMinute(dayHours.first.time)}–'
        '${ForecastFormat.hourMinute(dayHours.last.time)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final units = PreferencesProvider.unitsOf(context);
    final unit = units.tempUnit;
    final dayHours = [
      for (final h in hours)
        if (ForecastFormat.sameDay(h.time, day.date) &&
            (h.precipitationMm ?? h.precipitationMedian) != null)
          h,
    ];
    final rainyHours = dayHours
        .where((h) => (h.precipitationMm ?? h.precipitationMedian)! >= 0.1)
        .length;
    // Ghi ro khung tinh: "Tổng mưa" la ca ngay (so lieu ngay), "Giờ có mưa"
    // chi dem cac gio co so lieu -> khong bi doc nhu hai so mau thuan.
    final hoursWindow = DaySummaryCard.hoursWindow(dayHours);
    // Trung vi chi co nghia voi so lieu nhieu nam (du bao: trung vi = tong).
    final showMedian =
        (day.source ?? SourceSummary.fallback) == DataSource.climatology;
    final trend = day.isLowConfidence;
    final stats = <_Stat>[
      _Stat(
        Icons.thermostat_rounded,
        StatTone.warm,
        trend ? 'Thấp / Cao (xu hướng)' : 'Thấp / Cao',
        '${trend ? '~' : ''}${units.tempNumber(day.tempMin)}° / '
        '${units.tempNumber(day.tempMax)}$unit',
      ),
      _Stat(
        Icons.water_drop_rounded,
        StatTone.water,
        day.isObserved ? 'Tổng mưa cả ngày (đã ghi nhận)' : 'Tổng mưa cả ngày',
        units.rainText(day.precipitationMm),
      ),
      _Stat(
        Icons.schedule_rounded,
        StatTone.water,
        'Giờ có mưa',
        dayHours.isEmpty ? '--' : '$rainyHours/${dayHours.length} giờ',
        // Khung gio dem (dong rieng, khong cat giua "21:00–23:00").
        note: hoursWindow == null
            ? null
            : hoursWindow == 'cả ngày'
            ? 'Cả ngày'
            : 'Trong $hoursWindow',
      ),
      if (showMedian)
        _Stat(
          Icons.water_drop_outlined,
          StatTone.water,
          'Lượng mưa thường gặp',
          units.rainText(day.precipitationMedian),
        ),
      _Stat(
        Icons.air_rounded,
        StatTone.air,
        'Gió mạnh nhất',
        units.windText(day.windSpeed),
      ),
      if (day.windGusts != null)
        _Stat(
          Icons.storm_rounded,
          StatTone.air,
          'Gió giật mạnh nhất',
          PreferencesProvider.unitsOf(context).windText(day.windGusts),
        ),
      if (day.humidity != null)
        _Stat(
          Icons.opacity_rounded,
          StatTone.neutral,
          'Độ ẩm TB',
          WeatherFormat.percent(day.humidity),
        ),
    ];
    final anyMissing =
        dayHours.isEmpty ||
        (showMedian && day.precipitationMedian == null) ||
        day.windSpeed == null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeroMode(
              enabled: !chartMotionOff(context),
              child: Hero(
                tag: heroTag(day.date),
                child: Material(
                  type: MaterialType.transparency,
                  child: Row(
                    children: [
                      Opacity(
                        opacity: trend ? kLowConfidenceOpacity : 1,
                        child: WeatherIcon.fromCode(
                          day.displayWeatherCode ??
                              wmoForCondition(day.condition),
                          isDay: true,
                          size: IconSizes.state,
                        ),
                      ),
                      const SizedBox(width: Space.l),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trend ? 'Xu hướng' : day.condition.description,
                              style: TypeScale.heading2.copyWith(
                                color: theme.textTheme.titleLarge?.color,
                              ),
                            ),
                            Text(
                              ForecastFormat.title(day.date),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.l),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = Space.s;
                final w = (constraints.maxWidth - gap) / 2;
                return Wrap(
                  spacing: gap,
                  runSpacing: Space.l,
                  children: [
                    for (final s in stats)
                      SizedBox(
                        width: w,
                        child: _StatTile(stat: s),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: Space.l),
            Text(
              [
                'Giờ có mưa: giờ có từ 0,1 mm trở lên.',
                if (showMedian)
                  'Lượng mưa thường gặp: giá trị trung vị trong ngày.',
                if (anyMissing) '"--": chưa có số liệu.',
              ].join(' '),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat {
  const _Stat(this.icon, this.tone, this.label, this.value, {this.note});
  final IconData icon;
  final StatTone tone;
  final String label;
  final String value;

  /// Dong phu duoi gia tri (vd. khung gio "Trong 21:00–23:00").
  final String? note;
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label:
          '${stat.label}: ${stat.value}'
          '${stat.note == null ? '' : ', ${stat.note}'}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            stat.icon,
            size: IconSizes.inline,
            color: AppColors.statIcon(context, stat.tone),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stat.label, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  stat.value,
                  style: TypeScale.heading3.copyWith(
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                ),
                if (stat.note != null)
                  Text(stat.note!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The thong bao (khong co du lieu theo gio, loi...).
