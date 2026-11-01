import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/debug/weather_simulator_screen.dart';
import '../ui/weather/design_tokens.dart';
import 'account_screen.dart';
import 'feedback_screen.dart';
import '../utils/forecast_format.dart';
import 'onboarding_screen.dart';
import 'settings/settings_common.dart';
import 'settings/settings_info.dart';
import 'settings/settings_notify.dart';
import 'settings/settings_page.dart';
import 'settings/settings_places.dart';
import 'settings/settings_preferences.dart';
import 'settings/settings_server.dart';

export '../services/server_health.dart' show ServerHealth, checkServerHealth;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      SettingsPage(title: 'Cài đặt', childrenBuilder: _overviewChildren);

  List<Widget> _overviewChildren(BuildContext context) {
    final (isReplay, at) = context.select<WeatherProvider, (bool, DateTime?)>(
      (p) => (p.isReplay, p.replayAt),
    );
    return [
      Card(
        child: Column(
          children: [
            _category(
              context,
              id: 'display',
              icon: CupertinoIcons.paintbrush,
              title: 'Hiển thị',
              subtitle: 'Chỉ số trang chủ, đơn vị',
              childrenBuilder: _displayChildren,
            ),
            const Divider(height: 1),
            _category(
              context,
              id: 'notifications',
              icon: CupertinoIcons.bell,
              title: 'Thông báo',
              subtitle: 'Cảnh báo thời tiết, giờ yên lặng',
              childrenBuilder: (_) => [const SettingsNotifySection()],
            ),
            const Divider(height: 1),
            _category(
              context,
              id: 'places',
              icon: CupertinoIcons.location,
              title: 'Nơi và hoạt động',
              subtitle: 'Nhà, nơi làm, giờ đi về, hoạt động',
              childrenBuilder: _placesChildren,
            ),
            const Divider(height: 1),
            _category(
              context,
              id: 'accessibility',
              icon: CupertinoIcons.hand_raised,
              title: 'Trợ năng',
              subtitle: 'Cỡ chữ, tương phản, giảm chuyển động',
              childrenBuilder: (_) => [const SettingsAccessibilitySection()],
            ),
            const Divider(height: 1),
            _category(
              context,
              id: 'advanced',
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              title: 'Nâng cao',
              subtitle: isReplay
                  ? at == null
                        ? 'Chế độ xem lại đang bật'
                        : 'Đang xem lại: ${ForecastFormat.moment(at)}'
                  : 'Máy chủ dữ liệu, chế độ xem lại',
              childrenBuilder: _advancedChildren,
            ),
          ],
        ),
      ),
      const SizedBox(height: Space.xl),
      Card(
        child: Column(
          children: [
            ListTile(
              key: const ValueKey('settings-account'),
              leading: const SettingsIcon(CupertinoIcons.arrow_2_circlepath),
              title: const Text('Tài khoản'),
              subtitle: const Text('Đồng bộ tùy chọn, không bắt buộc'),
              trailing: const Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: Palette.secondary,
              ),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
            ),
            const Divider(height: 1),
            _category(
              context,
              id: 'help',
              icon: CupertinoIcons.question_circle,
              title: 'Trợ giúp',
              subtitle: 'Góp ý, hướng dẫn, nguồn dữ liệu',
              childrenBuilder: _helpChildren,
            ),
          ],
        ),
      ),
      const SizedBox(height: Space.xl),
      _footer(context),
    ];
  }

  Widget _category(
    BuildContext context, {
    required String id,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> Function(BuildContext) childrenBuilder,
    // Ten hang = tieu de trang con; giu ngan de tieu de lon khong bi cat
    // "..." o 375/390 pt (mo ta dai dua vao dong phu).
  }) => ListTile(
    key: ValueKey('settings-category-$id'),
    leading: SettingsIcon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(
      CupertinoIcons.chevron_right,
      size: 16,
      color: Palette.secondary,
    ),
    onTap: () => Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsPage(title: title, childrenBuilder: childrenBuilder),
      ),
    ),
  );

  List<Widget> _displayChildren(BuildContext context) => [
    const SettingsSectionHeader(
      title: 'Chỉ số trên trang chủ',
      icon: CupertinoIcons.square_grid_2x2,
    ),
    const SettingsHomeMetricsSection(),
    const SizedBox(height: Space.xl),
    const SettingsSectionHeader(
      title: 'Đơn vị',
      icon: CupertinoIcons.slider_horizontal_3,
    ),
    const SettingsUnitsSection(),
    const SizedBox(height: Space.xl),
    _footer(context),
  ];

  List<Widget> _placesChildren(BuildContext context) => const [
    SettingsSectionHeader(title: 'Địa điểm', icon: CupertinoIcons.location),
    SettingsPlacesSection(),
    SizedBox(height: Space.xl),
    SettingsSectionHeader(title: 'Hoạt động', icon: CupertinoIcons.calendar),
    SettingsActivitySection(),
  ];

  List<Widget> _advancedChildren(BuildContext context) {
    final sceneOverride = maybeSceneOverride(context, listen: false);
    return [
      const SettingsSectionHeader(
        title: 'Nâng cao',
        icon: CupertinoIcons.antenna_radiowaves_left_right,
      ),
      const SettingsServerSection(),
      const SizedBox(height: Space.xl),
      const SettingsSectionHeader(
        title: 'Chế độ xem lại',
        icon: CupertinoIcons.clock,
      ),
      const SettingsReplaySection(),
      if (WeatherSimulatorScreen.available && sceneOverride != null) ...[
        const SizedBox(height: Space.xl),
        Card(
          child: ListTile(
            leading: const SettingsIcon(CupertinoIcons.lab_flask),
            title: const Text('Giả lập thời tiết'),
            subtitle: const Text(
              'Xem trước và áp dụng cảnh nền (chỉ bản debug)',
            ),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
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
    ];
  }

  List<Widget> _helpChildren(BuildContext context) => [
    Card(
      child: Column(
        children: [
          ListTile(
            leading: const SettingsIcon(CupertinoIcons.chat_bubble),
            title: const Text('Phản hồi và báo lỗi'),
            subtitle: const Text('Báo lỗi, góp ý, báo dự báo sai'),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const FeedbackScreen())),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const SettingsIcon(CupertinoIcons.book),
            title: const Text('Xem lại hướng dẫn'),
            subtitle: const Text('Nhà, nơi làm, giờ đi về, thông báo'),
            trailing: const Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: Palette.secondary,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (c) =>
                    OnboardingScreen(onDone: () => Navigator.of(c).pop()),
              ),
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: Space.xl),
    ...settingsAboutChildren(context),
    const SizedBox(height: Space.xl),
    _footer(context),
  ];

  Widget _footer(BuildContext context) => Center(
    child: Text(
      'Sky Weather · TP. Hồ Chí Minh',
      // Nam tren nen canh o cuoi trang (nen sang hon dau trang): chu trang.
      style: TypeScale.caption.copyWith(color: Palette.white),
    ),
  );
}
