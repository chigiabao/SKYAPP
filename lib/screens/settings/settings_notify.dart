/// Thong bao, hoat dong (gio di / ve) va che do xem lai.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/planner_provider.dart';
import '../../providers/weather_provider.dart';
import '../../services/notification_service.dart';
import '../../ui/weather/design_tokens.dart';
import '../../widgets/replay_settings_card.dart';
import '../activities_screen.dart';
import '../alert_settings_screen.dart';
import '../../utils/forecast_format.dart';
import 'settings_common.dart';
import '../../ui/weather/widgets/ios_sheet.dart';
import '../../ui/weather/widgets/ios_toast.dart';
import '../../utils/haptics.dart';

// ---------------------------------------------------------------------------
// Thong bao va canh bao, hoat dong (gio di / ve)

String _hm(int h, int m) => ForecastFormat.clock(h, m);

/// Cai dat canh bao (man rieng) + thong bao buoi sang.
class SettingsNotifySection extends StatelessWidget {
  const SettingsNotifySection({super.key});

  Future<void> _toggleBrief(
    BuildContext context,
    PlannerProvider planner,
    bool on,
  ) async {
    final ok = await planner.setMorningBrief(on);
    if (!ok && context.mounted) {
      AppHaptics.warning();
      showIosToast(
        context,
        'Chưa được cấp quyền thông báo (hoặc thiết bị không hỗ trợ). '
        'Cảnh báo vẫn hiện trong ứng dụng.',
        tone: IosToastTone.error,
      );
    }
  }

  Future<void> _pickTime(BuildContext context, PlannerProvider planner) async {
    final c = planner.commute;
    final t = await showIosTimeSheet(
      context,
      initial: TimeOfDay(hour: c.briefHour, minute: c.briefMinute),
      title: 'Giờ gửi bản tin sáng',
    );
    if (t == null) return;
    planner.setCommute(c.copyWith(briefHour: t.hour, briefMinute: t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final theme = Theme.of(context);
    final small = TypeScale.bodySmall.copyWith(
      color: theme.textTheme.bodySmall?.color,
    );
    final alertTile = ListTile(
      leading: const SettingsIcon(CupertinoIcons.exclamationmark_triangle),
      title: const Text('Cảnh báo, ngưỡng và giờ yên lặng'),
      subtitle: const Text('Mưa, dông sét, nắng nóng, gió, UV, không khí'),
      trailing: const Icon(
        CupertinoIcons.chevron_right,
        size: 16,
        color: Palette.secondary,
      ),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AlertSettingsScreen())),
    );
    if (planner == null) return Card(child: alertTile);
    final c = planner.commute;
    final on = planner.notifySettings.system && c.briefEnabled;
    final supported = NotificationService.isSupportedPlatform;
    final time = _hm(c.briefHour, c.briefMinute);
    final quiet = planner.settings;
    final inQuiet = quiet.inQuietHours(
      DateTime(2000, 1, 1, c.briefHour, c.briefMinute),
    );
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          alertTile,
          const Divider(height: 1),
          // Web / may tinh: khong co thong bao -> ghi chu (doc ro), khong
          // hien cong tac bi lam mo.
          if (!supported)
            const ListTile(
              leading: SettingsIcon(CupertinoIcons.sunrise),
              title: Text('Thông báo buổi sáng'),
              subtitle: Text(
                'Chỉ có trên ứng dụng Android, iPhone. Trên trình duyệt, '
                'xem tóm tắt ở thẻ Gợi ý hoạt động.',
              ),
            )
          else
            SettingsSwitchTile(
              secondary: const SettingsIcon(CupertinoIcons.sunrise),
              title: const Text('Thông báo buổi sáng'),
              subtitle: Text(
                'Lúc $time: tóm tắt mưa trong ngày ở Nhà và Nơi làm',
              ),
              value: on,
              onChanged: (v) => _toggleBrief(context, planner, v),
            ),
          if (on) ...[
            ListTile(
              leading: const SettingsIcon(CupertinoIcons.clock),
              title: const Text('Giờ gửi'),
              subtitle: Text(time),
              trailing: const Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: Palette.secondary,
              ),
              onTap: () => _pickTime(context, planner),
            ),
            SettingsSwitchTile(
              secondary: const SettingsIcon(CupertinoIcons.moon),
              title: const Text('Gửi cả trong giờ yên lặng'),
              subtitle: Text(
                quiet.quietEnabled
                    ? 'Giờ yên lặng ${_hm(quiet.quietStart, 0)}–${_hm(quiet.quietEnd, 0)}'
                          '${inQuiet ? ' (giờ gửi nằm trong khoảng này)' : ''}'
                    : 'Giờ yên lặng đang tắt',
              ),
              value: c.briefInQuiet,
              onChanged: (v) => planner.setCommute(c.copyWith(briefInQuiet: v)),
            ),
            if (planner.morningBriefAt == null && !c.briefInQuiet && inQuiet)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.l,
                  0,
                  Space.l,
                  Space.l,
                ),
                child: Text(
                  'Sẽ không gửi: giờ gửi nằm trong giờ yên lặng.',
                  style: small,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Man Hoat dong + gio di / ve.
class SettingsActivitySection extends StatelessWidget {
  const SettingsActivitySection({super.key});

  Future<void> _pick(
    BuildContext context,
    PlannerProvider planner,
    bool leave,
  ) async {
    final c = planner.commute;
    final t = await showIosTimeSheet(
      context,
      initial: leave
          ? TimeOfDay(hour: c.leaveHour, minute: c.leaveMinute)
          : TimeOfDay(hour: c.returnHour, minute: c.returnMinute),
      title: leave ? 'Giờ đi làm / đi học' : 'Giờ về',
    );
    if (t == null) return;
    planner.setCommute(
      leave
          ? c.copyWith(leaveHour: t.hour, leaveMinute: t.minute)
          : c.copyWith(returnHour: t.hour, returnMinute: t.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final open = ListTile(
      leading: const SettingsIcon(CupertinoIcons.sportscourt),
      title: const Text('Hoạt động yêu thích và lịch'),
      subtitle: const Text('Gợi ý giờ đẹp trời, nhắc trước giờ hoạt động'),
      trailing: const Icon(
        CupertinoIcons.chevron_right,
        size: 16,
        color: Palette.secondary,
      ),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ActivitiesScreen())),
    );
    if (planner == null) return Card(child: open);
    final c = planner.commute;
    return Card(
      child: Column(
        children: [
          open,
          const Divider(height: 1),
          ListTile(
            leading: const SettingsIcon(CupertinoIcons.car),
            title: const Text('Giờ đi làm / đi học'),
            subtitle: Text(_hm(c.leaveHour, c.leaveMinute)),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
            onTap: () => _pick(context, planner, true),
          ),
          ListTile(
            leading: const SettingsIcon(CupertinoIcons.home),
            title: const Text('Giờ về'),
            subtitle: Text(_hm(c.returnHour, c.returnMinute)),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
            onTap: () => _pick(context, planner, false),
          ),
        ],
      ),
    );
  }
}

class SettingsReplaySection extends StatelessWidget {
  const SettingsReplaySection({super.key});

  @override
  Widget build(BuildContext context) {
    final (isReplay, at) = context.select<WeatherProvider, (bool, DateTime?)>(
      (p) => (p.isReplay, p.replayAt),
    );
    final provider = context.read<WeatherProvider>();
    final preset = WeatherProvider.replayPreset;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchTile(
            secondary: const SettingsIcon(CupertinoIcons.clock),
            title: const Text('Chế độ xem lại'),
            subtitle: Text(
              isReplay && at != null
                  ? 'Đang xem lại: ${ForecastFormat.moment(at)}'
                  : 'Xem thời tiết như tại một thời điểm trong quá khứ',
            ),
            value: isReplay,
            onChanged: provider.setReplayEnabled,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const SettingsIcon(CupertinoIcons.calendar),
            title: const Text('Thời điểm'),
            subtitle: Text(
              at == null ? 'Chưa chọn' : ForecastFormat.moment(at),
            ),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
            onTap: () async {
              final picked = await ReplaySettingsCard.pickMoment(
                context,
                provider,
              );
              if (picked != null) await provider.startReplay(picked);
            },
          ),
          Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsAction(
                  onPressed: () => provider.startReplay(preset),
                  icon: CupertinoIcons.clock,
                  label: WeatherProvider.replayPresetLabel,
                ),
                const SizedBox(height: Space.s),
                const SettingsNote(
                  'Khi bật, mọi số liệu (hiện tại, theo giờ, 7 ngày, dự báo AI) '
                  'được lấy như thể đang ở thời điểm đã chọn; giờ đã qua được '
                  'ghi \u0022Đã ghi nhận\u0022. Dữ liệu xem lại không được lưu vào bộ nhớ đệm. '
                  'Có dữ liệu từ 03/01/2017.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
