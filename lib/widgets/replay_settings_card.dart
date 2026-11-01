import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../utils/forecast_format.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/widgets/ios_sheet.dart';

/// The "Chế độ xem lại" trong Cai dat: cong tac, chon thoi diem (theo gio,
/// 03/01/2017 … hien tai) va nut moc mau co du bao AI da luu.
class ReplaySettingsCard extends StatelessWidget {
  const ReplaySettingsCard({super.key});

  /// Chon ngay roi chon gio (gio TP.HCM). null neu nguoi dung huy.
  static Future<DateTime?> pickMoment(
    BuildContext context,
    WeatherProvider provider,
  ) async {
    final realNow = provider.realNowHcm;
    final initial = provider.replayAt ?? WeatherProvider.replayPreset;
    // CupertinoDatePicker dung DateTime "dia phuong": chi mang cac truong
    // ngay/gio (gio TP.HCM), quy doi lai DateTime.utc nhu truoc.
    DateTime wall(DateTime d) => DateTime(d.year, d.month, d.day, d.hour);
    final min = wall(WeatherProvider.replayMin);
    final max = wall(realNow);
    var start = wall(initial);
    if (start.isBefore(min)) start = min;
    if (start.isAfter(max)) start = max;
    final picked = await showIosDateTimeSheet(
      context,
      title: 'Thời điểm xem lại',
      initial: start,
      minimum: min,
      maximum: max,
      mode: CupertinoDatePickerMode.dateAndTime,
      minuteInterval: 60,
    );
    if (picked == null) return null;
    return DateTime.utc(picked.year, picked.month, picked.day, picked.hour);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<WeatherProvider>();
    final at = provider.replayAt;
    final caption = TypeScale.bodySmall.copyWith(
      color: theme.textTheme.bodySmall?.color,
    );

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
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
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      provider.startReplay(WeatherProvider.replayPreset),
                  icon: const Icon(Icons.history_rounded),
                  label: Text(WeatherProvider.replayPresetLabel),
                ),
                const SizedBox(height: Space.s),
                Text(
                  'Khi bật, mọi số liệu (hiện tại, theo giờ, 7 ngày, dự báo AI) '
                  'được lấy như thể đang ở thời điểm đã chọn; giờ đã qua được '
                  'ghi "Đã ghi nhận". Dữ liệu xem lại không được lưu vào bộ nhớ đệm. '
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
}
