import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/place.dart';
import '../../models/units.dart';
import '../../models/weather.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../utils/constants.dart';
import '../../utils/formatters.dart';
import '../../widgets/source_badge.dart';
import '../../utils/forecast_format.dart';
import 'forecast_source.dart';
import '../../providers/preferences_provider.dart';
import '../../ui/weather/app_scene.dart';
import '../../ui/weather/weather_icons.dart';
import 'forecast_charts.dart' show chartMotionOff;
import '../../ui/weather/widgets/daily_forecast_list.dart'
    show kLowConfidenceOpacity, showConfidenceInfo;
import '../../utils/haptics.dart';

part 'widgets/day_picker.dart';
part 'widgets/day_summary_card.dart';
part 'widgets/hourly_table.dart';

/// Tieu de muc + dong phu tuy chon.
class ForecastSectionTitle extends StatelessWidget {
  const ForecastSectionTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Space.xl, bottom: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TypeScale.heading3.copyWith(
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
        : Tones.brand.withValues(alpha: 0.08);
    final chipFg = isDark ? Tones.textOnDark : Tones.brandDeep;

    Widget chip(IconData icon, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(Radii.large),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: chipFg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TypeScale.bodySmall.copyWith(
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
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            // Tron nguon: chi ghi nhan ngan ("Đã ghi nhận + Dự báo"), chu thich
            // mau ben duoi; khong lap "Nguồn: Nhiều nguồn: ...".
            chip(
              _icon(source),
              source.isMixed
                  ? 'Nguồn: ${source.summary!.sources.map((s) => s.shortLabel).join(' + ')}'
                  : 'Nguồn: ${source.label}',
            ),
            if (isFromCache)
              chip(
                Icons.cloud_off_rounded,
                cachedAt == null
                    ? 'Dữ liệu đã lưu'
                    : 'Đã lưu lúc ${ForecastFormat.dateTime(cachedAt!)}',
              ),
          ],
        ),
        if (!source.isMixed) ...[
          const SizedBox(height: Space.xs),
          Text(source.note, style: theme.textTheme.bodySmall),
        ],
        if (source.isMixed) ...[
          const SizedBox(height: Space.xs),
          SourceLegend(summary: source.summary!),
        ],
      ],
    );
  }

  static IconData _icon(ForecastSource source) {
    if (source.isMixed) return Icons.layers_outlined;
    switch (source.summary?.single) {
      case DataSource.forecast:
      case DataSource.ai:
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
        padding: const EdgeInsets.all(Space.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.textTheme.bodySmall?.color),
            const SizedBox(width: Space.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: theme.textTheme.bodyMedium),
                  if (action != null) ...[
                    const SizedBox(height: Space.s),
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

/// Canh bao do tin cay cua ngay dang chon (tab ngay). Chi hien khi backend
/// gui `confidence` medium/low; high hoac thieu (backend cu) -> rong.
class DayConfidenceNotice extends StatelessWidget {
  const DayConfidenceNotice({super.key, required this.day});

  final DailyForecast day;

  @override
  Widget build(BuildContext context) {
    final level = day.confidence;
    if (level == null || level == ForecastConfidence.high) {
      return const SizedBox.shrink();
    }
    final low = level == ForecastConfidence.low;
    final head = low
        ? 'Độ tin cậy thấp · chỉ là xu hướng.'
        : 'Độ tin cậy trung bình.';
    return ForecastMessageCard(
      icon: low ? Icons.info_outline_rounded : Icons.insights_rounded,
      message: [head, if (day.skillNote != null) day.skillNote!].join(' '),
      action: TextButton(
        onPressed: () => showConfidenceInfo(context),
        child: const Text('Vì sao?'),
      ),
    );
  }
}

/// Bang chi tiet theo gio (thu gon mac dinh).
