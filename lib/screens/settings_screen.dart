import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../config/api_config.dart';
import '../models/units.dart';
import '../models/weather_alerts.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/app_version.dart';
import '../services/notification_service.dart';
import 'account_screen.dart';
import 'activities_screen.dart';
import 'alert_settings_screen.dart';
import 'feedback_screen.dart';
import 'onboarding_screen.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/debug/weather_simulator_screen.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../utils/constants.dart';
import '../widgets/replay_settings_card.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  /// Noi dung (context nam duoi theme kinh cua GlassPage).
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    // Mau chu canh bao du tuong phan (>= 4.5:1) tren nen cam nhat
    final warningText = theme.brightness == Brightness.dark
        ? Colors.orange.shade200
        : Colors.deepOrange.shade900;

    final sceneOverride = maybeSceneOverride(context, listen: false);
    // Man rong (web / may tinh bang): cot noi dung toi da 640, can giua.
    final width = MediaQuery.sizeOf(context).width;
    final hPad = width > Space.contentMaxWidth + 2 * AppSizes.paddingM
        ? (width - Space.contentMaxWidth) / 2
        : AppSizes.paddingM;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Cài đặt',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: hPad,
          vertical: AppSizes.paddingM,
        ),
        children: [
          // Thu tu theo muc dung: thong bao / canh bao truoc, nang cao sau.
          _SectionHeader(
            title: 'Thông báo và cảnh báo',
            icon: Icons.notifications_none_rounded,
          ),
          const _NotifySection(),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(title: 'Địa điểm', icon: Icons.place_outlined),
          const _PlacesSection(),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(
            title: 'Hoạt động',
            icon: Icons.event_available_outlined,
          ),
          const _ActivitySection(),
          const SizedBox(height: AppSizes.paddingL),

          // Tai khoan tuy chon (nhom 9)
          _SectionHeader(title: 'Tài khoản', icon: Icons.person_outline),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('Tài khoản và đồng bộ'),
              subtitle: const Text('Tuỳ chọn, không cần để dùng app'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
            ),
          ),
          const SizedBox(height: AppSizes.paddingL),

          // Gop y (nhom 10) + xem lai huong dan
          _SectionHeader(
            title: 'Góp ý và trợ giúp',
            icon: Icons.help_outline_rounded,
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.feedback_outlined),
                  title: const Text('Góp ý và báo lỗi'),
                  subtitle: const Text('Báo lỗi, góp ý, báo dự báo sai'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FeedbackScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.school_outlined),
                  title: const Text('Xem lại hướng dẫn'),
                  subtitle: const Text('Nhà, nơi làm, giờ đi về, thông báo'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (c) => OnboardingScreen(
                        onDone: () => Navigator.of(c).pop(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(title: 'Giao diện', icon: Icons.palette_outlined),
          const _AppearanceSection(),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(
            title: 'Chỉ số trên trang chủ',
            icon: Icons.dashboard_customize_outlined,
          ),
          const _HomeMetricsSection(),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(
            title: 'Trợ năng',
            icon: Icons.accessibility_new_rounded,
          ),
          const _AccessibilitySection(),
          const SizedBox(height: AppSizes.paddingL),

          _SectionHeader(title: 'Đơn vị', icon: Icons.straighten_rounded),
          const _UnitsSection(),
          const SizedBox(height: AppSizes.paddingL),

          // Replay / demo section
          _SectionHeader(title: 'Xem lại', icon: Icons.history_rounded),
          const ReplaySettingsCard(),
          const SizedBox(height: AppSizes.paddingL),

          // About section
          _SectionHeader(title: 'Thông tin', icon: Icons.info_outline_rounded),
          Card(
            child: Column(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: 'Phiên bản',
                  subtitle: AppVersion.current,
                ),
                const Divider(height: 1),
                _SettingsTile(
                  icon: Icons.person_outline_rounded,
                  title: 'Phát triển',
                  subtitle: 'Đồ án sinh viên',
                ),
                const Divider(height: 1),
                _SettingsTile(
                  icon: Icons.code_rounded,
                  title: 'Công nghệ',
                  subtitle: 'Flutter · FastAPI · LightGBM',
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSizes.paddingL),

          // Data source info
          _SectionHeader(title: 'Nguồn dữ liệu', icon: Icons.cloud_outlined),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSizes.paddingM),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        color: Theme.of(context).colorScheme.primary,
                        size: AppSizes.iconSizeM,
                      ),
                      const SizedBox(width: AppSizes.paddingS),
                      Expanded(
                        child: Text(
                          'Nguồn dữ liệu',
                          style: AppTextStyles.heading3.copyWith(
                            color: theme.textTheme.titleLarge?.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSizes.paddingS),
                  Text(
                    'Dữ liệu: 10 năm dữ liệu theo giờ của Open-Meteo (2017–2026) '
                    'tại TP.HCM, phục vụ qua backend FastAPI của nhóm. '
                    'Số liệu theo giờ/ngày có thể là dự báo mô hình (Open-Meteo), '
                    'thực tế (dữ liệu phân tích của mô hình, không phải trạm đo) '
                    'hoặc trung bình nhiều năm — nguồn được ghi rõ trên từng mục. '
                    'Dự báo AI (LightGBM) là thử nghiệm, chỉ mang tính tham khảo.',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),
                  Container(
                    padding: const EdgeInsets.all(AppSizes.paddingS),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(
                        AppSizes.borderRadiusS,
                      ),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: warningText,
                          size: AppSizes.iconSizeS,
                        ),
                        const SizedBox(width: AppSizes.paddingS),
                        Expanded(
                          child: Text(
                            'Không dùng cho mục đích an toàn. Cảnh báo thời tiết '
                            'chính thức xem tại Đài KTTV khu vực Nam Bộ.',
                            style: AppTextStyles.bodySmall.copyWith(
                              color: warningText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppSizes.paddingL),
          _SectionHeader(title: 'Nâng cao', icon: Icons.dns_outlined),
          const _ServerSection(),

          // Cong cu debug: gia lap canh thoi tiet cho toan app.
          if (WeatherSimulatorScreen.available && sceneOverride != null) ...[
            const SizedBox(height: AppSizes.paddingL),
            _SectionHeader(title: 'Gỡ lỗi'),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.science_outlined,
                  color: AppColors.accentLight,
                  size: AppSizes.iconSizeM,
                ),
                title: const Text('Giả lập thời tiết'),
                subtitle: Text(
                  'Xem trước và áp dụng cảnh nền (chỉ bản debug)',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WeatherSimulatorScreen(
                      sceneOverride: sceneOverride,
                      initialScene: AppScene.of(context).scene,
                    ),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: AppSizes.paddingXL),

          // Footer
          Center(
            child: Text(
              'Sky Weather · TP. Hồ Chí Minh',
              style: AppTextStyles.caption.copyWith(
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ),

          const SizedBox(height: AppSizes.paddingL),
        ],
      ),
    );
  }
}

IconData _themeIcon(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return Icons.light_mode_rounded;
    case ThemeMode.dark:
      return Icons.dark_mode_rounded;
    case ThemeMode.system:
      return Icons.brightness_auto_rounded;
  }
}

/// Tieu de nhom: chu ro, icon, cao toi thieu 48 dp, la "header" cho trinh
/// doc man hinh (vuot nhanh giua cac nhom).
class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;

  const _SectionHeader({required this.title, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.textTheme.titleMedium?.color;
    return Semantics(
      header: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSizes.paddingS,
            bottom: AppSizes.paddingXS,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                ExcludeSemantics(
                  child: Icon(icon, size: IconSizes.sm, color: color),
                ),
                const SizedBox(width: AppSizes.paddingS),
              ],
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: AppTextStyles.caption.copyWith(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ListTile tu doc title + subtitle; khong boc them Semantics(label) de
    // tranh doc trung (truoc day nhan bi doc hai lan cung control).
    return ListTile(
      leading: Icon(
        icon,
        color: Theme.of(context).colorScheme.primary,
        size: AppSizes.iconSizeM,
      ),
      title: Text(
        title,
        style: AppTextStyles.bodyLarge.copyWith(
          color: theme.textTheme.bodyLarge?.color,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: AppTextStyles.bodySmall.copyWith(
          color: theme.textTheme.bodySmall?.color,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSizes.paddingM,
        vertical: AppSizes.paddingXS,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nhom 8 - Ca nhan hoa: giao dien, don vi, chi so trang chu, dia diem, tro nang
// ---------------------------------------------------------------------------

/// Mau chu dam tren nen chip da chon (trang).
const Color _onSelected = Color(0xFF0B1F33);

/// Nhom lua chon dang chip (tu xuong dong khi co chu lon, khong tran).
class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.icon,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSizes.paddingM,
        AppSizes.paddingM,
        AppSizes.paddingM,
        AppSizes.paddingS,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  icon,
                  color: theme.colorScheme.primary,
                  size: AppSizes.iconSizeM,
                ),
              ),
              const SizedBox(width: AppSizes.paddingM),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSizes.paddingXS),
              child: Text(
                subtitle!,
                style: AppTextStyles.bodySmall.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ),
          const SizedBox(height: AppSizes.paddingS),
          Wrap(
            spacing: AppSizes.paddingS,
            runSpacing: AppSizes.paddingXS,
            children: [
              for (final (value, label) in options)
                Semantics(
                  label: '$title: $label',
                  excludeSemantics: true,
                  selected: value == selected,
                  button: true,
                  inMutuallyExclusiveGroup: true,
                  onTap: () => onSelected(value),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: value == selected,
                    onSelected: (_) => onSelected(value),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    selectedColor: Colors.white,
                    backgroundColor: Colors.transparent,
                    checkmarkColor: _onSelected,
                    side: const BorderSide(color: Color(0x99FFFFFF)),
                    labelStyle: AppTextStyles.bodyMedium.copyWith(
                      color: value == selected ? _onSelected : Colors.white,
                      fontWeight: value == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Giao diện": Sang / Toi / Theo he thong.
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final wp = context.watch<WeatherProvider>();
    return Card(
      child: _ChoiceGroup<ThemeMode>(
        icon: _themeIcon(wp.themeMode),
        title: 'Chế độ giao diện',
        options: const [
          (ThemeMode.light, 'Sáng'),
          (ThemeMode.dark, 'Tối'),
          (ThemeMode.system, 'Theo hệ thống'),
        ],
        selected: wp.themeMode,
        onSelected: wp.setThemeMode,
      ),
    );
  }
}

/// "Đơn vị": nhiet do, gio, ap suat, luong mua, khoang cach.
class _UnitsSection extends StatelessWidget {
  const _UnitsSection();

  @override
  Widget build(BuildContext context) {
    final wp = context.watch<WeatherProvider>();
    final prefs = PreferencesProvider.maybeOf(context);
    final u = prefs?.units ?? const UnitPrefs();
    void set(UnitPrefs next) => prefs?.setUnits(next);
    return Card(
      child: Column(
        children: [
          _ChoiceGroup<bool>(
            icon: Icons.thermostat_rounded,
            title: 'Nhiệt độ',
            options: const [(true, '°C'), (false, '°F')],
            selected: wp.isCelsius,
            onSelected: wp.setTemperatureUnit,
          ),
          if (prefs != null) ...[
            const Divider(height: 1),
            _ChoiceGroup<WindUnit>(
              icon: Icons.air_rounded,
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
            _ChoiceGroup<PressureUnit>(
              icon: Icons.speed_rounded,
              title: 'Áp suất',
              subtitle: 'Ví dụ 1013 hPa = ${u.pressureText(1013)}',
              options: [for (final p in PressureUnit.values) (p, p.label)],
              selected: u.pressure,
              onSelected: (p) => set(u.copyWith(pressure: p)),
            ),
            const Divider(height: 1),
            _ChoiceGroup<PrecipUnit>(
              icon: Icons.umbrella_outlined,
              title: 'Lượng mưa',
              options: [for (final p in PrecipUnit.values) (p, p.label)],
              selected: u.precip,
              onSelected: (p) => set(u.copyWith(precip: p)),
            ),
            const Divider(height: 1),
            _ChoiceGroup<DistanceUnit>(
              icon: Icons.straighten_rounded,
              title: 'Khoảng cách',
              subtitle: 'Dùng cho tầm nhìn và chế độ di chuyển.',
              options: [for (final d in DistanceUnit.values) (d, d.label)],
              selected: u.distance,
              onSelected: (d) => set(u.copyWith(distance: d)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSizes.paddingM,
                0,
                AppSizes.paddingM,
                AppSizes.paddingM,
              ),
              child: _Note(
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

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: AppTextStyles.bodySmall.copyWith(
        color: Theme.of(context).textTheme.bodySmall?.color,
      ),
    ),
  );
}

/// "Chỉ số trên trang chủ": bat/tat + keo tha, co nut len/xuong thay the.
class _HomeMetricsSection extends StatelessWidget {
  const _HomeMetricsSection();

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
            padding: EdgeInsets.fromLTRB(
              AppSizes.paddingM,
              AppSizes.paddingM,
              AppSizes.paddingM,
              AppSizes.paddingXS,
            ),
            child: _Note(
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
              padding: const EdgeInsets.all(AppSizes.paddingS),
              child: TextButton.icon(
                onPressed: prefs.resetMetrics,
                icon: const Icon(Icons.restart_alt_rounded),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.paddingXS),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Kéo để sắp xếp $name',
              child: const SizedBox.square(
                dimension: 48,
                child: Icon(Icons.drag_indicator_rounded),
              ),
            ),
          ),
          Expanded(
            child: Text(
              name,
              style: AppTextStyles.bodyMedium.copyWith(
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
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
          IconButton(
            tooltip: 'Đưa $name xuống',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: index == count - 1
                ? null
                : () => prefs.moveMetric(metric, 1),
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          Semantics(
            label: 'Hiện $name trên trang chủ',
            child: Switch(
              value: visible,
              onChanged: (v) => prefs.setMetricVisible(metric, v),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Địa điểm": bat/tat canh bao va nguong rieng cho tung dia diem.
class _PlacesSection extends StatelessWidget {
  const _PlacesSection();

  static LocationProvider? _locations(BuildContext context) {
    try {
      return Provider.of<LocationProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final lp = _locations(context);
    if (planner == null || lp == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(AppSizes.paddingM),
          child: _Note('Chưa tải được danh sách địa điểm.'),
        ),
      );
    }
    final s = planner.settings;
    final pages = lp.pages;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSizes.paddingM,
              AppSizes.paddingM,
              AppSizes.paddingM,
              0,
            ),
            child: _Note(
              'Bật/tắt cảnh báo cho từng nơi; đặt ngưỡng riêng nếu muốn. '
              'Cài đặt theo hoạt động nằm ở mục Hoạt động.',
            ),
          ),
          for (final e in pages) ...[
            Builder(
              builder: (context) {
                final place = lp.placeById(e.locationId);
                final label = lp.labelFor(e);
                final o = s.placeOverride(e.locationId);
                final title = label == null
                    ? place.name
                    : '$label · ${place.name}';
                final custom = o.thresholds.length;
                return Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.place_outlined),
                      title: Text(title),
                      subtitle: Text(
                        !o.enabled
                            ? 'Đã tắt cảnh báo'
                            : custom == 0
                            ? 'Dùng ngưỡng chung'
                            : '$custom ngưỡng riêng',
                      ),
                      value: o.enabled,
                      onChanged: (v) => planner.setSettings(
                        s.withPlace(e.locationId, o.copyWith(enabled: v)),
                      ),
                    ),
                    if (o.enabled)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: AppSizes.paddingS,
                          ),
                          child: TextButton.icon(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => _PlaceThresholdDialog(
                                placeId: e.locationId,
                                placeName: title,
                                planner: planner,
                                units: PreferencesProvider.unitsOf(context),
                                formatTemp: context
                                    .read<WeatherProvider>()
                                    .formatTemperature,
                              ),
                            ),
                            icon: const Icon(Icons.tune_rounded),
                            label: Text('Ngưỡng riêng cho ${place.name}'),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Hop thoai nguong rieng: moi loai co cong tac "Riêng" + thanh truot.
/// Gia tri luu theo don vi goc; nhan hien theo don vi nguoi dung chon.
class _PlaceThresholdDialog extends StatelessWidget {
  const _PlaceThresholdDialog({
    required this.placeId,
    required this.placeName,
    required this.planner,
    required this.units,
    required this.formatTemp,
  });

  final String placeId;
  final String placeName;
  final PlannerProvider planner;
  final UnitPrefs units;
  final String Function(double c) formatTemp;

  /// (min, max, buoc) theo don vi goc.
  static const Map<AlertType, (double, double, double)> ranges = {
    AlertType.rain: (30, 100, 5),
    AlertType.heavyRain: (2, 50, 1),
    AlertType.heat: (30, 42, 1),
    AlertType.uv: (3, 11, 1),
    AlertType.wind: (20, 100, 5),
    AlertType.aqi: (51, 301, 50),
  };

  String _fmt(AlertType t, double v) => switch (t) {
    AlertType.rain => '${v.round()}%',
    AlertType.heavyRain => units.rainRateText(v),
    AlertType.heat => formatTemp(v),
    AlertType.wind => units.windText(v),
    _ => '${v.round()}',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: planner,
      builder: (context, _) {
        final s = planner.settings;
        final o = s.placeOverride(placeId);
        return AlertDialog(
          title: Text('Ngưỡng riêng · $placeName'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in ranges.keys)
                  if (s.isEnabled(t)) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.label),
                      subtitle: Text(
                        o.thresholds[t] == null
                            ? 'Chung: ${_fmt(t, s.thresholdOf(t)!)}'
                            : 'Riêng: ${_fmt(t, o.thresholds[t]!)}',
                      ),
                      value: o.thresholds[t] != null,
                      onChanged: (v) => planner.setSettings(
                        s.withPlace(
                          placeId,
                          o.withThreshold(t, v ? s.thresholdOf(t) : null),
                        ),
                      ),
                    ),
                    if (o.thresholds[t] != null)
                      Slider(
                        value: o.thresholds[t]!
                            .clamp(ranges[t]!.$1, ranges[t]!.$2)
                            .toDouble(),
                        min: ranges[t]!.$1,
                        max: ranges[t]!.$2,
                        divisions:
                            ((ranges[t]!.$2 - ranges[t]!.$1) / ranges[t]!.$3)
                                .round(),
                        label: _fmt(t, o.thresholds[t]!),
                        semanticFormatterCallback: (v) => _fmt(t, v),
                        onChanged: (v) => planner.setSettings(
                          s.withPlace(placeId, o.withThreshold(t, v)),
                        ),
                      ),
                  ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                planner.setSettings(
                  s.withPlace(placeId, PlaceAlertOverride(enabled: o.enabled)),
                );
              },
              child: const Text('Dùng ngưỡng chung'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Xong'),
            ),
          ],
        );
      },
    );
  }
}

/// "Trợ năng": co chu, tuong phan cao, giam chuyen dong.
class _AccessibilitySection extends StatelessWidget {
  const _AccessibilitySection();

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
          _ChoiceGroup<double>(
            icon: Icons.format_size_rounded,
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
          SwitchListTile(
            secondary: const Icon(Icons.contrast_rounded),
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
          SwitchListTile(
            secondary: const Icon(Icons.motion_photos_off_outlined),
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

// ---------------------------------------------------------------------------
// Nang cao - May chu du lieu (URL backend luc chay)
// ---------------------------------------------------------------------------

/// Ket qua kiem tra `/health`.
typedef ServerHealth = ({bool ok, String message});

/// Goi `GET {baseUrl}/health` va mo ta ket qua bang tieng Viet.
Future<ServerHealth> checkServerHealth(
  String baseUrl, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final c = client ?? http.Client();
  try {
    final r = await c.get(Uri.parse('$baseUrl/health')).timeout(timeout);
    if (r.statusCode != 200) {
      return (ok: false, message: 'Máy chủ trả lỗi HTTP ${r.statusCode}.');
    }
    final j = jsonDecode(r.body);
    if (j is! Map || j['status'] == null) {
      return (ok: false, message: 'Không phải máy chủ Sky Weather.');
    }
    final age = j['data_age_hours'];
    final db = j['database'];
    final parts = [
      'Kết nối được (${j['status']})',
      if (db != null) 'CSDL: $db',
      if (age is num) 'dữ liệu mới nhất cách đây ${age.toStringAsFixed(1)} giờ',
    ];
    return (ok: true, message: '${parts.join(' · ')}.');
  } on TimeoutException {
    return (ok: false, message: 'Hết thời gian chờ. Kiểm tra địa chỉ và mạng.');
  } catch (_) {
    return (
      ok: false,
      message: 'Không kết nối được. Kiểm tra địa chỉ, mạng và máy chủ.',
    );
  } finally {
    if (client == null) c.close();
  }
}

class _ServerSection extends StatefulWidget {
  const _ServerSection();

  @override
  State<_ServerSection> createState() => _ServerSectionState();
}

class _ServerSectionState extends State<_ServerSection> {
  late final TextEditingController _ctrl = TextEditingController(
    text: ApiConfig.baseUrl,
  );
  String? _error;
  ServerHealth? _health;
  bool _checking = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Tai lai du lieu sau khi doi may chu.
  void _reload() {
    context.read<WeatherProvider>().fetchWeatherData();
    try {
      context.read<LocationProvider>().refreshRemote();
    } on ProviderNotFoundException {
      // Man hinh don le (test): khong co danh sach dia diem.
    }
  }

  Future<void> _save() async {
    final ok = await ApiConfig.setBaseUrl(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _error = ok ? null : 'Địa chỉ không hợp lệ. Dùng http:// hoặc https://';
      _health = null;
    });
    if (!ok) return;
    _ctrl.text = ApiConfig.baseUrl;
    _reload();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Đã lưu máy chủ ${ApiConfig.baseUrl}')),
    );
  }

  Future<void> _reset() async {
    await ApiConfig.setBaseUrl(null);
    if (!mounted) return;
    setState(() {
      _ctrl.text = ApiConfig.baseUrl;
      _error = null;
      _health = null;
    });
    _reload();
  }

  Future<void> _check() async {
    final url = ApiConfig.normalizeBaseUrl(_ctrl.text);
    if (url == null) {
      setState(
        () => _error = 'Địa chỉ không hợp lệ. Dùng http:// hoặc https://',
      );
      return;
    }
    setState(() {
      _error = null;
      _checking = true;
      _health = null;
    });
    final h = await checkServerHealth(url);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _health = h;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = GlassInk.of(context);
    final custom = ApiConfig.baseUrlOverride != null;
    final h = _health;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Máy chủ dữ liệu',
                style: AppTextStyles.bodyLarge.copyWith(
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),
            ),
            const SizedBox(height: AppSizes.paddingXS),
            _Note(
              custom
                  ? 'Đang dùng địa chỉ tự đặt. Mặc định: '
                        '${ApiConfig.defaultBaseUrl}'
                  : 'Đang dùng địa chỉ mặc định của bản cài.',
            ),
            const SizedBox(height: AppSizes.paddingM),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Địa chỉ máy chủ (URL)',
                hintText: 'http://192.168.1.10:8000',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSizes.paddingS),
            Wrap(
              spacing: AppSizes.paddingS,
              runSpacing: AppSizes.paddingXS,
              children: [
                FilledButton.icon(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: Colors.white,
                    foregroundColor: _onSelected,
                  ),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Lưu và tải lại'),
                ),
                OutlinedButton.icon(
                  onPressed: _checking ? null : _check,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.network_check_rounded),
                  label: const Text('Kiểm tra kết nối'),
                ),
                TextButton.icon(
                  onPressed: custom ? _reset : null,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Khôi phục mặc định'),
                ),
              ],
            ),
            if (_checking)
              const Padding(
                padding: EdgeInsets.only(top: AppSizes.paddingS),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Đang kiểm tra kết nối',
                ),
              ),
            if (h != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSizes.paddingS),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        h.ok
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        color: h.ok ? ink.accent : ink.warning,
                        size: AppSizes.iconSizeS,
                      ),
                      const SizedBox(width: AppSizes.paddingS),
                      Expanded(
                        child: Text(
                          h.message,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: h.ok ? Colors.white : ink.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thong bao va canh bao, hoat dong (gio di / ve)

String _hm(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// Cai dat canh bao (man rieng) + thong bao buoi sang.
class _NotifySection extends StatelessWidget {
  const _NotifySection();

  Future<void> _toggleBrief(
    BuildContext context,
    PlannerProvider planner,
    bool on,
  ) async {
    final ok = await planner.setMorningBrief(on);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chưa được cấp quyền thông báo (hoặc thiết bị không hỗ trợ). '
            'Cảnh báo vẫn hiện trong ứng dụng.',
          ),
        ),
      );
    }
  }

  Future<void> _pickTime(BuildContext context, PlannerProvider planner) async {
    final c = planner.commute;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: c.briefHour, minute: c.briefMinute),
      helpText: 'Giờ gửi thông báo buổi sáng',
    );
    if (t == null) return;
    planner.setCommute(c.copyWith(briefHour: t.hour, briefMinute: t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final theme = Theme.of(context);
    final small = AppTextStyles.bodySmall.copyWith(
      color: theme.textTheme.bodySmall?.color,
    );
    final alertTile = ListTile(
      leading: const Icon(Icons.warning_amber_rounded),
      title: const Text('Cảnh báo, ngưỡng và giờ yên lặng'),
      subtitle: const Text('Mưa, dông sét, nắng nóng, gió, UV, không khí'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AlertSettingsScreen()),
      ),
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
              leading: Icon(Icons.wb_twilight_rounded),
              title: Text('Thông báo buổi sáng'),
              subtitle: Text(
                'Chỉ có trên ứng dụng Android, iPhone. Trên trình duyệt, '
                'xem tóm tắt ở thẻ Gợi ý hoạt động.',
              ),
            )
          else
            SwitchListTile(
              secondary: const Icon(Icons.wb_twilight_rounded),
              title: const Text('Thông báo buổi sáng'),
              subtitle: Text(
                'Lúc $time: tóm tắt mưa trong ngày ở Nhà và Nơi làm',
              ),
              value: on,
              onChanged: (v) => _toggleBrief(context, planner, v),
            ),
          if (on) ...[
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Giờ gửi'),
              subtitle: Text(time),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _pickTime(context, planner),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.bedtime_outlined),
              title: const Text('Gửi cả trong giờ yên lặng'),
              subtitle: Text(
                quiet.quietEnabled
                    ? 'Giờ yên lặng ${quiet.quietStart}h–${quiet.quietEnd}h'
                          '${inQuiet ? ' (giờ gửi nằm trong khoảng này)' : ''}'
                    : 'Giờ yên lặng đang tắt',
              ),
              value: c.briefInQuiet,
              onChanged: (v) =>
                  planner.setCommute(c.copyWith(briefInQuiet: v)),
            ),
            if (planner.morningBriefAt == null && !c.briefInQuiet && inQuiet)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSizes.paddingM,
                  0,
                  AppSizes.paddingM,
                  AppSizes.paddingM,
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
class _ActivitySection extends StatelessWidget {
  const _ActivitySection();

  Future<void> _pick(
    BuildContext context,
    PlannerProvider planner,
    bool leave,
  ) async {
    final c = planner.commute;
    final t = await showTimePicker(
      context: context,
      initialTime: leave
          ? TimeOfDay(hour: c.leaveHour, minute: c.leaveMinute)
          : TimeOfDay(hour: c.returnHour, minute: c.returnMinute),
      helpText: leave ? 'Giờ đi làm / đi học' : 'Giờ về',
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
      leading: const Icon(Icons.directions_run_rounded),
      title: const Text('Hoạt động yêu thích và lịch'),
      subtitle: const Text('Gợi ý giờ đẹp trời, nhắc trước giờ hoạt động'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ActivitiesScreen())),
    );
    if (planner == null) return Card(child: open);
    final c = planner.commute;
    return Card(
      child: Column(
        children: [
          open,
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.two_wheeler_rounded),
            title: const Text('Giờ đi làm / đi học'),
            subtitle: Text(_hm(c.leaveHour, c.leaveMinute)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pick(context, planner, true),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Giờ về'),
            subtitle: Text(_hm(c.returnHour, c.returnMinute)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pick(context, planner, false),
          ),
        ],
      ),
    );
  }
}
