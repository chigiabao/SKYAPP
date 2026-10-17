import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/weather_provider.dart';
import '../screens/ai_verify_screen.dart';
import '../screens/forecast/forecast_format.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';

/// The kinh "Dự báo AI (thử nghiệm)": hang o 1h / 3h / 6h, moi o co gio muc
/// tieu tuyet doi, nhiet do, thanh kha nang mua; lien ket "Kiểm chứng" mau
/// nhan cua canh. forecast == null -> "Chưa có dự báo AI" (khong so gia).
class AIForecastCard extends StatelessWidget {
  final AIForecast? forecast;

  const AIForecastCard({super.key, required this.forecast});

  /// "lgbm-hcmc-v2-20261015" -> "mô hình v2"; khong co so phien ban -> null.
  static String? shortModel(String version) {
    final m = RegExp(r'(?:^|[-_])v(\d+)(?:[-_]|$)').firstMatch(version);
    return m == null ? null : 'mô hình v${m.group(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final f = forecast;
    final ink = GlassInk.of(context);
    return GlassCard(
      title: 'Dự báo AI (thử nghiệm)',
      icon: Icons.auto_awesome_outlined,
      trailing: Pressable(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AIVerifyScreen())),
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
                Text(
                  'Kiểm chứng',
                  style: TypeScale.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: ink.accent,
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
      footer:
          '% = khả năng mưa. Mô hình LightGBM của nhóm, học từ dữ liệu '
          'Open-Meteo; chỉ mang tính tham khảo.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _subtitle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TypeScale.small.copyWith(
              fontSize: 13,
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
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < f.predictions.length; i++) ...[
                    if (i > 0)
                      const VerticalDivider(
                        width: Space.xl,
                        thickness: 1,
                        color: Palette.divider,
                      ),
                    Expanded(
                      child: _PredictionColumn(prediction: f.predictions[i]),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle(BuildContext context) {
    final f = forecast;
    if (f == null) return 'Mô hình dự đoán 1h / 3h / 6h';
    final now = context.read<WeatherProvider>().nowHcm;
    final issued = DateFormat(
      ForecastFormat.sameDay(f.issuedAt, now) ? 'HH:mm' : 'dd/MM HH:mm',
    ).format(f.issuedAt);
    final model = shortModel(f.modelVersion);
    return model == null ? 'Phát hành $issued' : 'Phát hành $issued · $model';
  }
}

/// Do lech nhiet do (do C) theo don vi dang chon: "0,4°C".
String formatTempDelta(double celsiusDelta, WeatherProvider provider) {
  final v = provider.isCelsius ? celsiusDelta : celsiusDelta * 9 / 5;
  return '${v.toStringAsFixed(1).replaceAll('.', ',')}${provider.tempUnit}';
}

/// Mot dong ve danh gia mo hinh tai khu vuc (o luoi) cua dia diem:
///   * vuot mo hinh co so -> "Sai số kiểm chứng tại ô lưới này: ±0,4°C (1h)";
///   * chua vuot -> canh bao nhe;
///   * khong co danh gia -> "Chưa có đánh giá tại ô lưới này".
class AIEvaluationLine extends StatelessWidget {
  const AIEvaluationLine({super.key, required this.evaluation});

  final AIEvaluation? evaluation;

  /// Cau hien thi (dung chung voi man hinh kiem chung).
  static String text(AIEvaluation? e, WeatherProvider provider) {
    if (e == null) return 'Chưa có đánh giá tại ô lưới này';
    if (e.beatsBaselines == false) {
      return 'Tại ô lưới này, AI chưa vượt mô hình cơ sở';
    }
    final h = e.primaryHorizon;
    if (h == null) return 'Chưa có đánh giá tại ô lưới này';
    return 'Sai số kiểm chứng tại ô lưới này: '
        '±${formatTempDelta(e.temperatureMae[h]!, provider)} ($h)';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final e = evaluation;
    final warn = e != null && e.beatsBaselines == false;
    final good = e != null && !warn && e.primaryHorizon != null;
    final color = warn ? ink.warning : ink.secondary;
    return Row(
      children: [
        ExcludeSemantics(
          child: Icon(
            warn
                ? Icons.info_outline_rounded
                : good
                ? Icons.verified_outlined
                : Icons.help_outline_rounded,
            size: 14,
            color: color,
          ),
        ),
        const SizedBox(width: Space.xs),
        Expanded(
          child: Text(
            text(e, provider),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TypeScale.small.copyWith(
              fontSize: 13,
              color: color,
              fontWeight: warn ? FontWeight.w600 : FontWeight.w500,
              fontFeatures: kTabular,
            ),
          ),
        ),
      ],
    );
  }
}

class _UnavailableState extends StatelessWidget {
  const _UnavailableState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.m),
      decoration: BoxDecoration(
        color: Palette.subtleFill,
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: Row(
        children: [
          const ExcludeSemantics(
            child: Icon(
              Icons.hourglass_empty_rounded,
              size: IconSizes.md,
              color: Palette.white,
            ),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(
              'Chưa có dự báo AI',
              style: TypeScale.label.copyWith(color: Palette.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mot cot moc du bao (khong co nen rieng - tranh "the trong the").
class _PredictionColumn extends StatelessWidget {
  final AIPrediction prediction;

  const _PredictionColumn({required this.prediction});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final target = prediction.targetTime;
    final targetText = target == null
        ? 'Sau ${prediction.timeLabel}'
        : ForecastFormat.targetTime(target, provider.nowHcm);

    return Semantics(
      label:
          'Lúc $targetText (sau ${prediction.timeLabel}): '
          '${provider.formatTemperature(prediction.temperature)}, '
          'khả năng mưa ${prediction.rainPercent}%',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SAU ${prediction.timeLabel.toUpperCase()}',
            style: TypeScale.cardTitle.copyWith(color: ink.title),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              targetText,
              style: TypeScale.hourLabel.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Palette.white,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${provider.formatTempValue(prediction.temperature)}°',
              style: TypeScale.bigValue.copyWith(color: Palette.white),
            ),
          ),
          const Spacer(),
          const SizedBox(height: Space.s),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.water_drop_outlined, size: 14, color: ink.rain),
                const SizedBox(width: 2),
                Text(
                  '${prediction.rainPercent}%',
                  style: TypeScale.small.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ink.rain,
                    fontFeatures: kTabular,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xs),
          _RainBar(percent: prediction.rainPercent, color: ink.rain),
        ],
      ),
    );
  }
}

class _RainBar extends StatelessWidget {
  final int percent;
  final Color color;

  const _RainBar({required this.percent, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.bar),
      child: SizedBox(
        height: 4,
        width: double.infinity,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Palette.track)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: percent.clamp(0, 100) / 100,
              heightFactor: 1,
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
