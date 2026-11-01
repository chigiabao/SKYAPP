/// Nut thanh tren, bang trang thai va the "chua co du lieu" cua Home.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../providers/weather_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../../ui/weather/widgets/ios_controls.dart';
import '../../ui/weather/widgets/home_skeleton.dart';
import '../settings_screen.dart';

/// Nut Canh bao (trai thanh tren). Lam moi: keo de lam moi.
class HomeHeaderActions extends StatelessWidget {
  const HomeHeaderActions({super.key, this.unread = 0, this.onAlerts});

  /// So thong bao chua doc (man Canh bao).
  final int unread;
  final VoidCallback? onAlerts;

  @override
  Widget build(BuildContext context) {
    if (onAlerts == null) return const SizedBox(width: Touch.min);
    return GlassIconButton(
      tooltip: unread > 0 ? 'Cảnh báo, $unread thông báo mới' : 'Cảnh báo',
      icon: unread > 0 ? CupertinoIcons.bell_fill : CupertinoIcons.bell,
      onPressed: onAlerts,
    );
  }
}

/// Nut Cai dat (phai thanh tren).
class HomeSettingsButton extends StatelessWidget {
  const HomeSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      tooltip: 'Cài đặt',
      icon: CupertinoIcons.ellipsis_circle,
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

/// Actionable status band, separate from the weather summary.
class HomeGlassBanner extends StatelessWidget {
  const HomeGlassBanner({
    super.key,
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.banner,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(child: Icon(icon, color: Palette.stale)),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: TypeScale.subhead.copyWith(
                        height: 1.5,
                        color: Palette.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: const Size(Touch.min, Touch.min),
                  foregroundColor: Palette.white,
                ),
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chua co du lieu: dang tai / loi / trong.
class HomeStateCard extends StatelessWidget {
  const HomeStateCard({super.key, required this.provider});

  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    if (provider.isLoading) return const HomeSkeleton();
    final error = provider.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Column(
        children: [
          const ExcludeSemantics(
            child: Icon(
              CupertinoIcons.wifi_slash,
              size: 48,
              color: Palette.secondary,
            ),
          ),
          const SizedBox(height: Space.xl),
          Text(
            'Chưa thể tải thời tiết',
            textAlign: TextAlign.center,
            style: TypeScale.title2.copyWith(color: Palette.white, height: 1.3),
          ),
          const SizedBox(height: Space.s),
          Text(
            error ?? 'Không có dữ liệu',
            textAlign: TextAlign.center,
            style: TypeScale.body.copyWith(color: Palette.secondary),
          ),
          const SizedBox(height: Space.l),
          // Nut chinh chuan cua app (nen trang, chu toi) thay nut xanh.
          IosButton.filled(
            label: 'Thử lại',
            icon: CupertinoIcons.arrow_clockwise,
            onPressed: provider.fetchWeatherData,
          ),
          const SizedBox(height: Space.xs),
          CupertinoButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: Text(
              'Máy chủ dữ liệu',
              style: TypeScale.subhead.copyWith(color: Palette.rain),
            ),
          ),
        ],
      ),
    );
  }
}
