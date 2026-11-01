part of '../ai_forecast_card.dart';

/// Chua co danh gia nhieu ngay cho o luoi chua dia diem (khac voi kiem
/// chung tung moc o tren).
const String kNoCellEvaluation =
    'Chưa có đánh giá nhiều ngày của AI cho ô lưới ~8 km chứa địa điểm này.';

/// Mot dong ve danh gia mo hinh tai khu vuc (o luoi) cua dia diem:
///   * vuot mo hinh co so -> MAE nhiet do tai o luoi, khong phai khoang;
///   * chua vuot -> canh bao nhe;
///   * khong co danh gia -> [kNoCellEvaluation].
class AIEvaluationLine extends StatelessWidget {
  const AIEvaluationLine({super.key, required this.evaluation});

  final AIEvaluation? evaluation;

  /// Cau hien thi (dung chung voi man hinh kiem chung).
  static String text(AIEvaluation? e, UnitPrefs units) {
    if (e == null) return kNoCellEvaluation;
    if (e.beatsBaselines == false) {
      return 'Tại ô lưới này, AI chưa vượt mô hình cơ sở';
    }
    final h = e.primaryHorizon;
    if (h == null) return kNoCellEvaluation;
    return 'MAE nhiệt độ tại ô lưới này: '
        '${units.tempDeltaText(e.temperatureMae[h]!)} ($h)';
  }

  @override
  Widget build(BuildContext context) {
    final units = PreferencesProvider.unitsOf(context);
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
            text(e, units),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TypeScale.footnote.copyWith(
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
              style: TypeScale.footnote.copyWith(color: ink.secondary),
            ),
          ),
        ),
        if (notes.isNotEmpty)
          Semantics(
            button: true,
            label: 'Giải thích khoảng nhiệt độ',
            excludeSemantics: true,
            child: CupertinoButton(
              key: const ValueKey('interval-note-info'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(Touch.min, Touch.min),
              onPressed: () => showIosInfoSheet(
                context,
                title: 'Khoảng nhiệt độ',
                message: notes.join('\n\n'),
              ),
              child: Icon(
                CupertinoIcons.info_circle,
                size: IconSizes.md,
                color: ink.secondary,
              ),
            ),
          ),
      ],
    );
  }
}
