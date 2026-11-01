import 'package:flutter/material.dart';

import '../../models/units.dart';
import '../../models/weather.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_page.dart';
import '../../utils/forecast_format.dart';

class HorizonCard extends StatelessWidget {
  const HorizonCard({
    super.key,
    required this.item,
    required this.nowHcm,
    required this.units,
  });

  final AIVerificationItem item;
  final DateTime nowHcm;
  final UnitPrefs units;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = item.targetTime;
    final notYet = target != null && target.isAfter(nowHcm);
    final targetText = target == null
        ? ''
        : ' · ${ForecastFormat.hourMinute(target)} ${ForecastFormat.title(target)}';

    final String status;
    final Color statusColor;
    if (item.hasActual) {
      status = 'Đã có thực tế';
      statusColor = GlassThemeMarker.isGlass(context)
          ? Palette.white
          : theme.brightness == Brightness.dark
          ? Tones.successOnDark
          : Tones.successOnLight;
    } else if (notYet) {
      status = 'Chưa tới giờ';
      statusColor = theme.textTheme.bodySmall?.color ?? _mutedFallback(theme);
    } else {
      status = 'Chưa có số liệu';
      statusColor = theme.textTheme.bodySmall?.color ?? _mutedFallback(theme);
    }

    final predTemp = item.predictedTemperature;
    final actTemp = item.actualTemperature;
    final err = item.temperatureError;
    final predRain = item.predictedRainPercent;
    final String actualRain;
    if (item.actualRain == null) {
      actualRain = '--';
    } else {
      final mm = item.actualPrecipitation == null
          ? ''
          : ' (${units.rainText(item.actualPrecipitation)})';
      actualRain = '${item.actualRain! ? 'Có mưa' : 'Không mưa'}$mm';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Sau ${item.horizon}$targetText',
                    style: TypeScale.heading3.copyWith(
                      color: theme.textTheme.titleLarge?.color,
                    ),
                  ),
                ),
                const SizedBox(width: Space.s),
                Text(
                  status,
                  style: TypeScale.caption.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.1),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1.2),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _row(context, const [
                  '',
                  'Dự báo',
                  'Đã ghi nhận',
                ], header: true),
                _row(context, [
                  'Nhiệt độ',
                  predTemp == null ? '--' : units.tempText(predTemp),
                  actTemp == null ? '--' : units.tempText(actTemp),
                ]),
                _row(context, [
                  'Mưa',
                  predRain == null ? '--' : '$predRain% khả năng',
                  actualRain,
                ]),
              ],
            ),
            const SizedBox(height: Space.s),
            if (err != null)
              Text(
                'Sai số nhiệt độ: ${units.tempDeltaText(err)}',
                style: TypeScale.bodyMedium.copyWith(
                  color: theme.textTheme.bodyLarge?.color,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (!item.hasActual)
              Text(
                notYet
                    ? 'Mốc ${ForecastFormat.hourMinute(target)} chưa tới — '
                          'chưa có số liệu thực tế để so sánh.'
                    : 'Chưa có số liệu thực tế cho mốc này.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
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
            padding: const EdgeInsets.only(top: 4, bottom: 4, right: 8),
            child: Text(
              cells[i],
              style: header || i == 0
                  ? theme.textTheme.bodySmall
                  : TypeScale.bodyMedium.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w600,
                    ),
            ),
          ),
      ],
    );
  }
}

class NotesCard extends StatelessWidget {
  const NotesCard({super.key, required this.showReplayTip});

  final bool showReplayTip;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final notes = [
      '"Đã ghi nhận" là ${DataCopy.observedExplain}; phản hồi người dùng '
          'không được dùng làm số liệu đã ghi nhận.',
      '"Có mưa / Không mưa" do máy chủ đánh giá từ lượng mưa thực tế '
          'trong giờ đó.',
      'Vài mốc kiểm chứng không đủ để đánh giá độ chính xác của mô hình.',
      if (showReplayTip)
        'Dự báo quá khứ chỉ kiểm chứng được khi đã lưu; không tự tính lại '
            'bằng mô hình hiện tại.',
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: Text('• $n', style: style),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mau chu phu du phong theo giao dien (khi theme khong dat bodySmall).
Color _mutedFallback(ThemeData theme) => theme.brightness == Brightness.dark
    ? SystemColors.secondaryLabelDark
    : SystemColors.secondaryLabelLight;
