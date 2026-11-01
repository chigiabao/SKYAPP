import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/units.dart';
import '../models/weather.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../utils/forecast_format.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/ios_sheet.dart';

part 'ai_forecast/interval_note.dart';
part 'ai_forecast/prediction_column.dart';

/// The kinh "Dự báo AI (thử nghiệm)": hang o 1h / 3h / 6h, moi o co gio muc
/// tieu tuyet doi, nhiet do, thanh kha nang mua; lien ket "Kiểm chứng" mau
/// nhan cua canh. forecast == null -> "Chưa có dự báo AI" (khong so gia).
///
/// [compact] = 1-2 dong cho Home ("AI: 3h tới 26° (25–27°), mưa 40%") + lien
/// ket "Chi tiết" mo man kiem chung; khong co chu ky thuat (ten mo hinh...).
class AIForecastCard extends StatelessWidget {
  final AIForecast? forecast;
  final bool compact;

  /// Mo man kiem chung AI (man hinh truyen vao; widget dung chung khong
  /// import man hinh).
  final VoidCallback onVerify;

  const AIForecastCard({
    super.key,
    required this.forecast,
    required this.onVerify,
    this.compact = false,
  });

  /// Moc hien o ban compact: uu tien 3h, khong co thi moc dau tien.
  static AIPrediction? compactPrediction(AIForecast? f) {
    if (f == null || f.predictions.isEmpty) return null;
    return f.predictions.where((p) => p.timeLabel == '3h').firstOrNull ??
        f.predictions.first;
  }

  /// Cau compact, vd "AI: 3h tới 26° (25–27°), mưa 40%".
  static String compactText(
    AIForecast? f,
    WeatherProvider provider, {
    required UnitPrefs units,
  }) {
    final p = compactPrediction(f);
    if (f == null || p == null) return 'AI: chưa có dự báo';
    String t(double c) => units.tempNumber(c);
    final range = f.isEnabled('temperature_interval') && p.hasInterval
        ? ' (${t(p.intervalLow!)}–${t(p.intervalHigh!)}°)'
        : '';
    final rain = f.isEnabled('rain_probability')
        ? ', mưa ${p.rainPercent}%'
        : '';
    final replay = f.forecastMode == 'retrospective' || provider.isReplay;
    final lead = replay
        ? 'AI hồi cứu: sau ${p.timeLabel}'
        : 'AI: ${p.timeLabel} tới';
    return '$lead ${t(p.temperature)}°$range$rain';
  }

  /// "lgbm-hcmc-v2-20261015" -> "mô hình v2"; khong co so phien ban -> null.
  static String? shortModel(String version) {
    final m = RegExp(r'(?:^|[-_])v(\d+)(?:[-_]|$)').firstMatch(version);
    return m == null ? null : 'mô hình v${m.group(1)}';
  }

  Widget _buildCompact(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final text = compactText(
      forecast,
      provider,
      units: PreferencesProvider.unitsOf(context),
    );
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.cardPadding,
        vertical: Space.xs,
      ),
      child: Pressable(
        onTap: onVerify,
        semanticsLabel: '$text. Chi tiết dự báo AI',
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Touch.min),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: IconSizes.sm,
                  color: ink.accent,
                ),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s),
                    child: Text(
                      text,
                      style: TypeScale.label.copyWith(
                        color: Palette.white,
                        fontFeatures: kTabular,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Space.s),
                // Nhan "Chi tiết" giu tren mot dong (khong bi bẻ "Chi tiế/t");
                // phan chu ben trai xuong dong khi chu lon.
                Text(
                  'Chi tiết',
                  maxLines: 1,
                  softWrap: false,
                  style: TypeScale.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: ink.accent,
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: IconSizes.sm,
                  color: ink.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (compact) return _buildCompact(context);
    final f = forecast;
    final ink = GlassInk.of(context);
    return GlassCard(
      title: 'AI ngắn hạn 1–6 giờ (thử nghiệm)',
      icon: Icons.auto_awesome_outlined,
      trailing: Pressable(
        onTap: onVerify,
        semanticsLabel: 'Kiểm chứng dự báo AI',
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: Touch.min,
              minWidth: Touch.min,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    'Kiểm chứng',
                    style: TypeScale.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: ink.accent,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: IconSizes.md,
                  color: ink.accent,
                ),
              ],
            ),
          ),
        ),
      ),
      footer: _footer(f),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _subtitle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TypeScale.footnote.copyWith(
              color: ink.secondary,
              fontFeatures: kTabular,
            ),
          ),
          if (f != null && f.predictions.isNotEmpty) ...[
            const SizedBox(height: Space.xs),
            AIEvaluationLine(evaluation: f.evaluation),
          ],
          const SizedBox(height: Space.m),
          if (f == null || f.predictions.isEmpty)
            const _UnavailableState()
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final count = f.predictions.length;
                final columnWidth =
                    (constraints.maxWidth - (count - 1) * Space.xl) / count;
                final stacked =
                    columnWidth < MediaQuery.textScalerOf(context).scale(90);
                final columns = [
                  for (final prediction in f.predictions)
                    _PredictionColumn(
                      prediction: prediction,
                      forecast: f,
                      domain: _domain(f),
                    ),
                ];
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < columns.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: Space.xl,
                            color: Palette.divider,
                          ),
                        IntrinsicHeight(child: columns[i]),
                      ],
                    ],
                  );
                }
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < columns.length; i++) ...[
                        if (i > 0)
                          const VerticalDivider(
                            width: Space.xl,
                            thickness: 1,
                            color: Palette.divider,
                          ),
                        Expanded(child: columns[i]),
                      ],
                    ],
                  ),
                );
              },
            ),
          if (f != null && _showsInterval(f)) ...[
            const SizedBox(height: Space.s),
            AIIntervalNote(forecast: f),
          ],
        ],
      ),
    );
  }

  static bool _showsInterval(AIForecast f) =>
      f.isEnabled('temperature_interval') &&
      f.predictions.any((p) => p.hasInterval);

  String _footer(AIForecast? f) {
    final rain = f == null || f.isEnabled('rain_probability')
        ? '% = khả năng mưa. '
        : '';
    return '${rain}Dự báo AI Sky Weather (mô hình của nhóm, học từ dữ liệu '
        'đầu vào giờ đã qua); chỉ mang tính tham khảo.';
  }

  /// Mien chung (do C) cho thanh khoang: tu can duoi thap nhat toi can tren
  /// cao nhat.
  static (double, double)? _domain(AIForecast f) {
    if (!_showsInterval(f)) return null;
    double? lo, hi;
    for (final p in f.predictions) {
      for (final v in [p.temperature, p.intervalLow, p.intervalHigh]) {
        if (v == null) continue;
        lo = lo == null || v < lo ? v : lo;
        hi = hi == null || v > hi ? v : hi;
      }
    }
    if (lo == null || hi == null) return null;
    // Tranh mien qua hep lam thanh khoang trong qua to.
    if (hi - lo < 2) {
      final mid = (hi + lo) / 2;
      return (mid - 1, mid + 1);
    }
    return (lo, hi);
  }

  String _subtitle(BuildContext context) {
    final f = forecast;
    if (f == null) return 'Mô hình dự đoán 1h / 3h / 6h';
    final now = context.read<WeatherProvider>().nowHcm;
    final issued = ForecastFormat.sameDay(f.issuedAt, now)
        ? ForecastFormat.hourMinute(f.issuedAt)
        : ForecastFormat.dateTime(f.issuedAt);
    final model = shortModel(f.modelVersion);
    final replay =
        f.forecastMode == 'retrospective' ||
        context.read<WeatherProvider>().isReplay;
    final label = replay ? 'Mô phỏng hồi cứu' : 'Phát hành';
    return model == null ? '$label $issued' : '$label $issued · $model';
  }
}
