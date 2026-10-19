import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../glass_ink.dart';
import 'collapsing_header.dart';

/// Unframed current conditions; values and guidance come from the provider.
class HomeWeatherOverview extends StatelessWidget {
  const HomeWeatherOverview({
    super.key,
    required this.info,
    required this.onTrip,
  });

  final WeatherHeaderInfo info;
  final VoidCallback onTrip;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.detail,
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: Palette.white,
              ),
            ),
            const SizedBox(height: Space.s),
            Wrap(
              spacing: Space.xl,
              runSpacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (info.temperature != null)
                  Semantics(
                    label: info.semanticsTemp,
                    excludeSemantics: info.semanticsTemp != null,
                    child: Text(
                      info.temperature!,
                      textScaler: TextScaler.linear(
                        (MediaQuery.textScalerOf(context).scale(80) / 80).clamp(
                          1.0,
                          1.3,
                        ),
                      ),
                      style: const TextStyle(
                        fontSize: 80,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        fontFeatures: TypeScale.tabular,
                        color: Palette.white,
                      ),
                    ),
                  ),
                if (info.condition != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Hiện tại',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Palette.white,
                          ),
                        ),
                        Text(
                          info.condition!,
                          style: const TextStyle(
                            fontSize: 22,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: Palette.white,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (info.highLow != null) ...[
              const SizedBox(height: Space.s),
              Text(
                info.highLow!,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  fontFeatures: TypeScale.tabular,
                  color: Palette.white,
                ),
              ),
            ],
            if (info.temperature != null) ...[
              const SizedBox(height: Space.xl),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: info.todayRain ? ink.rain : Palette.tempMild,
                      width: 3,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Space.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.today ?? 'Chưa có dự báo theo giờ',
                        style: const TextStyle(
                          fontSize: 18,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                          color: Palette.white,
                        ),
                      ),
                      const SizedBox(height: Space.m),
                      FilledButton.icon(
                        onPressed: onTrip,
                        style: FilledButton.styleFrom(
                          backgroundColor: Palette.white,
                          foregroundColor: Palette.onAlert,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.directions_walk_rounded),
                        label: const Text(
                          'Lên kế hoạch ra ngoài',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: Space.l),
            Semantics(
              liveRegion: info.isStale,
              child: Wrap(
                spacing: Space.m,
                runSpacing: Space.xs,
                children: [
                  if (info.isStale)
                    const Text(
                      'Dữ liệu cũ',
                      style: TextStyle(
                        color: Palette.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (info.sourceLabel != null)
                    Text(
                      info.sourceLabel!,
                      style: const TextStyle(
                        color: Palette.white,
                        fontSize: 14,
                      ),
                    ),
                  if (info.updated != null)
                    Text(
                      info.updated!,
                      style: const TextStyle(
                        color: Palette.white,
                        fontSize: 14,
                      ),
                    ),
                  if (info.cachedNote != null)
                    Text(
                      info.cachedNote!,
                      style: const TextStyle(
                        color: Palette.white,
                        fontSize: 14,
                      ),
                    ),
                  if (info.refreshing)
                    const Text(
                      'Đang cập nhật...',
                      style: TextStyle(color: Palette.white, fontSize: 14),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
