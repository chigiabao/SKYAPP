import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../providers/preferences_provider.dart';
import '../../providers/trip_provider.dart';
import '../../ui/weather/design_tokens.dart';
import 'trip_helpers.dart';

/// Man dang di: toi gian, chu to, nut lon; khong can thao tac.
class DrivingView extends StatelessWidget {
  const DrivingView({super.key, required this.trip});

  final TripProvider trip;

  @override
  Widget build(BuildContext context) {
    final units = PreferencesProvider.unitsOf(context);
    final paused = trip.phase == TripPhase.paused;
    final alert = trip.lastAlert;
    final route = trip.ahead ?? trip.route;
    // The provider's legacy all-clear message is not a complete hazard assessment.
    final status =
        route != null &&
            trip.status == 'Không có mưa lớn hay dông trên phần đường còn lại.'
        ? routeWeatherSummary(route)
        : trip.status;
    final coverageNote = route == null ? null : routeCoverageNote(route);
    final big = TypeScale.title1.copyWith(
      color: Palette.white,
      fontWeight: FontWeight.w700,
    );
    final mid = TypeScale.title3.copyWith(
      color: Palette.white,
      fontWeight: FontWeight.w400,
    );
    return Scaffold(
      backgroundColor: Palette.drivingScrim,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(Space.m),
                decoration: BoxDecoration(
                  color: Palette.alert,
                  borderRadius: BorderRadius.circular(Radii.tile),
                ),
                child: Text(
                  'Không thao tác khi đang lái xe',
                  textAlign: TextAlign.center,
                  style: TypeScale.title3.copyWith(
                    color: Palette.onAlert,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: Space.xl),
              // Trang thai doi -> trinh doc man hinh doc lai (lai xe khong
              // nhin man hinh).
              Semantics(
                liveRegion: true,
                child: Text(
                  paused
                      ? 'Đã tạm dừng'
                      : trip.withRoute
                      ? 'Đang theo tuyến'
                      : 'Đang theo dõi vị trí',
                  style: mid,
                ),
              ),
              if (trip.withRoute && trip.remainingKm != null)
                Text('Còn ${units.distanceText(trip.remainingKm)}', style: big),
              const SizedBox(height: Space.l),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (alert != null) ...[
                        Semantics(
                          liveRegion: true,
                          child: MergeSemantics(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(alert.title, style: big),
                                const SizedBox(height: Space.s),
                                Text(alert.body, style: mid),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.l),
                      ],
                      if (status != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            status,
                            style: mid.copyWith(color: Palette.secondary),
                          ),
                        ),
                      if (coverageNote != null) ...[
                        const SizedBox(height: Space.s),
                        Text(
                          coverageNote,
                          style: mid.copyWith(color: Palette.secondary),
                        ),
                      ],
                      if (kIsWeb)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.l),
                          child: Text(
                            'Trên trình duyệt chỉ theo dõi khi tab này đang mở.',
                            style: mid.copyWith(color: Palette.secondary),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      // Nut lon cho tay khi lai xe; cao them khi chu lon.
                      constraints: const BoxConstraints(minHeight: 72),
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(72),
                          foregroundColor: Palette.white,
                          side: const BorderSide(color: Palette.white),
                          textStyle: TypeScale.title3,
                        ),
                        onPressed: paused ? trip.resume : trip.pause,
                        icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 32,
                        ),
                        label: Text(paused ? 'Tiếp tục' : 'Tạm dừng'),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.l),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 72),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(72),
                          backgroundColor: Palette.stop,
                          foregroundColor: Palette.white,
                          textStyle: TypeScale.title3,
                        ),
                        onPressed: trip.end,
                        icon: const Icon(Icons.stop_rounded, size: 32),
                        label: const Text('Kết thúc'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
