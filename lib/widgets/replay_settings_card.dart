import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/hcm_time.dart';
import '../providers/weather_provider.dart';
import '../screens/forecast/forecast_format.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';

/// The "Chế độ xem lại" trong Cai dat: cong tac, chon thoi diem (theo gio,
/// 03/01/2017 … hien tai) va nut mau "Đợt mưa lớn 07/10/2026".
class ReplaySettingsCard extends StatelessWidget {
  const ReplaySettingsCard({super.key});

  /// Chon ngay roi chon gio (gio TP.HCM). null neu nguoi dung huy.
  static Future<DateTime?> pickMoment(
    BuildContext context,
    WeatherProvider provider,
  ) async {
    final realNow = provider.realNowHcm;
    final initial = provider.replayAt ?? WeatherProvider.replayPreset;
    // showDatePicker dung DateTime "dia phuong": chi mang ngay/thang/nam.
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(
        WeatherProvider.replayMin.year,
        WeatherProvider.replayMin.month,
        WeatherProvider.replayMin.day,
      ),
      lastDate: DateTime(realNow.year, realNow.month, realNow.day),
      helpText: 'Chọn ngày xem lại',
      cancelText: 'Hủy',
      confirmText: 'Tiếp',
      // Hop thoai theo giao dien sang/toi cua app, khong theo theme kinh.
      builder: (_, child) => AppThemeScope.wrapDialog(context, child!),
    );
    if (date == null || !context.mounted) return null;
    final isToday =
        date.year == realNow.year &&
        date.month == realNow.month &&
        date.day == realNow.day;
    final maxHour = isToday ? realNow.hour : 23;
    final hour = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AppThemeScope.wrapDialog(
        context,
        SimpleDialog(
          title: Text('Chọn giờ · ${date.day}/${date.month}/${date.year}'),
          children: [
            SizedBox(
              width: 280,
              height: 320,
              child: GridView.count(
                crossAxisCount: 4,
                padding: const EdgeInsets.all(AppSizes.paddingS),
                childAspectRatio: 1.6,
                children: [
                  for (var h = 0; h <= maxHour; h++)
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, h),
                      child: Text('${h.toString().padLeft(2, '0')}:00'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (hour == null) return null;
    return DateTime.utc(date.year, date.month, date.day, hour);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<WeatherProvider>();
    final at = provider.replayAt;
    final caption = AppTextStyles.bodySmall.copyWith(
      color: theme.textTheme.bodySmall?.color,
    );

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            secondary: Icon(
              Icons.history_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Chế độ xem lại'),
            subtitle: Text(
              provider.isReplay && at != null
                  ? 'Đang xem lại: ${ForecastFormat.moment(at)}'
                  : 'Xem thời tiết như tại một thời điểm trong quá khứ',
              style: caption,
            ),
            value: provider.isReplay,
            onChanged: provider.setReplayEnabled,
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              Icons.event_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Thời điểm'),
            subtitle: Text(
              at == null ? 'Chưa chọn' : ForecastFormat.moment(at),
              style: caption,
            ),
            trailing: const Icon(Icons.edit_calendar_rounded),
            onTap: () async {
              final picked = await pickMoment(context, provider);
              if (picked != null) await provider.startReplay(picked);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSizes.paddingM,
              0,
              AppSizes.paddingM,
              AppSizes.paddingM,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      provider.startReplay(WeatherProvider.replayPreset),
                  icon: const Icon(Icons.thunderstorm_rounded),
                  label: Text(
                    'Đợt mưa lớn ${_dayMonthYear(WeatherProvider.replayPreset)}',
                  ),
                ),
                const SizedBox(height: AppSizes.paddingS),
                Text(
                  'Khi bật, mọi số liệu (hiện tại, theo giờ, 7 ngày, dự báo AI) '
                  'được lấy như thể đang ở thời điểm đã chọn; giờ đã qua được '
                  'ghi "Thực tế". Dữ liệu xem lại không được lưu vào bộ nhớ đệm. '
                  'Có dữ liệu từ 03/01/2017.',
                  style: caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _dayMonthYear(DateTime d) {
    final t = HcmTime.startOfDay(d);
    return '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}/${t.year}';
  }
}
