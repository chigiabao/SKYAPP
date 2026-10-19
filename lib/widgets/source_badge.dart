import 'package:flutter/material.dart';

import '../models/data_source.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';

/// Mau nhan dien nguon (du tuong phan tren nen the sang/toi).
/// Tren nen kinh (theme co [GlassThemeMarker]) chu luon trang; mau nguon chi
/// con o cham tron (nhan chu van phan biet nguon).
Color sourceColor(BuildContext context, DataSource source) {
  if (GlassThemeMarker.isGlass(context)) return Colors.white;
  return sourceDotColor(context, source);
}

/// Mau cham nhan dien nguon (tin hieu phu, khong phai chu).
Color sourceDotColor(BuildContext context, DataSource source) {
  final dark =
      GlassThemeMarker.isGlass(context) ||
      Theme.of(context).brightness == Brightness.dark;
  switch (source) {
    case DataSource.observed:
      return dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
    case DataSource.forecast:
      return dark ? const Color(0xFF90CAF9) : AppColors.primaryDark;
    case DataSource.ai:
      return dark ? const Color(0xFF80CBC4) : const Color(0xFF00695C);
    case DataSource.climatology:
      return dark ? const Color(0xFFFFB74D) : const Color(0xFFB45309);
  }
}

/// Nhan nho cho mot o/hang: cham mau + nhan ngan ("Thực tế"...).
/// [onColor]: ve tren nen dam (o "Bây giờ") -> dung mau nay cho chu.
class SourceTag extends StatelessWidget {
  const SourceTag({super.key, required this.source, this.onColor});

  final DataSource source;
  final Color? onColor;

  @override
  Widget build(BuildContext context) {
    final color = sourceColor(context, source);
    final dot = onColor ?? sourceDotColor(context, source);
    return Semantics(
      label: 'Nguồn: ${source.shortLabel}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 3),
          Text(
            source.shortLabel,
            maxLines: 1,
            style: AppTextStyles.caption.copyWith(
              fontSize: 12,
              color: onColor ?? color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chu thich nguon khi danh sach tron nguon: MOT dong (tu xuong dong khi
/// hep) "● Thực tế (phân tích mô hình) · ● Dự báo (Open-Meteo)" kem nut (i)
/// giai thich chi tiet.
class SourceLegend extends StatelessWidget {
  const SourceLegend({super.key, required this.summary});

  final SourceSummary summary;

  /// Ghi chu ngan trong ngoac.
  static String short(DataSource s) {
    switch (s) {
      case DataSource.observed:
        return 'phân tích mô hình';
      case DataSource.forecast:
        return 'Open-Meteo';
      case DataSource.ai:
        return 'Sky Weather';
      case DataSource.climatology:
        return 'trung bình nhiều năm';
    }
  }

  /// Giai thich day du (tooltip / man hinh kiem chung).
  static String explain(DataSource s) {
    switch (s) {
      case DataSource.observed:
        return 'dữ liệu phân tích của mô hình, không phải trạm đo';
      case DataSource.forecast:
        return 'mô hình Open-Meteo';
      case DataSource.ai:
        return 'model do Sky Weather huấn luyện';
      case DataSource.climatology:
        return 'trung bình nhiều năm';
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.caption.copyWith(
      color: Theme.of(context).textTheme.bodySmall?.color,
    );
    final detail = [
      for (final s in summary.sources) '${s.shortLabel}: ${explain(s)}.',
    ].join(' ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                for (var i = 0; i < summary.sources.length; i++) ...[
                  if (i > 0) const TextSpan(text: '  ·  '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: sourceDotColor(context, summary.sources[i]),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  TextSpan(
                    text:
                        '${summary.sources[i].shortLabel} '
                        '(${short(summary.sources[i])})',
                  ),
                ],
              ],
            ),
            style: style,
          ),
        ),
        Tooltip(
          message: detail,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 6),
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: style.color,
            ),
          ),
        ),
      ],
    );
  }
}

/// Dong nguon cuoi the: mot nguon -> nhan day du; tron nguon -> chu thich
/// mot dong ([SourceLegend]).
class SourceSubtitle extends StatelessWidget {
  const SourceSubtitle({super.key, required this.summary});

  final SourceSummary summary;

  @override
  Widget build(BuildContext context) {
    if (summary.isMixed) return SourceLegend(summary: summary);
    return Text(
      summary.label,
      style: AppTextStyles.caption.copyWith(
        color: Theme.of(context).textTheme.bodySmall?.color,
      ),
    );
  }
}

/// Nguon can gan nhan rieng tung muc: chi khi danh sach TRON nguon, va chi
/// cac nguon thieu so (nguon chiem nhieu muc nhat da ghi o dong cuoi the).
/// Muc khong co `source` tinh la [SourceSummary.fallback].
Set<DataSource> minoritySources(Iterable<DataSource?> items) {
  final counts = <DataSource, int>{};
  for (final s in items) {
    final k = s ?? SourceSummary.fallback;
    counts[k] = (counts[k] ?? 0) + 1;
  }
  if (counts.length < 2) return const {};
  final majority = counts.entries
      .reduce((a, b) => b.value > a.value ? b : a)
      .key;
  return {
    for (final k in counts.keys)
      if (k != majority) k,
  };
}
