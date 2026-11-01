import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/data_source.dart';
import '../providers/weather_provider.dart';
import '../utils/forecast_format.dart';
import '../utils/haptics.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';

/// Ly do AI cua nhom chua chay (tu chi tiet 503 cua backend).
enum AIUnavailableCause { noInput, notCovered, model }

/// Chi tiet 503 (`forecast_error` / `ai_error`) -> nguyen nhan. Khong bao gio
/// hien nguyen van chi tiet (co the chua thong bao loi ky thuat).
AIUnavailableCause aiUnavailableCause(String? detail) {
  final d = (detail ?? '').toLowerCase();
  // Kiem 'chưa phủ đủ' truoc: chi tiet backend nay cung nhac 'dữ liệu đầu vào'.
  if (d.contains('chưa phủ đủ')) return AIUnavailableCause.notCovered;
  if (d.contains('dữ liệu đầu vào') || d.contains('không đủ dữ liệu')) {
    return AIUnavailableCause.noInput;
  }
  return AIUnavailableCause.model;
}

/// Cau giai thich co dinh, de hieu cho nguoi dung.
String aiUnavailableReason(String? detail) =>
    switch (aiUnavailableCause(detail)) {
      AIUnavailableCause.noInput =>
        'Máy chủ chưa có dữ liệu đầu vào mới (các giờ vừa qua) nên AI của '
            'nhóm chưa chạy được.',
      AIUnavailableCause.notCovered =>
        'AI của nhóm chưa phủ đủ khoảng thời gian cần hiển thị.',
      AIUnavailableCause.model =>
        'Mô hình AI của nhóm tạm thời không chạy được trên máy chủ.',
    };

/// Thong bao ngan cho man khac (vd. chi tiet ngay).
String aiUnavailableMessage(String? detail) =>
    'Dự báo AI của nhóm chưa sẵn sàng. ${aiUnavailableReason(detail)}';

/// Trang thai "AI chưa sẵn sàng": giai thich vi sao, khong hien so thay the,
/// kem loi thu lai, xem moc mau da luu (che do xem lai) va man kiem chung.
///
/// [shortRange] = chi AI 1–6 giờ loi (`ai_error`); false = du bao theo gio /
/// 7 ngay loi (`forecast_error`).
class AIUnavailableCard extends StatelessWidget {
  const AIUnavailableCard({
    super.key,
    required this.detail,
    required this.onVerify,
    this.shortRange = false,
  });

  final String? detail;
  final bool shortRange;

  /// Mo man kiem chung AI (nut "Kiểm chứng AI").
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    final current = provider.currentWeather;
    final input = current?.lastUpdated;
    final busy = provider.isLoading || provider.isRefreshing;
    final message = switch (aiUnavailableCause(detail)) {
      AIUnavailableCause.noInput => 'Chờ dữ liệu đầu vào mới để chạy AI.',
      AIUnavailableCause.notCovered => 'AI chưa phủ đủ thời gian dự báo.',
      AIUnavailableCause.model => 'Mô hình AI tạm thời không khả dụng.',
    };
    final diagnostics = [
      if (shortRange)
        'Chưa có dự báo 1–6 giờ tới.'
      else
        'Chưa có dự báo theo giờ và 7 ngày.',
      aiUnavailableReason(detail),
      if (input != null)
        'Dữ liệu đầu vào mới nhất: ${ForecastFormat.moment(input)}.'
      else
        'Chưa có mốc dữ liệu đầu vào.',
      if (current != null)
        'Nguồn đầu vào: ${current.source?.note ?? 'chưa xác định'}',
      if (provider.isStale) 'Dữ liệu đầu vào đã cũ.',
      if (provider.isReplay) 'Đang xem lại mốc đã lưu, không phải dự báo live.',
      'Ứng dụng không thay bằng số của nguồn khác.',
    ].join(' ');
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: ink.accent,
      disabledForegroundColor: ink.secondary,
      minimumSize: const Size(Touch.min, Touch.min),
    );
    return GlassCard(
      title: shortRange ? 'AI 1–6 giờ chưa sẵn sàng' : 'AI chưa sẵn sàng',
      icon: Icons.hourglass_empty_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: TypeScale.body.copyWith(color: Palette.white),
            ),
          ),
          const SizedBox(height: Space.s),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: buttonStyle,
              onPressed: busy
                  ? null
                  : () {
                      AppHaptics.light();
                      provider.refreshWeatherData();
                    },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(busy ? 'Đang thử lại' : 'Thử lại'),
            ),
          ),
          ExpansionTile(
            key: PageStorageKey('ai-unavailable-details-$shortRange'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            minTileHeight: Touch.min,
            iconColor: ink.secondary,
            collapsedIconColor: ink.secondary,
            expansionAnimationStyle:
                MediaQuery.maybeDisableAnimationsOf(context) ?? false
                ? AnimationStyle.noAnimation
                : null,
            title: Text(
              'Chi tiết dữ liệu',
              style: TypeScale.body.copyWith(color: ink.secondary),
            ),
            children: [
              Text(
                diagnostics,
                style: TypeScale.body.copyWith(color: ink.secondary),
              ),
              Wrap(
                spacing: Space.s,
                children: [
                  if (!provider.isReplay)
                    TextButton(
                      style: buttonStyle,
                      onPressed: () =>
                          provider.startReplay(WeatherProvider.replayPreset),
                      child: const Text('Xem mốc mẫu đã lưu'),
                    ),
                  TextButton(
                    style: buttonStyle,
                    onPressed: onVerify,
                    child: const Text('Kiểm chứng AI'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
