import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../utils/forecast_format.dart';
import '../ui/weather/design_tokens.dart';

/// Thanh "ĐANG XEM LẠI: 07/10 12:00 — Thoát" (ngay gio ngan de khong bi cat
/// khi chu 200 %; day du "12:00 Thứ 4, 07/10/2026" nam trong Semantics).
/// Chi la giao dien; trang thai lay tu [WeatherProvider.isReplay] /
/// [WeatherProvider.replayAt].
class ReplayBanner extends StatelessWidget {
  const ReplayBanner({super.key, required this.at, required this.onExit});

  final DateTime at; // gio TP.HCM
  final VoidCallback onExit;

  static const Color background = Palette.replay; // chu trang ~ 6.9:1

  static String text(DateTime at) =>
      'ĐANG XEM LẠI: ${ForecastFormat.dateTime(at)}';

  /// Nhan day du cho trinh doc man hinh (chu tren banner co the bi cat).
  static String semanticsLabel(DateTime at) =>
      'Đang xem lại dữ liệu lúc ${ForecastFormat.moment(at)}. '
      'Mọi số liệu là của thời điểm đó, không phải hiện tại.';

  @override
  Widget build(BuildContext context) {
    // Mot dong ca khi chu 200 %: phong toi da 1.3 lan + cat "..."; noi dung
    // day du nam o nhan truy cap.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Material(
        color: background,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.only(left: Space.l),
            child: Row(
              children: [
                const Icon(
                  Icons.history_rounded,
                  color: Palette.white,
                  size: 18,
                ),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    label: semanticsLabel(at),
                    excludeSemantics: true,
                    child: Text(
                      text(at),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TypeScale.bodySmall.copyWith(
                        color: Palette.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  label: 'Thoát xem lại, về dữ liệu hiện tại',
                  excludeSemantics: true,
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: Space.l),
                    minimumSize: const Size(Touch.min, Touch.min),
                    onPressed: onExit,
                    child: Text(
                      'Thoát',
                      maxLines: 1,
                      style: TypeScale.subhead.copyWith(
                        color: Palette.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
