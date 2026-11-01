import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/app_version.dart';
import '../../ui/weather/design_tokens.dart';
import 'settings_common.dart';

/// Nhom "Thông tin" va "Nguồn dữ liệu" (con truc tiep cua ListView Cai dat).
List<Widget> settingsAboutChildren(BuildContext context) {
  final theme = Theme.of(context);
  // Mau chu canh bao du tuong phan (>= 4.5:1) tren nen cam nhat
  final warningText = theme.brightness == Brightness.dark
      ? Tones.warmOnDark
      : Tones.warmOnLight;
  return [
    // About section
    SettingsSectionHeader(title: 'Thông tin', icon: CupertinoIcons.info_circle),
    Card(
      child: Column(
        children: [
          SettingsTile(
            icon: CupertinoIcons.info_circle,
            title: 'Phiên bản',
            subtitle: AppVersion.current,
          ),
          const Divider(height: 1),
          SettingsTile(
            icon: CupertinoIcons.person,
            title: 'Phát triển',
            subtitle: 'Đồ án sinh viên',
          ),
          const Divider(height: 1),
          SettingsTile(
            icon: CupertinoIcons.device_phone_portrait,
            title: 'Công nghệ',
            subtitle: 'Flutter · FastAPI · LightGBM',
          ),
        ],
      ),
    ),

    const SizedBox(height: Space.xl),

    // Data source info
    SettingsSectionHeader(title: 'Nguồn dữ liệu', icon: CupertinoIcons.cloud),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SettingsIcon(CupertinoIcons.cloud),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Text(
                    'Nguồn dữ liệu',
                    style: TypeScale.heading3.copyWith(
                      color: theme.textTheme.titleLarge?.color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s),
            Text(
              'Mọi giá trị dự báo (theo giờ, 7 ngày, 1–6 giờ tới, bản đồ) do '
              'AI của nhóm tạo ra, phục vụ qua máy chủ FastAPI của nhóm. '
              'Dữ liệu đầu vào từ Open-Meteo (giờ đã qua, giấy phép CC BY 4.0): '
              '10 năm số liệu theo giờ (2017–2026) để huấn luyện và các giờ gần '
              'nhất để chạy AI — đây là số liệu đã ghi nhận do mô hình ước tính, '
              'không phải trạm đo, và không phải dự báo. Mục "Đã ghi nhận" là số '
              'liệu này; "Trung bình nhiều năm" là thống kê. Nguồn được ghi rõ '
              'trên từng mục. Dự báo AI là thử nghiệm, chỉ mang tính tham khảo.',
              style: TypeScale.bodyMedium.copyWith(
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: Space.l),
            Container(
              padding: const EdgeInsets.all(Space.s),
              decoration: BoxDecoration(
                color: Palette.alert.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.small),
                border: Border.all(color: Palette.alert.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    CupertinoIcons.exclamationmark_triangle,
                    color: warningText,
                    size: IconSizes.inline,
                  ),
                  const SizedBox(width: Space.s),
                  Expanded(
                    child: Text(
                      'Không dùng cho mục đích an toàn. Cảnh báo thời tiết '
                      'chính thức xem tại Đài KTTV khu vực Nam Bộ.',
                      style: TypeScale.bodySmall.copyWith(
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
  ];
}
