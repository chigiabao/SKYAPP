import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../screens/ai_verify_screen.dart';
import '../screens/forecast/forecast_format.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';

/// The kinh "Dự báo AI (thử nghiệm)": hang o 1h / 3h / 6h, moi o co gio muc
/// tieu tuyet doi, nhiet do, thanh kha nang mua; lien ket "Kiểm chứng" mau
/// nhan cua canh. forecast == null -> "Chưa có dự báo AI" (khong so gia).
///
/// [compact] = 1-2 dong cho Home ("AI: 3h tới 26° (25–27°), mưa 40%") + lien
/// ket "Chi tiết" mo man kiem chung; khong co chu ky thuat (ten mo hinh...).
class AIForecastCard extends StatelessWidget {
  final AIForecast? forecast;
  final bool compact;

  const AIForecastCard({
    super.key,
    required this.forecast,
    this.compact = false,
  });

  /// Moc hien o ban compact: uu tien 3h, khong co thi moc dau tien.
  static AIPrediction? compactPrediction(AIForecast? f) {
    if (f == null || f.predictions.isEmpty) return null;
    return f.predictions.where((p) => p.timeLabel == '3h').firstOrNull ??
        f.predictions.first;
  }

  /// Cau compact, vd "AI: 3h tới 26° (25–27°), mưa 40%".
  static String compactText(AIForecast? f, WeatherProvider provider) {
    final p = compactPrediction(f);
    if (f == null || p == null) return 'AI: chưa có dự báo';
    String t(double c) => provider.formatTempValue(c);
    final range = f.isEnabled('temperature_interval') && p.hasInterval
        ? ' (${t(p.intervalLow!)}–${t(p.intervalHigh!)}°)'
        : '';
    final rain = f.isEnabled('rain_probability')
        ? ', mưa ${p.rainPercent}%'
        : '';
    return 'AI: ${p.timeLabel} tới ${t(p.temperature)}°$range$rain';
  }

  static void openDetails(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AIVerifyScreen()));

  /// "lgbm-hcmc-v2-20261015" -> "mô hình v2"; khong co so phien ban -> null.
  static String? shortModel(String version) {
    final m = RegExp(r'(?:^|[-_])v(\d+)(?:[-_]|$)').firstMatch(version);
    return m == null ? null : 'mô hình v${m.group(1)}';
  }

  Widget _buildCompact(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final text = compactText(forecast, provider);
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.cardPadding,
        vertical: Space.xs,
      ),
      child: Pressable(
        onTap: () => openDetails(context),
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
                  flex: 3,
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
                // Co chu lon: nhan "Chi tiết" tu xuong dong, khong tran.
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          'Chi tiết',
                          textAlign: TextAlign.end,
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
      title: 'Dự báo AI (thử nghiệm)',
      icon: Icons.auto_awesome_outlined,
      trailing: Pressable(
        onTap: () => openDetails(context),
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
    return '${rain}Mô hình LightGBM của nhóm, học từ dữ liệu '
        'Open-Meteo; chỉ mang tính tham khảo.';
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

/// Ten khoang theo muc tin cay: "khoảng 90%"; khong ro muc -> "khoảng dự báo".
String intervalLevelLabel(double? level) =>
    level == null ? 'khoảng dự báo' : 'khoảng ${(level * 100).round()}%';

/// Do phu thuc te cua khoang nhiet do (%, lam tron) - lay tu
/// `uncertainty_note` ("~77% số lần"), neu thieu thi tu danh gia o luoi.
int? intervalCoveragePercent(AIPrediction p, AIEvaluation? e) {
  final note = p.uncertaintyNote;
  if (note != null) {
    final m = RegExp(r'~\s*(\d{1,3})\s*%').firstMatch(note);
    if (m != null) return int.parse(m.group(1)!);
  }
  final c = e?.intervalCoverage[p.timeLabel];
  return c == null ? null : (c * 100).round();
}

/// Giai thich ngan khoang trong ngoac + nut (i) hien nguyen van
/// `uncertainty_note` cua backend.
class AIIntervalNote extends StatelessWidget {
  const AIIntervalNote({super.key, required this.forecast});

  final AIForecast forecast;

  static String text(AIForecast f) {
    final first = f.predictions.where((p) => p.hasInterval).firstOrNull;
    final cov = first == null
        ? null
        : intervalCoveragePercent(first, f.evaluation);
    final covText = cov == null
        ? ''
        : ', kiểm chứng thực tế rơi vào khoảng ~$cov% số lần';
    final label = intervalLevelLabel(first?.effectiveIntervalLevel);
    return 'Trong ngoặc: $label$covText. Đây là mức bất định, '
        'không phải điểm độ chính xác.';
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final notes = [
      for (final p in forecast.predictions)
        if (p.uncertaintyNote != null)
          'Sau ${p.timeLabel}: ${p.uncertaintyNote}',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(
              text(forecast),
              style: TypeScale.small.copyWith(
                fontSize: 13,
                color: ink.secondary,
              ),
            ),
          ),
        ),
        if (notes.isNotEmpty)
          Tooltip(
            message: notes.join('\n\n'),
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 8),
            child: Semantics(
              button: true,
              label: 'Giải thích khoảng nhiệt độ',
              child: SizedBox(
                width: Touch.min,
                height: Touch.min,
                child: Icon(
                  Icons.info_outline_rounded,
                  size: IconSizes.md,
                  color: ink.secondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Mot cot moc du bao (khong co nen rieng - tranh "the trong the").
class _PredictionColumn extends StatelessWidget {
  final AIPrediction prediction;
  final AIForecast forecast;

  /// Mien nhiet do (do C) chung cho thanh khoang; null = khong ve.
  final (double, double)? domain;

  const _PredictionColumn({
    required this.prediction,
    required this.forecast,
    this.domain,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final units = PreferencesProvider.unitsOf(context);
    final ink = GlassInk.of(context);
    final p = prediction;
    final target = p.targetTime;
    final targetText = target == null
        ? 'Sau ${p.timeLabel}'
        : ForecastFormat.targetTime(target, provider.nowHcm);
    final showInterval =
        forecast.isEnabled('temperature_interval') && p.hasInterval;
    final showRain = forecast.isEnabled('rain_probability');
    String t(double c) => provider.formatTempValue(c);
    final rangeText = showInterval
        ? '${t(p.intervalLow!)}–${t(p.intervalHigh!)}°'
        : null;

    final extras = <(IconData, String, String)>[
      if (forecast.isEnabled('humidity') && p.humidity != null)
        (Icons.opacity_rounded, 'Ẩm', '${p.humidity!.round()}%'),
      if (forecast.isEnabled('wind_speed') && p.windSpeed != null)
        (Icons.air_rounded, 'Gió', units.windText(p.windSpeed)),
      if (forecast.isEnabled('wind_gusts') && p.windGusts != null)
        (Icons.storm_outlined, 'Giật', units.windText(p.windGusts)),
      if (forecast.isEnabled('precipitation_mm') && p.precipitationMm != null)
        (Icons.umbrella_outlined, 'Mưa', units.rainText(p.precipitationMm)),
    ];

    final semantics = StringBuffer(
      'Lúc $targetText (sau ${p.timeLabel}): '
      '${provider.formatTemperature(p.temperature)}',
    );
    if (rangeText != null) {
      semantics.write(
        ', ${intervalLevelLabel(p.effectiveIntervalLevel)} từ '
        '${t(p.intervalLow!)} đến ${t(p.intervalHigh!)} độ',
      );
    }
    if (showRain) semantics.write(', khả năng mưa ${p.rainPercent}%');
    for (final e in extras) {
      semantics.write(', ${e.$2.toLowerCase()} ${e.$3}');
    }

    final small = TypeScale.small.copyWith(
      fontSize: 13,
      color: ink.secondary,
      fontFeatures: kTabular,
    );

    return Semantics(
      label: semantics.toString(),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SAU ${p.timeLabel.toUpperCase()}',
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
              '${t(p.temperature)}°',
              style: TypeScale.bigValue.copyWith(color: Palette.white),
            ),
          ),
          if (rangeText != null) ...[
            Text(
              '($rangeText)',
              style: small.copyWith(
                fontWeight: FontWeight.w600,
                color: Palette.white,
              ),
            ),
            if (domain != null) ...[
              const SizedBox(height: Space.xs),
              _IntervalBar(
                domain: domain!,
                low: p.intervalLow!,
                high: p.intervalHigh!,
                point: p.temperature,
                color: ink.accent,
              ),
            ],
          ],
          const SizedBox(height: Space.s),
          if (showRain) ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.water_drop_outlined, size: 14, color: ink.rain),
                  const SizedBox(width: 2),
                  Text(
                    '${p.rainPercent}%',
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
            _RainBar(percent: p.rainPercent, color: ink.rain),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: Space.s),
            for (final e in extras)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(e.$1, size: 14, color: ink.secondary),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        // Giu so + don vi tren cung dong khi xuong dong.
                        '${e.$2} ${e.$3.replaceAll(' ', String.fromCharCode(0x00A0))}',
                        style: small,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

/// Thanh nho: vach khoang nhiet do tren mien chung cua 3 moc, cham = gia tri du bao.
class _IntervalBar extends StatelessWidget {
  const _IntervalBar({
    required this.domain,
    required this.low,
    required this.high,
    required this.point,
    required this.color,
  });

  final (double, double) domain;
  final double low;
  final double high;
  final double point;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // CustomPaint thay LayoutBuilder: cot nam trong IntrinsicHeight.
    return SizedBox(
      height: 8,
      width: double.infinity,
      child: CustomPaint(
        painter: _IntervalPainter(
          domain: domain,
          low: low,
          high: high,
          point: point,
          color: color,
        ),
      ),
    );
  }
}

class _IntervalPainter extends CustomPainter {
  _IntervalPainter({
    required this.domain,
    required this.low,
    required this.high,
    required this.point,
    required this.color,
  });

  final (double, double) domain;
  final double low;
  final double high;
  final double point;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final (lo, hi) = domain;
    final span = hi - lo;
    final w = size.width;
    double x(double v) =>
        (span <= 0 ? 0.5 : ((v - lo) / span).clamp(0.0, 1.0)) * w;
    final cy = size.height / 2;
    final r = const Radius.circular(Radii.bar);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - 2, w, 4), r),
      Paint()..color = Palette.track,
    );
    final a = x(low);
    final b = math.max(x(high), math.min(a + 4, w));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(a, cy - 2, b, cy + 2), r),
      Paint()..color = color,
    );
    final px = x(point).clamp(4.0, math.max(4.0, w - 4)).toDouble();
    canvas.drawCircle(Offset(px, cy), 4, Paint()..color = Palette.white);
  }

  @override
  bool shouldRepaint(_IntervalPainter old) =>
      old.domain != domain ||
      old.low != low ||
      old.high != high ||
      old.point != point ||
      old.color != color;
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
