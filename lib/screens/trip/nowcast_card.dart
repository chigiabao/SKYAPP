import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/weather.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/trip_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../../ui/weather/widgets/ios_controls.dart';
import '../../widgets/source_badge.dart';
import 'trip_helpers.dart';

class NowcastCard extends StatelessWidget {
  const NowcastCard({super.key, required this.trip, required this.onRetry});

  final TripProvider trip;
  final VoidCallback onRetry;

  /// Loi khuyen theo xac suat / luong mua lon nhat. Gio "thuc te" chi co
  /// xac suat 1/0 nen chi tinh luong mua (mm) cua no.
  static String advice(List<HourlyForecast> hours) {
    var p = 0.0;
    var mm = 0.0;
    var storm = false;
    for (final h in hours) {
      final hp = h.isObserved ? null : h.rainProbability;
      p = (hp ?? 0) > p ? hp! : p;
      mm = (h.precipitationMm ?? 0) > mm ? h.precipitationMm! : mm;
      storm = storm || h.condition == WeatherCondition.thunderstorm;
    }
    if (storm) return 'Có thể có dông: mặc áo mưa bộ, tránh trú dưới cây to.';
    if (p >= 0.6 || mm >= 2) {
      return 'Mưa khá chắc: mang áo mưa bộ, chạy chậm và tránh chỗ ngập.';
    }
    if (p >= 0.3 || mm >= 0.2) return 'Có thể mưa: bỏ sẵn áo mưa vào cốp xe.';
    return 'Khả năng mưa thấp, chưa cần áo mưa.';
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final units = PreferencesProvider.unitsOf(context);
    final body = TypeScale.body.copyWith(color: Palette.white);
    final hours = trip.nowcastHours;
    final place = trip.nowcastPlace;
    final Widget child;
    if (trip.nowcastLoading) {
      child = Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CupertinoActivityIndicator(radius: 9, color: Palette.white),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text('Đang lấy vị trí và dự báo…', style: body),
            ),
          ),
        ],
      );
    } else if (trip.nowcastError != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              trip.nowcastError!,
              style: body.copyWith(color: ink.warning),
            ),
          ),
          const SizedBox(height: Space.s),
          // Nut co nen: mep trai thang le noi dung the (khong thut nhu
          // TextButton).
          IosButton.tinted(
            label: 'Thử lại',
            icon: CupertinoIcons.arrow_clockwise,
            onPressed: onRetry,
          ),
        ],
      );
    } else if (place == null || hours.isEmpty) {
      child = Text('Chưa có dự báo cho chỗ bạn.', style: body);
    } else {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              advice(hours),
              style: TypeScale.headline.copyWith(color: Palette.white),
            ),
          ),
          const SizedBox(height: Space.s),
          for (final (i, h) in hours.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      i == 0 ? 'Bây giờ' : formatHhmm(h.time),
                      style: TypeScale.hourLabel.copyWith(color: ink.secondary),
                    ),
                  ),
                  Icon(Icons.water_drop_rounded, size: 18, color: ink.rain),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(
                      h.rainProbability == null || h.isObserved
                          ? units.rainText(h.precipitationMm)
                          : '${(h.rainProbability! * 100).round()}% · '
                                '${units.rainText(h.precipitationMm)}',
                      style: body,
                    ),
                  ),
                  if (h.isObserved)
                    const SourceTag(source: DataSource.observed),
                ],
              ),
            ),
        ],
      );
    }
    return GlassCard(
      title: 'Mưa trong 2 giờ tới tại chỗ bạn',
      icon: Icons.umbrella_rounded,
      footer: place == null
          ? null
          : 'Gần ${place.name} · theo từng giờ · '
                '${SourceSummary.of(hours.map((h) => h.source)).label}'
                '${trip.nowcastUpdatedAt == null ? '' : ' · Cập nhật ${formatHhmm(trip.nowcastUpdatedAt!)}'}',
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
