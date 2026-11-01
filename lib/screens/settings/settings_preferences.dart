/// Ca nhan hoa: don vi, chi so trang chu, tro nang.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/units.dart';
import '../../providers/preferences_provider.dart';
import '../../ui/weather/design_tokens.dart';
import 'settings_choice_group.dart';
import 'settings_common.dart';

/// "Đơn vị": nhiet do, gio, ap suat, luong mua, khoang cach.
class SettingsUnitsSection extends StatelessWidget {
  const SettingsUnitsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesProvider.maybeOf(context);
    final u = prefs?.units ?? const UnitPrefs();
    void set(UnitPrefs next) => prefs?.setUnits(next);
    return Card(
      child: Column(
        children: [
          SettingsChoiceGroup<bool>(
            icon: CupertinoIcons.thermometer,
            title: 'Nhiệt độ',
            options: const [(true, '°C'), (false, '°F')],
            selected: u.isCelsius,
            onSelected: (c) => prefs?.setTemperatureUnit(c),
          ),
          if (prefs != null) ...[
            const Divider(height: 1),
            SettingsChoiceGroup<WindUnit>(
              icon: CupertinoIcons.wind,
              title: 'Tốc độ gió',
              subtitle: 'Ví dụ 20 km/h = ${u.windText(20)}',
              options: [
                for (final w in WindUnit.values)
                  (w, w == WindUnit.beaufort ? 'Cấp Beaufort' : w.label),
              ],
              selected: u.wind,
              onSelected: (w) => set(u.copyWith(wind: w)),
            ),
            const Divider(height: 1),
            SettingsChoiceGroup<PressureUnit>(
              icon: CupertinoIcons.speedometer,
              title: 'Áp suất',
              subtitle: 'Ví dụ 1013 hPa = ${u.pressureText(1013)}',
              options: [for (final p in PressureUnit.values) (p, p.label)],
              selected: u.pressure,
              onSelected: (p) => set(u.copyWith(pressure: p)),
            ),
            const Divider(height: 1),
            SettingsChoiceGroup<PrecipUnit>(
              icon: CupertinoIcons.umbrella,
              title: 'Lượng mưa',
              options: [for (final p in PrecipUnit.values) (p, p.label)],
              selected: u.precip,
              onSelected: (p) => set(u.copyWith(precip: p)),
            ),
            const Divider(height: 1),
            SettingsChoiceGroup<DistanceUnit>(
              icon: CupertinoIcons.slider_horizontal_3,
              title: 'Khoảng cách',
              subtitle: 'Dùng cho tầm nhìn và chế độ di chuyển.',
              options: [for (final d in DistanceUnit.values) (d, d.label)],
              selected: u.distance,
              onSelected: (d) => set(u.copyWith(distance: d)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
              child: SettingsNote(
                'Ngưỡng cảnh báo vẫn tính theo đơn vị gốc (km/h, mm); '
                'chỉ phần hiển thị được đổi.',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Chỉ số trên trang chủ": bat/tat + keo tha, co nut len/xuong thay the.
class SettingsHomeMetricsSection extends StatelessWidget {
  const SettingsHomeMetricsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesProvider.maybeOf(context);
    if (prefs == null) return const SizedBox.shrink();
    final order = prefs.metricOrder;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(Space.l, Space.l, Space.l, Space.xs),
            child: SettingsNote(
              'Bật/tắt và sắp xếp thẻ chỉ số. Giữ và kéo biểu tượng bên '
              'trái, hoặc dùng nút lên/xuống.',
            ),
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: prefs.reorderMetric,
            proxyDecorator: (child, _, _) =>
                Material(color: Colors.transparent, child: child),
            children: [
              for (var i = 0; i < order.length; i++)
                _MetricRow(
                  key: ValueKey('pref-metric-${order[i].name}'),
                  metric: order[i],
                  index: i,
                  count: order.length,
                  visible: prefs.isVisible(order[i]),
                  prefs: prefs,
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.all(Space.s),
              child: TextButton.icon(
                onPressed: prefs.resetMetrics,
                icon: const Icon(CupertinoIcons.arrow_counterclockwise),
                label: const Text('Khôi phục mặc định'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    super.key,
    required this.metric,
    required this.index,
    required this.count,
    required this.visible,
    required this.prefs,
  });

  final HomeMetric metric;
  final int index;
  final int count;
  final bool visible;
  final PreferencesProvider prefs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = metric.label;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Kéo để sắp xếp $name',
              child: const SizedBox.square(
                dimension: 48,
                child: Icon(CupertinoIcons.line_horizontal_3, size: 20),
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              style: TypeScale.bodyMedium.copyWith(
                color: visible
                    ? theme.textTheme.bodyLarge?.color
                    : theme.textTheme.bodySmall?.color,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Đưa $name lên',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: index == 0 ? null : () => prefs.moveMetric(metric, -1),
            icon: const Icon(CupertinoIcons.chevron_up, size: 20),
          ),
          IconButton(
            tooltip: 'Đưa $name xuống',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: index == count - 1
                ? null
                : () => prefs.moveMetric(metric, 1),
            icon: const Icon(CupertinoIcons.chevron_down, size: 20),
          ),
          Semantics(
            label: 'Hiện $name trên trang chủ',
            child: SizedBox(
              width: 60,
              height: 48,
              child: CupertinoSwitch(
                value: visible,
                onChanged: (v) => prefs.setMetricVisible(metric, v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Trợ năng": co chu, tuong phan cao, giam chuyen dong.
class SettingsAccessibilitySection extends StatelessWidget {
  const SettingsAccessibilitySection({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesProvider.maybeOf(context);
    if (prefs == null) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    // MediaQuery da gop lua chon trong app; bat ma app tat -> do he thong.
    final systemMotion = mq.disableAnimations && !prefs.reduceMotion;
    final systemContrast = mq.highContrast && !prefs.highContrast;
    return Card(
      child: Column(
        children: [
          SettingsChoiceGroup<double>(
            icon: CupertinoIcons.textformat_size,
            title: 'Cỡ chữ',
            subtitle: 'Nhân thêm với cỡ chữ của hệ thống.',
            options: const [
              (0.9, 'Nhỏ'),
              (1.0, 'Mặc định'),
              (1.15, 'Lớn'),
              (1.3, 'Rất lớn'),
            ],
            selected: prefs.textScale,
            onSelected: prefs.setTextScale,
          ),
          const Divider(height: 1),
          SettingsSwitchTile(
            secondary: const SettingsIcon(CupertinoIcons.circle_lefthalf_fill),
            title: const Text('Tương phản cao'),
            subtitle: Text(
              systemContrast
                  ? 'Đang bật theo hệ thống'
                  : 'Thẻ kính đặc hơn, viền rõ hơn',
            ),
            value: prefs.highContrast || systemContrast,
            onChanged: systemContrast ? null : prefs.setHighContrast,
          ),
          const Divider(height: 1),
          SettingsSwitchTile(
            secondary: const SettingsIcon(CupertinoIcons.pause),
            title: const Text('Giảm chuyển động'),
            subtitle: Text(
              systemMotion
                  ? 'Đang bật theo hệ thống'
                  : 'Tắt hiệu ứng mưa, mây trôi và chuyển cảnh',
            ),
            value: prefs.reduceMotion || systemMotion,
            onChanged: systemMotion ? null : prefs.setReduceMotion,
          ),
        ],
      ),
    );
  }
}
