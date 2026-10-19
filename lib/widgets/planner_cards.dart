/// The kinh cho canh bao va goi y hoat dong (Home + man chi tiet).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/activities.dart';
import '../models/weather.dart';
import '../models/weather_alerts.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';

/// Icon cua loai canh bao (Material, khong dung emoji).
IconData alertIcon(AlertType t) {
  switch (t) {
    case AlertType.rain:
      return Icons.umbrella_outlined;
    case AlertType.heavyRain:
      return Icons.water_drop_outlined;
    case AlertType.thunderstorm:
      return Icons.thunderstorm_outlined;
    case AlertType.heat:
      return Icons.thermostat_rounded;
    case AlertType.uv:
      return Icons.wb_sunny_outlined;
    case AlertType.wind:
      return Icons.air_rounded;
    case AlertType.aqi:
      return Icons.masks_outlined;
  }
}

IconData activityIcon(Activity a) {
  switch (a) {
    case Activity.running:
      return Icons.directions_run_rounded;
    case Activity.cycling:
      return Icons.directions_bike_rounded;
    case Activity.commute:
      return Icons.commute_rounded;
    case Activity.laundry:
      return Icons.local_laundry_service_outlined;
    case Activity.outing:
      return Icons.park_outlined;
    case Activity.photography:
      return Icons.photo_camera_outlined;
    case Activity.watering:
      return Icons.yard_outlined;
  }
}

/// Mau icon theo muc (tin hieu phu - chu van trang, muc ghi bang chu).
Color levelColor(BuildContext context, AlertLevel l) {
  switch (l) {
    case AlertLevel.advisory:
      return GlassInk.of(context).secondary;
    case AlertLevel.warning:
      return GlassInk.of(context).alert;
    case AlertLevel.danger:
      return Palette.tempHot;
  }
}

String _hh(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Hôm nay 06:00–07:00" / "Mai 17:00–19:00" / "T2 18/10 06:00–07:00".
String windowLabel(DateTime start, DateTime end, DateTime nowHcm) {
  final d = HcmTime.startOfDay(start)
      .difference(HcmTime.startOfDay(nowHcm))
      .inDays;
  final day = d == 0
      ? 'Hôm nay'
      : d == 1
      ? 'Mai'
      : '${start.day}/${start.month}';
  return '$day ${_hh(start)}\u2060–\u2060${_hh(end)}';
}

/// Banner gon o Home: so canh bao + canh bao quan trong nhat; cham de mo
/// man Canh bao. Vach mau trai 3 px nhu banner mua cu.
class AlertsSummaryBanner extends StatelessWidget {
  const AlertsSummaryBanner({
    super.key,
    required this.events,
    required this.onOpen,
    required this.onDismiss,
  });

  /// Da sap xep (muc cao truoc) - [evaluateAlerts].
  final List<AlertEvent> events;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final top = events.first;
    final color = levelColor(context, top.level);
    final more = events.length > 1 ? ' · +${events.length - 1} khác' : '';
    return Semantics(
      liveRegion: true,
      container: true,
      child: GlassSurface(
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 3, child: ColoredBox(color: color)),
              Expanded(
                child: Pressable(
                  onTap: onOpen,
                  semanticsLabel:
                      '${top.level.label}: ${top.title}. ${top.detailFor(PreferencesProvider.unitsOf(context))}$more. '
                      'Dữ liệu mô hình. Mở màn Cảnh báo',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Touch.min),
                    child: Row(
                      children: [
                        const SizedBox(width: Space.m),
                        Icon(
                          alertIcon(top.type),
                          color: color,
                          size: IconSizes.md,
                        ),
                        const SizedBox(width: Space.m),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.m,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${top.level.label} · ${top.title}',
                                    maxLines: 1,
                                    style: TypeScale.label.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: Palette.white,
                                      fontFeatures: kTabular,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${top.detailFor(PreferencesProvider.unitsOf(context))}$more',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TypeScale.small.copyWith(
                                    fontSize: 13,
                                    color: ink.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const ExcludeSemantics(
                          child: Icon(
                            Icons.chevron_right_rounded,
                            color: Palette.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Center(
                child: Tooltip(
                  message: 'Đóng cảnh báo',
                  excludeFromSemantics: true,
                  child: Pressable(
                    onTap: onDismiss,
                    semanticsLabel: 'Đóng cảnh báo',
                    child: const SizedBox.square(
                      dimension: Touch.min,
                      child: Icon(
                        Icons.close_rounded,
                        color: Palette.white,
                        size: IconSizes.md,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Space.xs),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mot dong canh bao (man Canh bao).
class AlertEventTile extends StatelessWidget {
  const AlertEventTile({super.key, required this.event});

  final AlertEvent event;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    return Semantics(
      container: true,
      label:
          '${event.level.label}: ${event.title}. ${event.detailFor(PreferencesProvider.unitsOf(context))}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s),
          child: Row(
            children: [
              Icon(
                alertIcon(event.type),
                color: levelColor(context, event.level),
                size: IconSizes.md,
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: TypeScale.body.copyWith(
                        color: Palette.white,
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabular,
                      ),
                    ),
                    Text(
                      event.detailFor(PreferencesProvider.unitsOf(context)),
                      style: TypeScale.small.copyWith(color: ink.secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.s),
              GlassPill(
                label: event.level.label,
                icon: Icons.circle,
                iconColor: levelColor(context, event.level),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Gợi ý hoạt động": moi hoat dong yeu thich -> khung gio tot nhat.
class ActivitySuggestionCard extends StatelessWidget {
  const ActivitySuggestionCard({
    super.key,
    required this.activities,
    required this.hours,
    required this.nowHcm,
    this.horizonHours = 24,
    this.sensitivity = Sensitivity.normal,
    this.onOpen,
    this.title = 'GỢI Ý HOẠT ĐỘNG',
  });

  final List<Activity> activities;
  final List<HourlyForecast> hours;

  /// Gio "hien tai" cua app (provider.nowHcm, ke ca xem lai).
  final DateTime nowHcm;
  final int horizonHours;
  final Sensitivity sensitivity;
  final VoidCallback? onOpen;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final rows = <Widget>[];
    for (final a in activities) {
      if (a == Activity.commute) {
        rows.add(CommuteRows(hours: hours, nowHcm: nowHcm));
        continue;
      }
      final w = bestWindows(
        a,
        hours,
        nowHcm: nowHcm,
        horizonHours: horizonHours,
        limit: 1,
        sensitivity: sensitivity,
      );
      rows.add(
        ActivityWindowRow(
          activity: a,
          window: w.isEmpty ? null : w.first,
          nowHcm: nowHcm,
        ),
      );
    }
    return GlassCard(
      title: title,
      icon: Icons.event_available_outlined,
      footer:
          'Chấm điểm theo nhiệt độ cảm giác, mưa, UV, gió, AQI '
          '(dữ liệu mô hình).',
      trailing: onOpen == null
          ? null
          : TextButton(
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: Palette.white,
                minimumSize: const Size(Touch.min, Touch.min),
              ),
              child: const Text('Chi tiết'),
            ),
      child: activities.isEmpty
          ? Text(
              'Chưa chọn hoạt động yêu thích.',
              style: TypeScale.body.copyWith(color: ink.secondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
    );
  }
}

/// Mot hoat dong + khung gio goi y (hoac "khong co khung phu hop").
class ActivityWindowRow extends StatelessWidget {
  const ActivityWindowRow({
    super.key,
    required this.activity,
    required this.window,
    required this.nowHcm,
    this.showActivity = true,
    this.showDay = true,
  });

  final Activity activity;
  final ActivityWindow? window;
  final DateTime nowHcm;

  /// false: the da co ten hoat dong (man Hoat dong) -> chi hien gio.
  final bool showActivity;

  /// false: cung ngay voi dong tren -> bo "Hôm nay" / "Mai".
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final w = window;
    final when = w == null
        ? 'Chưa có khung giờ phù hợp'
        : showDay
        ? windowLabel(w.start, w.end, nowHcm)
        : '${_hh(w.start)}⁠–⁠${_hh(w.end)}';
    final rating = w?.rating.label;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '${activity.label}: $when'
          '${w == null ? '' : '. ${w.rating.label}, ${w.reason}'}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Row(
            children: [
              if (showActivity) ...[
                Icon(activityIcon(activity), color: Palette.white),
                const SizedBox(width: Space.m),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      showActivity ? '${activity.label} · $when' : when,
                      style: TypeScale.body.copyWith(
                        color: Palette.white,
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabular,
                      ),
                    ),
                    if (w != null)
                      Text(
                        w.reason,
                        style: TypeScale.small.copyWith(color: ink.secondary),
                      ),
                  ],
                ),
              ),
              if (rating != null) ...[
                const SizedBox(width: Space.s),
                GlassPill(label: rating),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Hai dong di / ve cho "Đi làm / đi học" (gio trong [PlannerProvider.commute],
/// mac dinh 7:30 / 17:30): "Về 17h30: mưa 70% – mang áo mưa". Dung du lieu
/// cua Nha (luc di) / Noi lam (luc ve) neu da tai, khong thi [hours] cua
/// trang dang xem.
class CommuteRows extends StatelessWidget {
  const CommuteRows({super.key, required this.hours, required this.nowHcm});

  final List<HourlyForecast> hours;
  final DateTime nowHcm;

  static String Function(double)? _temp(BuildContext context) {
    try {
      return Provider.of<WeatherProvider>(
        context,
        listen: false,
      ).formatTemperature;
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = maybePlanner(context);
    final c = planner?.commute ?? const CommuteSettings();
    final temp = _temp(context);
    List<HourlyForecast> of(String? id) =>
        (id == null ? null : planner?.hoursFor(id)) ?? hours;
    final lines = [
      commuteLine(
        'Đi',
        c.leaveHour,
        c.leaveMinute,
        of(c.homeId),
        nowHcm,
        formatTemp: temp,
      ),
      commuteLine(
        'Về',
        c.returnHour,
        c.returnMinute,
        of(c.workId),
        nowHcm,
        formatTemp: temp,
      ),
    ]..sort((a, b) => (a?.at ?? nowHcm).compareTo(b?.at ?? nowHcm));
    final shown = [for (final l in lines) ?l];
    return Semantics(
      container: true,
      excludeSemantics: true,
      label:
          '${Activity.commute.label}: '
          '${shown.isEmpty ? 'chưa có dự báo cho giờ đi, về' : shown.map((l) => l.text).join('. ')}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.min),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.two_wheeler_rounded, color: Palette.white),
              ),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (shown.isEmpty)
                      Text(
                        'Đi, về: chưa có dự báo cho giờ này',
                        style: TypeScale.body.copyWith(color: ink.secondary),
                      ),
                    for (final l in shown)
                      Text(
                        l.text,
                        style: TypeScale.body.copyWith(
                          color: Palette.white,
                          fontWeight: l.bad ? FontWeight.w600 : FontWeight.w400,
                          fontFeatures: kTabular,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
