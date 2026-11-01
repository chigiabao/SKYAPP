import 'package:flutter/material.dart';

import '../../models/weather_alerts.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/trip_provider.dart';
import '../../services/route_service.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/widgets/glass_card.dart';
import 'trip_helpers.dart';
import 'route_weather_details.dart';

class RouteSummary extends StatelessWidget {
  const RouteSummary({
    super.key,
    required this.trip,
    this.fromLabel = 'Điểm đi',
    this.toLabel = 'Điểm đến',
  });

  final TripProvider trip;
  final String fromLabel;
  final String toLabel;

  @override
  Widget build(BuildContext context) {
    final r = trip.plan!;
    final ink = GlassInk.of(context);
    final units = PreferencesProvider.unitsOf(context);
    final better = trip.betterDeparture;
    final coverageNote = routeCoverageNote(r);
    final body = TypeScale.body.copyWith(color: Palette.white);
    final shownHazards = RouteHazard.values.where(
      (h) => r.samples.any((s) => s.hazard == h),
    );
    String? suggestion;
    if (trip.comparing) {
      suggestion = 'Đang so sánh giờ đi sớm / muộn hơn…';
    } else if (trip.departOptions.isNotEmpty &&
        (!r.hasCompleteHazardCoverage ||
            trip.departOptions.any(
              (o) => !o.route.hasCompleteHazardCoverage,
            ))) {
      // The coverage note already states the own-AI limitation once.
      if (!r.hasOwnModelForecasts) {
        suggestion = 'Chưa đủ dữ liệu để kết luận giờ đi tốt nhất.';
      }
    } else if (better != null) {
      final m = better.offsetMin;
      suggestion =
          'Nên đi ${m < 0 ? 'sớm' : 'muộn'} hơn ${m.abs()} phút '
          '(${formatHhmm(better.route.departAt)}): ít mưa, dông hơn trên đường.';
    } else if (trip.departOptions.isNotEmpty) {
      suggestion = 'Giờ đi đã chọn là tốt nhất trong khoảng ±60 phút.';
    }
    return GlassCard(
      title: 'TÓM TẮT TUYẾN',
      icon: Icons.summarize_outlined,
      footer: '${r.attribution}. $kAlertDisclaimer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${units.distanceText(r.distanceKm)} · ${durationText(r.durationMin)}'
            ' · đến lúc ${formatHhmm(r.arriveAt)}',
            style: TypeScale.headline.copyWith(color: Palette.white),
          ),
          const SizedBox(height: Space.s),
          Text(routeWeatherSummary(r), style: body),
          const SizedBox(height: Space.m),
          RouteWeatherDetails(
            route: r,
            units: units,
            fromLabel: fromLabel,
            toLabel: toLabel,
          ),
          if (coverageNote != null) ...[
            const SizedBox(height: Space.s),
            Text(coverageNote, style: body.copyWith(color: ink.secondary)),
          ],
          if (suggestion != null) ...[
            const SizedBox(height: Space.s),
            Text(suggestion, style: body.copyWith(color: ink.secondary)),
          ],
          const SizedBox(height: Space.s),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: Space.m,
              runSpacing: Space.xs,
              children: [
                for (final h in shownHazards)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 14, height: 4, color: hazardColor(h)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            r.hasOwnModelForecasts && h == RouteHazard.heavy
                                ? 'Mưa to / có cảnh báo'
                                : h.label,
                            style: TypeScale.label,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
