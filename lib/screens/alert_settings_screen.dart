import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminders.dart';
import '../models/units.dart';
import '../models/weather_alerts.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/gps_service.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import '../widgets/planner_cards.dart';

/// Pham vi + buoc cua thanh truot nguong tung loai.
class _Range {
  const _Range(this.min, this.max, this.step);
  final double min;
  final double max;
  final double step;
  int get divisions => ((max - min) / step).round();
}

const Map<AlertType, _Range> _ranges = {
  AlertType.rain: _Range(40, 100, 5),
  AlertType.heavyRain: _Range(5, 50, 5),
  AlertType.heat: _Range(32, 40, 1),
  AlertType.uv: _Range(3, 11, 1),
  AlertType.wind: _Range(30, 90, 5),
  AlertType.aqi: _Range(51, 201, 50),
};

/// Muc AQI (US) theo nguong.
String _aqiWord(double v) => v >= 201
    ? 'rất có hại'
    : v >= 151
    ? 'có hại cho sức khỏe'
    : v >= 101
    ? 'kém với người nhạy cảm'
    : 'trung bình';

/// Muc UV theo nguong.
String _uvWord(double v) => v >= 11
    ? 'cực cao'
    : v >= 8
    ? 'rất cao'
    : v >= 6
    ? 'cao'
    : 'trung bình';

/// Nguong luu theo don vi goc (°C, km/h, mm/h); chi phan hien thi doi theo
/// [u] / [temp].
String _fmt(
  AlertType t,
  double v,
  UnitPrefs u,
  String Function(double c) temp,
) => switch (t) {
  AlertType.rain => '${v.round()}%',
  AlertType.heavyRain => u.rainRateText(v),
  AlertType.heat => temp(v),
  AlertType.wind => u.windText(v),
  AlertType.uv => '${v.round()}',
  AlertType.aqi => '${v.round()}',
  AlertType.thunderstorm => '',
};

/// Mo ta bang loi nguoi dung, kem nguong hien hanh.
String _hint(
  AlertType t,
  AlertSettings s,
  UnitPrefs u,
  String Function(double c) temp,
) {
  final v = s.thresholdOf(t);
  String f(double x) => _fmt(t, x, u, temp);
  return switch (t) {
    AlertType.rain => 'Báo khi khả năng mưa từ ${f(v!)}',
    AlertType.heavyRain => 'Báo khi mưa từ ${f(v!)} – dễ ngập đường',
    AlertType.thunderstorm =>
      'Báo khi có dông, sét; mức Nguy hiểm nếu kèm mưa đá',
    AlertType.heat =>
      'Báo khi nhiệt độ từ ${f(v!)}, hoặc cảm giác từ ${temp(s.heatIndex)}',
    AlertType.uv => 'Báo khi chỉ số UV từ ${f(v!)} (${_uvWord(v)})',
    AlertType.wind => 'Báo khi gió giật từ ${f(v!)}',
    AlertType.aqi => 'Báo khi AQI từ ${f(v!)} (${_aqiWord(v)})',
  };
}

String _celsius(double c) => '${c.round()}°C';

/// Cai dat canh bao: bat/tat va nguong tung loai, muc uu tien thong bao,
/// gio yen lang, so gio xet toi.
class AlertSettingsScreen extends StatelessWidget {
  const AlertSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  /// Nhiet do theo don vi nguoi dung chon (°C / °F); khong co provider -> °C.
  static String Function(double) _tempOf(BuildContext context) {
    try {
      return context.read<WeatherProvider>().formatTemperature;
    } on ProviderNotFoundException {
      return _celsius;
    }
  }

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final s = planner.settings;
    final units = PreferencesProvider.unitsOf(context);
    final temp = _tempOf(context);
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;

    Widget typeTile(AlertType t) {
      final on = s.isEnabled(t);
      final value = s.thresholdOf(t);
      final r = _ranges[t];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(alertIcon(t), color: Palette.white),
            title: Text(
              t.label,
              style: TypeScale.body.copyWith(
                color: Palette.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              _hint(t, s, units, temp),
              style: TypeScale.small.copyWith(color: ink.secondary),
            ),
            value: on,
            onChanged: (v) => planner.setSettings(s.withEnabled(t, v)),
          ),
          if (on && value != null && r != null)
            Slider(
              value: value.clamp(r.min, r.max).toDouble(),
              min: r.min,
              max: r.max,
              divisions: r.divisions,
              label: _fmt(t, value, units, temp),
              semanticFormatterCallback: (v) =>
                  'Ngưỡng ${_fmt(t, v, units, temp)}',
              onChanged: (v) => planner.setSettings(s.withThreshold(t, v)),
            ),
        ],
      );
    }

    String hour(int h) => '${h.toString().padLeft(2, '0')}:00';

    Future<void> pickHour(bool start) async {
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: start ? s.quietStart : s.quietEnd,
          minute: 0,
        ),
        helpText: start ? 'Bắt đầu giờ yên lặng' : 'Kết thúc giờ yên lặng',
      );
      if (t == null) return;
      planner.setSettings(
        start ? s.copyWith(quietStart: t.hour) : s.copyWith(quietEnd: t.hour),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Cài đặt cảnh báo',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => planner.setSettings(const AlertSettings()),
            style: TextButton.styleFrom(
              foregroundColor: Palette.white,
              minimumSize: const Size(Touch.min, Touch.min),
            ),
            child: const Text('Mặc định'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
        children: [
          GlassCard(
            title: 'LOẠI CẢNH BÁO VÀ NGƯỠNG',
            icon: Icons.tune_rounded,
            footer: kAlertDisclaimer,
            // Material rieng: ListTile ve hieu ung cham len day.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final t in AlertType.values) typeTile(t)],
              ),
            ),
          ),
          const SizedBox(height: Space.cardGap),
          GlassCard(
            title: 'THÔNG BÁO',
            icon: Icons.notifications_none_rounded,
            footer:
                'Thông báo luôn hiện trong ứng dụng (lịch sử ở màn Cảnh báo). '
                'Mức Nguy hiểm vẫn báo trong giờ yên lặng.',
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Mức ưu tiên tối thiểu',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                  const SizedBox(height: Space.s),
                  SegmentedButton<AlertLevel>(
                    segments: [
                      for (final l in AlertLevel.values)
                        ButtonSegment(value: l, label: Text(l.label)),
                    ],
                    selected: {s.minNotifyLevel},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => planner.setSettings(
                      s.copyWith(minNotifyLevel: v.first),
                    ),
                  ),
                  const SizedBox(height: Space.m),
                  Text(
                    'Xét ${s.lookaheadHours} giờ tới',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                  Slider(
                    value: s.lookaheadHours.toDouble(),
                    min: 6,
                    max: 48,
                    divisions: 7,
                    label: '${s.lookaheadHours} giờ',
                    semanticFormatterCallback: (v) => '${v.round()} giờ tới',
                    onChanged: (v) => planner.setSettings(
                      s.copyWith(lookaheadHours: v.round()),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(
                      Icons.bedtime_outlined,
                      color: Palette.white,
                    ),
                    title: Text(
                      'Giờ yên lặng',
                      style: TypeScale.body.copyWith(color: Palette.white),
                    ),
                    subtitle: Text(
                      '${hour(s.quietStart)}–${hour(s.quietEnd)}',
                      style: TypeScale.small.copyWith(color: ink.secondary),
                    ),
                    value: s.quietEnabled,
                    onChanged: (v) =>
                        planner.setSettings(s.copyWith(quietEnabled: v)),
                  ),
                  if (s.quietEnabled)
                    Wrap(
                      spacing: Space.s,
                      children: [
                        OutlinedButton(
                          onPressed: () => pickHour(true),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Palette.white,
                            minimumSize: const Size(Touch.min, Touch.min),
                          ),
                          child: Text('Từ ${hour(s.quietStart)}'),
                        ),
                        OutlinedButton(
                          onPressed: () => pickHour(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Palette.white,
                            minimumSize: const Size(Touch.min, Touch.min),
                          ),
                          child: Text('Đến ${hour(s.quietEnd)}'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.cardGap),
          _SystemNotifyCard(planner: planner),
        ],
      ),
    );
  }
}

String _minutesLabel(int m) => m % 60 == 0 ? '${m ~/ 60} giờ' : '$m phút';

/// Thong bao he thong (Android) + nhac truoc gio hoat dong. Quyen chi duoc
/// xin khi nguoi dung bat cong tac.
class _SystemNotifyCard extends StatelessWidget {
  const _SystemNotifyCard({required this.planner});

  final PlannerProvider planner;

  Future<void> _toggle(BuildContext context, bool on) async {
    final ok = await planner.setSystemNotifications(on);
    if (!ok && context.mounted) {
      // Android / iOS: mo trang cai dat cua app (geolocator.openAppSettings,
      // iOS: UIApplication.openSettingsURLString) de bat lai thong bao; noi
      // khac chi huong dan.
      final mobile =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Chưa được cấp quyền thông báo (hoặc thiết bị không hỗ trợ). '
            'Cảnh báo vẫn hiện trong ứng dụng.'
            '${mobile ? '' : ' Bật thông báo cho Sky Weather trong Cài đặt '
                      'của thiết bị.'}',
          ),
          action: mobile
              ? SnackBarAction(
                  label: 'Mở cài đặt',
                  onPressed: () async {
                    final opened = await const GeolocatorGps()
                        .openAppSettings();
                    if (!opened) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Vào Cài đặt > Sky Weather > Thông báo để bật lại.',
                          ),
                        ),
                      );
                    }
                  },
                )
              : null,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final n = planner.notifySettings;
    final plan = planner.reminderPlan;
    final routines = planner.routines.length;
    final status = !n.system || !n.reminders
        ? null
        : routines == 0
        ? 'Chưa có lịch hoạt động để nhắc (thêm ở màn Hoạt động).'
        : 'Đã hẹn ${plan.reminders.length} lần nhắc trong 48 giờ tới'
              '${plan.skippedQuiet > 0 ? ' · bỏ ${plan.skippedQuiet} lần trong giờ yên lặng' : ''}.';
    final quietLabel = planner.settings.quietEnabled
        ? 'Giờ yên lặng ${planner.settings.quietStart}h–'
              '${planner.settings.quietEnd}h. Tắt: lời nhắc bạn tự đặt vẫn '
              'được gửi.'
        : 'Giờ yên lặng đang tắt.';
    return GlassCard(
      title: 'THÔNG BÁO HỆ THỐNG',
      icon: Icons.notifications_active_outlined,
      footer:
          'Android: kiểm tra nền khoảng mỗi giờ (hệ điều hành có thể giãn '
          'ra), cảnh báo tự động tôn trọng giờ yên lặng và chống trùng. '
          'Không gửi ở chế độ xem lại.',
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(
                Icons.phone_android_rounded,
                color: Palette.white,
              ),
              title: Text(
                'Thông báo trên điện thoại',
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
              subtitle: Text(
                'Xin quyền thông báo khi bật',
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
              value: n.system,
              onChanged: (v) => _toggle(context, v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.alarm_rounded, color: Palette.white),
              title: Text(
                'Nhắc trước giờ hoạt động',
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
              subtitle: Text(
                'Kèm điểm thời tiết; gợi ý giờ khác khi xấu',
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
              value: n.reminders,
              onChanged: n.system ? planner.setReminders : null,
            ),
            if (n.system && n.reminders) ...[
              const SizedBox(height: Space.s),
              Text(
                'Nhắc trước',
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
              const SizedBox(height: Space.s),
              SegmentedButton<int>(
                segments: [
                  for (final m in NotifySettings.minuteOptions)
                    ButtonSegment(value: m, label: Text(_minutesLabel(m))),
                ],
                selected: {n.minutesBefore},
                showSelectedIcon: false,
                onSelectionChanged: (v) => planner.setReminderMinutes(v.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(
                  Icons.bedtime_outlined,
                  color: Palette.white,
                ),
                title: Text(
                  'Tôn trọng giờ yên lặng cho lời nhắc',
                  style: TypeScale.body.copyWith(color: Palette.white),
                ),
                subtitle: Text(
                  quietLabel,
                  style: TypeScale.small.copyWith(color: ink.secondary),
                ),
                value: n.reminderQuiet,
                onChanged: planner.setReminderQuiet,
              ),
            ],
            if (status != null) ...[
              const SizedBox(height: Space.s),
              Text(
                status,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
