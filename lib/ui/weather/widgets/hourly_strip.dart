/// Dai "Theo giờ" ngang: o "Bây giờ", cac gio tiep theo, va moc
/// "Mặt trời mọc" / "Mặt trời lặn" chen dung vi tri thoi gian.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../config/api_config.dart';
import '../../../models/weather.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/weather_provider.dart';
import '../../../widgets/source_badge.dart';
import '../app_scene.dart';
import '../sun_times.dart';
import '../design_tokens.dart';
import '../glass_ink.dart';
import '../weather_icons.dart';
import '../weather_insights.dart';
import '../weather_scene.dart';
import 'glass_card.dart';

/// Mot muc tren dai: gio du bao hoac su kien mat troi.
sealed class HourlyEntry {
  const HourlyEntry(this.time);

  /// Gio TP.HCM cua muc (gio: dau gio; mat troi: phut chinh xac).
  final DateTime time;
}

class HourEntry extends HourlyEntry {
  HourEntry(this.forecast, {required this.isNow}) : super(forecast.time);

  final HourlyForecast forecast;
  final bool isNow;
}

class SunEntry extends HourlyEntry {
  const SunEntry(super.time, {required this.isSunrise});

  final bool isSunrise;

  String get label => isSunrise ? 'Mặt trời mọc' : 'Mặt trời lặn';

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

/// Dung dai thoi gian: [hours] (sap xep theo gio) + moc mat troi cua moi ngay
/// ma dai phu, chen sau o gio chua no (gio <= moc < gio + 1).
/// Moc truoc o dau tien hoac sau het o cuoi cung bi bo.
List<HourlyEntry> buildHourlyTimeline(
  List<HourlyForecast> hours, {
  required DateTime nowHcm,
  double lat = ApiConfig.latitude,
  double lon = ApiConfig.longitude,
}) {
  if (hours.isEmpty) return const [];
  final sorted = [...hours]..sort((a, b) => a.time.compareTo(b.time));
  final DateTime first = sorted.first.time;
  final DateTime endExclusive = sorted.last.time.add(const Duration(hours: 1));
  final nowHour = HcmTime.startOfHour(nowHcm);

  final events = <SunEntry>[];
  for (
    DateTime d = HcmTime.startOfDay(first);
    !d.isAfter(endExclusive);
    d = d.add(const Duration(days: 1))
  ) {
    final SunTimes s = SunTimes.forDate(d, lat: lat, lon: lon);
    if (s.isPolarDay || s.isPolarNight) continue;
    for (final e in [
      SunEntry(s.sunrise, isSunrise: true),
      SunEntry(s.sunset, isSunrise: false),
    ]) {
      if (!e.time.isBefore(first) && e.time.isBefore(endExclusive)) {
        events.add(e);
      }
    }
  }
  events.sort((a, b) => a.time.compareTo(b.time));

  final out = <HourlyEntry>[];
  var ei = 0;
  for (final h in sorted) {
    // Moc thuoc gio truoc da chen; chen gio nay roi cac moc trong gio nay.
    out.add(HourEntry(h, isNow: HcmTime.startOfHour(h.time) == nowHour));
    final next = h.time.add(const Duration(hours: 1));
    while (ei < events.length && events[ei].time.isBefore(next)) {
      out.add(events[ei++]);
    }
  }
  return out;
}

/// The "Theo giờ" (kinh).
class HourlyStrip extends StatelessWidget {
  const HourlyStrip({super.key, required this.hours, this.nowHcm});

  final List<HourlyForecast> hours;

  /// Gio hien tai (de test); mac dinh [WeatherProvider.nowHcm].
  final DateTime? nowHcm;

  static const double baseTileWidth = 64;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final now = nowHcm ?? provider.nowHcm;
    final summary = SourceSummary.of(hours.map((h) => h.source));
    final minority = minoritySources(hours.map((h) => h.source));
    DataSource? tagFor(HourlyForecast f) {
      final s = f.source ?? SourceSummary.fallback;
      return minority.contains(s) ? s : null;
    }

    final anyTag = hours.any((h) => tagFor(h) != null);
    final entries = buildHourlyTimeline(hours, nowHcm: now);

    final scaler = MediaQuery.textScalerOf(context);
    double sc(double v) => scaler.scale(v);
    // Chieu cao o: 4 dong chu (gio, nhiet, mua, nguon) + icon + khoang cach.
    final double tileHeight =
        16 +
        1.3 * (sc(13) + sc(18) + sc(12) + (anyTag ? sc(11) : 0)) +
        30 +
        6 * 3 +
        6;
    final double tileWidth = (sc(18) * 2.4 + 12).clamp(baseTileWidth, 120.0);

    final sentence = hourlySummary(
      hours,
      nowHcm: now,
      currentCondition: provider.currentWeather?.condition,
      units: PreferencesProvider.unitsOf(context),
    );

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: GlassCardTitle(
              title: 'Theo giờ',
              icon: Icons.schedule_rounded,
            ),
          ),
          if (sentence != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                sentence,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TypeScale.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: Palette.white,
                ),
              ),
            ),
          const SizedBox(height: 10),
          const Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: GlassColors.divider,
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: tileHeight,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return switch (e) {
                  HourEntry() => _HourTile(
                    entry: e,
                    width: tileWidth,
                    sourceTag: tagFor(e.forecast),
                  ),
                  SunEntry() => _SunTile(entry: e, width: tileWidth * 1.25),
                };
              },
            ),
          ),
          const SizedBox(height: 4),
          const Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: GlassColors.divider,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SourceSubtitle(summary: summary),
          ),
        ],
      ),
    );
  }
}

class _HourTile extends StatelessWidget {
  const _HourTile({
    required this.entry,
    required this.width,
    required this.sourceTag,
  });

  final HourEntry entry;
  final double width;
  final DataSource? sourceTag;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final f = entry.forecast;
    final mm = f.precipitationMm;
    final rainText = f.isObserved
        ? (mm != null && mm > 0
              ? PreferencesProvider.unitsOf(context).rainText(mm)
              : null)
        : (f.rainPercent > 0 ? '${f.rainPercent}%' : null);
    final label = entry.isNow
        ? 'Bây giờ'
        : '${f.time.hour.toString().padLeft(2, '0')}:00';
    final isDay = isDayAt(f.time);
    final code = f.weatherCode ?? wmoForCondition(f.condition);
    final icon = WeatherIcon.fromCode(code, isDay: isDay, size: 28);
    final ink = GlassInk.of(context);

    return Semantics(
      label:
          '$label: ${provider.formatTemperature(f.temperature)}, '
          '${icon.scene.label}'
          '${rainText == null
              ? ''
              : f.isObserved
              ? ', mưa $rainText'
              : ', khả năng mưa $rainText'}'
          '${sourceTag != null ? ', ${sourceTag!.shortLabel}' : ''}',
      excludeSemantics: true,
      child: Container(
        width: width,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: entry.isNow
            ? BoxDecoration(
                color: Palette.subtleFill,
                borderRadius: BorderRadius.circular(Radii.tile),
              )
            : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            _fit(
              Text(
                label,
                style: TypeScale.hourLabel.copyWith(
                  color: Palette.white,
                  fontWeight: entry.isNow ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 6),
            icon,
            const SizedBox(height: 6),
            _fit(
              Text(
                '${provider.formatTempValue(f.temperature)}°',
                style: TypeScale.label.copyWith(
                  fontSize: 18,
                  color: Palette.white,
                  fontFeatures: kTabular,
                ),
              ),
            ),
            const SizedBox(height: 6),
            _fit(
              Text(
                rainText ?? ' ',
                style: TypeScale.small.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ink.rain,
                  fontFeatures: kTabular,
                ),
              ),
            ),
            if (sourceTag != null) _fit(SourceTag(source: sourceTag!)),
          ],
        ),
      ),
    );
  }
}

class _SunTile extends StatelessWidget {
  const _SunTile({required this.entry, required this.width});

  final SunEntry entry;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${entry.label} ${entry.timeText}',
      excludeSemantics: true,
      child: Container(
        width: width,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          children: [
            _fit(
              Text(
                entry.timeText,
                style: TypeScale.hourLabel.copyWith(color: Palette.white),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 28,
              height: 28,
              child: CustomPaint(
                painter: SunEventIconPainter(isSunrise: entry.isSunrise),
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: Text(
                entry.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.text,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _fit(Widget child) => FittedBox(fit: BoxFit.scaleDown, child: child);

/// Icon mat troi moc/lan: nua mat troi tren duong chan troi + mui ten.
class SunEventIconPainter extends CustomPainter {
  SunEventIconPainter({required this.isSunrise});

  final bool isSunrise;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide / 24;
    final Paint sun = Paint()..color = const Color(0xFFFFD45C);
    final Paint line = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.6 * s
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final Offset c = Offset(12 * s, 17 * s);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width, 17 * s));
    canvas.drawCircle(c, 6 * s, sun);
    canvas.restore();
    // Tia
    for (final (double dx, double dy) in const [
      (-9.0, -1.5),
      (9.0, -1.5),
      (-6.4, -6.4),
      (6.4, -6.4),
    ]) {
      final Offset d = Offset(dx, dy) * s;
      canvas.drawLine(c + d * 0.95, c + d * 1.18, line..color = sun.color);
    }
    line.color = const Color(0xFFFFFFFF);
    canvas.drawLine(Offset(2 * s, 17 * s), Offset(22 * s, 17 * s), line);
    // Mui ten len (moc) / xuong (lan)
    final double top = 1.5 * s;
    final double bottom = 7.5 * s;
    final double x = 12 * s;
    canvas.drawLine(Offset(x, top), Offset(x, bottom), line);
    final double tip = isSunrise ? top : bottom;
    final double back = isSunrise ? top + 3 * s : bottom - 3 * s;
    canvas.drawLine(Offset(x, tip), Offset(x - 2.6 * s, back), line);
    canvas.drawLine(Offset(x, tip), Offset(x + 2.6 * s, back), line);
  }

  @override
  bool shouldRepaint(SunEventIconPainter old) => old.isSunrise != isSunrise;
}
