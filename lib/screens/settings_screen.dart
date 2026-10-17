import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/debug/weather_simulator_screen.dart';
import '../ui/weather/widgets/glass_page.dart';
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
    final provider = context.watch<WeatherProvider>();
    // Mau chu canh bao du tuong phan (>= 4.5:1) tren nen cam nhat
    final warningText = theme.brightness == Brightness.dark
        ? Colors.orange.shade200
        : Colors.deepOrange.shade900;

    final sceneOverride = maybeSceneOverride(context, listen: false);

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
        padding: const EdgeInsets.all(AppSizes.paddingM),
        children: [
          // Appearance section
          _SectionHeader(title: 'Giao diện'),
          Card(
            child: Column(
              children: [
                // Theme mode: Sang / Toi / Theo he thong
                _SettingsTile(
                  icon: _themeIcon(provider.themeMode),
                  title: 'Chế độ giao diện',
                  subtitle: _themeLabel(provider.themeMode),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSizes.paddingM,
                    0,
                    AppSizes.paddingM,
                    AppSizes.paddingM,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Sáng'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Tối'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('Theo hệ thống'),
                        ),
                      ],
                      selected: {provider.themeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (selection) {
                        provider.setThemeMode(selection.first);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSizes.paddingL),

          // Units section
          _SectionHeader(title: 'Đơn vị'),
          Card(
            child: Column(
              children: [
                // Temperature unit
                _SettingsTile(
                  icon: Icons.thermostat_rounded,
                  title: 'Đơn vị nhiệt độ',
                  subtitle: provider.isCelsius
                      ? 'Celsius (°C)'
                      : 'Fahrenheit (°F)',
                  trailing: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('°C')),
                      ButtonSegment(value: false, label: Text('°F')),
                    ],
                    selected: {provider.isCelsius},
                    onSelectionChanged: (selection) {
                      provider.setTemperatureUnit(selection.first);
                    },
                    style: ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSizes.paddingL),

          // Replay / demo section
          _SectionHeader(title: 'Xem lại'),
          const ReplaySettingsCard(),

          const SizedBox(height: AppSizes.paddingL),

          // About section
          _SectionHeader(title: 'Thông tin'),
          Card(
            child: Column(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: 'Phiên bản',
                  subtitle: '1.0.0',
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
          _SectionHeader(title: 'Dữ liệu'),
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

String _themeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'Sáng';
    case ThemeMode.dark:
      return 'Tối';
    case ThemeMode.system:
      return 'Theo hệ thống';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(
        left: AppSizes.paddingS,
        bottom: AppSizes.paddingS,
      ),
      child: Text(
        title.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: theme.textTheme.bodySmall?.color,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
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
      trailing: trailing,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSizes.paddingM,
        vertical: AppSizes.paddingXS,
      ),
    );
  }
}
