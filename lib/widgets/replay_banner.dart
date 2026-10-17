import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../screens/forecast/forecast_format.dart';
import '../utils/constants.dart';

/// Thanh "ĐANG XEM LẠI: 12:00 Thứ 4, 07/10/2026 — Thoát".
/// Chi la giao dien; trang thai lay tu [WeatherProvider.isReplay] /
/// [WeatherProvider.replayAt].
class ReplayBanner extends StatelessWidget {
  const ReplayBanner({super.key, required this.at, required this.onExit});

  final DateTime at; // gio TP.HCM
  final VoidCallback onExit;

  static const Color background = Color(0xFF8A4B00); // chu trang ~ 6.9:1

  static String text(DateTime at) =>
      'ĐANG XEM LẠI: ${ForecastFormat.moment(at)}';

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(left: AppSizes.paddingM),
          child: Row(
            children: [
              const Icon(Icons.history_rounded, color: Colors.white, size: 18),
              const SizedBox(width: AppSizes.paddingS),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    text(at),
                    style: AppTextStyles.bodySmall.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: onExit,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text(
                  'Thoát',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white,
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

/// Boc toan bo Navigator (MaterialApp.builder): khi dang xem lai, banner nam
/// tren cung o MOI man hinh. Phan duoi bo padding tren de khong bi doi.
class ReplayBannerHost extends StatelessWidget {
  const ReplayBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final at = provider.replayAt;
    if (!provider.isReplay || at == null) return child;
    return Column(
      children: [
        ReplayBanner(at: at, onExit: provider.exitReplay),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
