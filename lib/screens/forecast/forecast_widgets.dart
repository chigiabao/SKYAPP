import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/weather.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../utils/constants.dart';
import '../../utils/formatters.dart';
import '../../widgets/source_badge.dart';
import 'forecast_format.dart';
import 'forecast_source.dart';

/// Tieu de muc + dong phu tuy chon.
class ForecastSectionTitle extends StatelessWidget {
  const ForecastSectionTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSizes.paddingL,
        bottom: AppSizes.paddingS,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: AppTextStyles.heading3.copyWith(
                color: theme.textTheme.titleLarge?.color,
              ),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle!, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Dai chon ngay (cuon ngang). Ngay dang chon tu cuon vao giua.
class DayPicker extends StatefulWidget {
  const DayPicker({
    super.key,
    required this.days,
    required this.selectedIndex,
    required this.nowHcm,
    required this.onSelect,
  });

  final List<DailyForecast> days;
  final int selectedIndex;
  final DateTime nowHcm;
  final ValueChanged<int> onSelect;

  @override
  State<DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<DayPicker> {
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scrollToSelected();
  }

  @override
  void didUpdateWidget(DayPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) _scrollToSelected();
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final summary = SourceSummary.of(widget.days.map((d) => d.source));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.days.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: AppSizes.paddingS),
              child: _DayChip(
                key: i == widget.selectedIndex ? _selectedKey : null,
                day: widget.days[i],
                nowHcm: widget.nowHcm,
                selected: i == widget.selectedIndex,
                onTap: () => widget.onSelect(i),
                sourceTag: summary.marks(widget.days[i].source)
                    ? (widget.days[i].source ?? SourceSummary.fallback)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    super.key,
    required this.day,
    required this.nowHcm,
    required this.selected,
    required this.onTap,
    this.sourceTag,
  });

  final DailyForecast day;
  final DateTime nowHcm;
  final bool selected;
  final VoidCallback onTap;
  final DataSource? sourceTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final glass = GlassThemeMarker.isGlass(context);
    // Tren nen kinh: chon = trang dac + chu toi (~17:1); chua chon = kinh.
    // Ngoai kinh: chon = #1976D2, chu trang ~4.6:1.
    const onSelectedGlass = Color(0xFF0F172A);
    final bg = selected
        ? (glass ? Colors.white : AppColors.primaryDark)
        : glass
        ? (theme.cardTheme.color ?? Colors.transparent)
        : (isDark ? AppColors.darkCard : Colors.white);
    final fg = selected
        ? (glass ? onSelectedGlass : Colors.white)
        : theme.textTheme.bodyLarge?.color;
    final sub = selected
        ? (glass ? onSelectedGlass : AppColors.onHeroSecondary)
        : theme.textTheme.bodySmall?.color;
    final border = selected
        ? (glass ? Colors.white : AppColors.primaryDark)
        : glass
        ? Colors.white.withValues(alpha: 0.18)
        : (isDark ? Colors.white24 : Colors.black12);

    return Semantics(
      button: true,
      selected: selected,
      label: ForecastFormat.title(day.date),
      hint: sourceTag?.shortLabel,
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.borderRadius),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 68, minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSizes.paddingM,
                vertical: AppSizes.paddingS,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ForecastFormat.relativeDay(day.date, nowHcm),
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ForecastFormat.dayMonth(day.date),
                    style: AppTextStyles.bodySmall.copyWith(color: sub),
                  ),
                  const SizedBox(height: 4),
                  Icon(
                    day.condition.icon,
                    size: AppSizes.iconSizeS,
                    color: selected ? fg : day.condition.color,
                  ),
                  if (sourceTag != null) ...[
                    const SizedBox(height: 2),
                    SourceTag(
                      source: sourceTag!,
                      onColor: selected ? fg : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chip nguon du lieu + do moi (cache).
class ForecastSourceInfo extends StatelessWidget {
  const ForecastSourceInfo({
    super.key,
    required this.source,
    required this.isFromCache,
    this.cachedAt,
  });

  final ForecastSource source;
  final bool isFromCache;
  final DateTime? cachedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chipBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : AppColors.primaryLight.withValues(alpha: 0.08);
    final chipFg = isDark ? AppColors.textDark : AppColors.primaryDark;

    Widget chip(IconData icon, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(AppSizes.borderRadiusL),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: chipFg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: AppTextStyles.bodySmall.copyWith(
                color: chipFg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSizes.paddingS,
          runSpacing: AppSizes.paddingS,
          children: [
            chip(_icon(source), 'Nguồn: ${source.label}'),
            if (isFromCache)
              chip(
                Icons.cloud_off_rounded,
                cachedAt == null
                    ? 'Dữ liệu đã lưu'
                    : 'Đã lưu lúc ${DateFormat('HH:mm, dd/MM').format(cachedAt!)}',
              ),
          ],
        ),
        const SizedBox(height: AppSizes.paddingXS),
        Text(source.note, style: theme.textTheme.bodySmall),
        if (source.isMixed) ...[
          const SizedBox(height: AppSizes.paddingXS),
          SourceLegend(summary: source.summary!),
        ],
      ],
    );
  }

  static IconData _icon(ForecastSource source) {
    if (source.isMixed) return Icons.layers_outlined;
    switch (source.summary?.single) {
      case DataSource.forecast:
        return Icons.insights_rounded;
      case DataSource.observed:
        return Icons.fact_check_outlined;
      case DataSource.climatology:
      case null:
        return Icons.history_rounded;
    }
  }
}

/// Tom tat ngay: dieu kien, cao/thap, kha nang mua, luong mua thuong gap
/// (trung vi), gio manh nhat. Thieu so lieu -> "--".
class DaySummaryCard extends StatelessWidget {
  const DaySummaryCard({super.key, required this.day, required this.provider});

  final DailyForecast day;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = provider.tempUnit;
    final rainPct = day.rainDayPercent;
    final stats = <_Stat>[
      _Stat(
        Icons.thermostat_rounded,
        StatTone.warm,
        'Thấp / Cao',
        '${provider.formatTempValue(day.tempMin)}° / '
            '${provider.formatTempValue(day.tempMax)}$unit',
      ),
      _Stat(
        Icons.umbrella_rounded,
        StatTone.water,
        day.isObserved ? 'Mưa (thực tế, ≥ 1 mm)' : 'Khả năng mưa',
        day.observedRainText ?? WeatherFormat.percent(rainPct),
      ),
      _Stat(
        Icons.water_drop_rounded,
        StatTone.water,
        'Lượng mưa thường gặp',
        WeatherFormat.rainMm(day.precipitationMedian),
      ),
      _Stat(
        Icons.air_rounded,
        StatTone.air,
        'Gió mạnh nhất',
        WeatherFormat.speedKmh(day.windSpeed),
      ),
      if (day.windGusts != null)
        _Stat(
          Icons.storm_rounded,
          StatTone.air,
          'Gió giật mạnh nhất',
          WeatherFormat.speedKmh(day.windGusts),
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
        rainPct == null ||
        day.precipitationMedian == null ||
        day.windSpeed == null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  day.condition.icon,
                  size: AppSizes.iconSizeL,
                  color: day.condition.color,
                ),
                const SizedBox(width: AppSizes.paddingM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day.condition.description,
                        style: AppTextStyles.heading2.copyWith(
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
            const SizedBox(height: AppSizes.paddingM),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = AppSizes.paddingS;
                final w = (constraints.maxWidth - gap) / 2;
                return Wrap(
                  spacing: gap,
                  runSpacing: AppSizes.paddingM,
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
            const SizedBox(height: AppSizes.paddingM),
            Text(
              'Lượng mưa thường gặp: giá trị trung vị trong ngày.'
              '${anyMissing ? ' "--": chưa có số liệu.' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat {
  const _Stat(this.icon, this.tone, this.label, this.value);
  final IconData icon;
  final StatTone tone;
  final String label;
  final String value;
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '${stat.label}: ${stat.value}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            stat.icon,
            size: AppSizes.iconSizeS,
            color: AppColors.statIcon(context, stat.tone),
          ),
          const SizedBox(width: AppSizes.paddingS),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stat.label, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  stat.value,
                  style: AppTextStyles.heading3.copyWith(
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The thong bao (khong co du lieu theo gio, loi...).
class ForecastMessageCard extends StatelessWidget {
  const ForecastMessageCard({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.textTheme.bodySmall?.color),
            const SizedBox(width: AppSizes.paddingM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: theme.textTheme.bodyMedium),
                  if (action != null) ...[
                    const SizedBox(height: AppSizes.paddingS),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bang chi tiet theo gio (thu gon mac dinh).
class HourlyTable extends StatelessWidget {
  const HourlyTable({
    super.key,
    required this.hours,
    required this.nowIndex,
    required this.provider,
  });

  final List<HourlyForecast> hours;
  final int? nowIndex;
  final WeatherProvider provider;

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
            style: AppTextStyles.bodyLarge.copyWith(
              color: theme.textTheme.bodyLarge?.color,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.only(bottom: AppSizes.paddingS),
          children: [
            for (var i = 0; i < hours.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: AppSizes.paddingM,
                  endIndent: AppSizes.paddingM,
                  color: theme.dividerTheme.color,
                ),
              _HourRow(
                hour: hours[i],
                isNow: i == nowIndex,
                provider: provider,
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
    required this.provider,
    this.sourceTag,
  });

  final HourlyForecast hour;
  final bool isNow;
  final WeatherProvider provider;
  final DataSource? sourceTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rain = hour.isObserved
        ? 'Mưa thực tế ${WeatherFormat.rainMm(hour.precipitationMm)}'
        : hour.rainProbability == null
        ? 'Mưa: --'
        : 'Mưa ${hour.rainPercent}%';
    final amount = hour.isObserved || hour.precipitationMedian == null
        ? ''
        : ' · ${WeatherFormat.rainMm(hour.precipitationMedian)}';
    final hasWind = hour.windSpeed != null || hour.windGusts != null;
    final wind = !hasWind
        ? null
        : 'Gió ${WeatherFormat.speedKmh(hour.windSpeed)}'
              '${hour.windGusts == null ? '' : ' · giật ${WeatherFormat.speedKmh(hour.windGusts)}'}'
              '${hour.windDirection == null ? '' : ' · ${WeatherFormat.compass(hour.windDirection)}'}';
    return Container(
      color: isNow ? AppColors.primaryLight.withValues(alpha: 0.10) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSizes.paddingM,
        vertical: AppSizes.paddingS + 2,
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
                  style: AppTextStyles.bodyMedium.copyWith(
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
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.rainyText(context),
                  ),
                ),
                if (wind != null) Text(wind, style: theme.textTheme.bodySmall),
                if (sourceTag != null) SourceTag(source: sourceTag!),
              ],
            ),
          ),
          const SizedBox(width: AppSizes.paddingS),
          Icon(hour.condition.icon, color: hour.condition.color),
          const SizedBox(width: AppSizes.paddingS),
          Text(
            '${provider.formatTempValue(hour.temperature)}${provider.tempUnit}',
            style: AppTextStyles.temperatureSmall.copyWith(
              color: theme.textTheme.bodyLarge?.color,
            ),
          ),
        ],
      ),
    );
  }
}
