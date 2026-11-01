import 'package:flutter/material.dart';

import '../../models/units.dart';
import '../../models/weather.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../widgets/ai_forecast_card.dart';

/// Danh gia mo hinh tren tap kiem tra tai o luoi cua dia diem.
class EvaluationCard extends StatelessWidget {
  const EvaluationCard({
    super.key,
    required this.evaluation,
    required this.units,
  });

  final AIEvaluation? evaluation;
  final UnitPrefs units;

  static const Map<String, String> _targetNames = {
    'humidity': 'độ ẩm',
    'wind_speed': 'gió',
    'wind_gusts': 'gió giật',
    'precipitation_mm': 'lượng mưa',
  };

  /// MAE theo don vi dang chon (goc %, km/h, mm).
  static String _maeText(String target, double v, UnitPrefs u) {
    String dec(double x, int d) => x.toStringAsFixed(d).replaceAll('.', ',');
    switch (target) {
      case 'humidity':
        return '${dec(v, 1)} điểm %';
      case 'wind_speed':
      case 'wind_gusts':
        // Beaufort khong tuyen tinh -> sai so hien theo m/s.
        return '${dec(u.windAxisValue(v), 1)} ${u.windAxisUnit.label}';
      default:
        return u.precip == PrecipUnit.mm
            ? '${dec(v, 2)} mm'
            : '${dec(UnitConvert.mmToInch(v), 3)} in';
    }
  }

  /// Dong MAE cac muc tieu moi + do phu khoang nhiet do (neu co).
  List<Widget> _extraLines(BuildContext context, AIEvaluation e) {
    final theme = Theme.of(context);
    final body = TypeScale.bodyMedium.copyWith(
      color: theme.textTheme.bodyLarge?.color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final lines = <String>[];
    for (final t in AIEvaluation.extraTargets) {
      final m = e.targetMae[t];
      if (!e.isEnabled(t) || m == null || m.isEmpty) continue;
      final parts = [
        for (final h in m.entries) '${_maeText(t, h.value, units)} (${h.key})',
      ];
      lines.add('MAE ${_targetNames[t]}: ${parts.join(' · ')}');
    }
    final cov = e.intervalCoverage;
    if (e.isEnabled('temperature_interval') && cov.isNotEmpty) {
      final parts = [
        for (final h in cov.entries) '${(h.value * 100).round()}% (${h.key})',
      ];
      final nominal = e.intervalNominalCoverage;
      final goal = nominal == null
          ? ''
          : ' (mục tiêu ${(nominal * 100).round()}%)';
      final name = nominal == null ? 'dự báo' : '${(nominal * 100).round()}%';
      lines.add(
        'Khoảng nhiệt độ $name phủ ${parts.join(' · ')} trên tập kiểm '
        'tra$goal. Đây là mức bất định, không phải điểm độ chính xác.',
      );
    }
    return [
      for (final l in lines) ...[
        const SizedBox(height: Space.s),
        Text(l, style: body),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = evaluation;
    final warn = e != null && e.beatsBaselines == false;
    final ink = GlassThemeMarker.inkOf(context);
    final strong = TypeScale.bodyMedium.copyWith(
      color: warn && ink != null
          ? ink.warning
          : theme.textTheme.bodyLarge?.color,
      fontWeight: FontWeight.w600,
    );
    final horizons = [
      for (final h in AIForecast.horizons)
        if (e != null &&
            (e.temperatureMae.containsKey(h) || e.rainF1.containsKey(h)))
          h,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Đánh giá tại ô lưới này',
          style: TypeScale.heading3.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        const SizedBox(height: Space.s),
        Text(AIEvaluationLine.text(e, units), style: strong),
        if (horizons.isNotEmpty) ...[
          const SizedBox(height: Space.s),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              _row(context, const [
                'Mốc',
                'MAE nhiệt độ',
                'F1 mưa',
              ], header: true),
              for (final h in horizons)
                _row(context, [
                  h,
                  e!.temperatureMae[h] == null
                      ? '--'
                      : units.tempDeltaText(e.temperatureMae[h]!),
                  e.rainF1[h] == null
                      ? '--'
                      : e.rainF1[h]!.toStringAsFixed(2).replaceAll('.', ','),
                ]),
            ],
          ),
        ],
        if (e != null) ..._extraLines(context, e),
        const SizedBox(height: Space.s),
        Text(
          e == null
              ? 'Máy chủ chưa gửi kết quả đánh giá cho ô dữ liệu của địa '
                    'điểm này.'
              : [
                  'Một mô hình chung cho mọi ô dữ liệu, đánh giá riêng '
                      'trên dữ liệu kiểm tra của ô này'
                      '${e.cellId == null ? '' : ' (${e.cellId})'}.',
                  if (e.testPeriodText != null)
                    'Giai đoạn kiểm tra: ${e.testPeriodText}.',
                  'MAE là sai số tuyệt đối trung bình, không phải khoảng dự báo.',
                  'F1 mưa là chỉ số phân loại (0–1), không phải phần trăm chính xác.',
                ].join(' '),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  TableRow _row(
    BuildContext context,
    List<String> cells, {
    bool header = false,
  }) {
    final theme = Theme.of(context);
    return TableRow(
      children: [
        for (var i = 0; i < cells.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              cells[i],
              style: header || i == 0
                  ? theme.textTheme.bodySmall
                  : TypeScale.bodyMedium.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
            ),
          ),
      ],
    );
  }
}
