import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/weather.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/sun_times.dart';
import '../../ui/weather/weather_insights.dart';
import '../../ui/weather/widgets/aqi_card.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../../ui/weather/widgets/metric_tile.dart';
import '../../ui/weather/widgets/uv_card.dart';
import '../../utils/formatters.dart';
import '../../utils/forecast_format.dart';
import 'home_current_sources.dart';

/// Luoi "Chi tiết" 2 cot o gan vuong: AQI (ca hang), cam giac, UV, gio, do
/// am, tam nhin, ap suat, luong mua, may, mat troi (ca hang).
/// Gia tri null -> "Không có dữ liệu".
class HomeDetailsGrid extends StatelessWidget {
  const HomeDetailsGrid({super.key, required this.current});

  final CurrentWeather current;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final c = current;
    final now = provider.nowHcm;
    final hours = provider.hourlyForecast;
    final feels = c.feelsLike;
    final vis = c.visibilityKm;
    final dir = c.windDirection;
    final cloud = c.cloudCover;
    final p = c.pressure;
    final rain = rainTotals(hours, nowHcm: now);
    final sourceLine = c.source == null
        ? null
        : c.fieldSources.isEmpty
        ? 'Nguồn: ${c.source!.label}'
        : 'Thời tiết: ${c.source!.label} · Chỉ số tham khảo ghi nguồn tại từng mục.';

    final aqi = AqiCard(
      usAqi: c.usAqi,
      sourceLabel:
          currentReferenceLabel(c, 'us_aqi') ??
          currentReferenceLabel(c, 'pm2_5'),
      pm25: c.pm25,
      sentence: aqiSentence(
        aqi: c.usAqi,
        pm25: c.pm25,
        hours: hours,
        nowHcm: now,
      ),
    );

    final u = PreferencesProvider.unitsOf(context);
    final order =
        PreferencesProvider.maybeOf(context)?.visibleMetrics ??
        HomeMetric.values;
    final wind = c.windSpeed == null ? null : u.windParts(c.windSpeed!);
    final pres = p == null ? null : u.pressureParts(p);
    // Khoang trang khong ngat dong trong "12 km/h".
    String nb(String s) => s.replaceAll(' ', ' ');

    Widget tile(HomeMetric m) {
      switch (m) {
        case HomeMetric.aqi:
          return aqi;
        case HomeMetric.sun:
          return _SunTile(
            nowHcm: now,
            lat: provider.place.lat,
            lon: provider.place.lon,
          );
        case HomeMetric.feelsLike:
          return MetricTile(
            footer: currentReferenceLabel(c, 'apparent_temperature'),
            title: 'Cảm giác như',
            icon: Icons.thermostat_outlined,
            value: feels == null ? null : '${u.tempNumber(feels)}°',
            sentence: feels == null
                ? null
                : feelsLikeSentence(
                    temperature: c.temperature,
                    feelsLike: feels,
                    humidity: c.humidity,
                    windKmh: c.windSpeed,
                  ),
          );
        case HomeMetric.uv:
          return UvCard(
            uvIndex: c.uvIndex,
            sourceLabel: currentReferenceLabel(c, 'uv_index'),
            sentence: uvSentence(hours, nowHcm: now),
          );
        case HomeMetric.wind:
          return MetricTile(
            title: 'Gió',
            icon: Icons.air_rounded,
            value: wind?.value,
            unit: wind?.unit,
            label: dir == null ? null : 'Hướng ${WeatherFormat.compass(dir)}',
            sentence: c.windGusts == null
                ? null
                : 'Gió giật tới ${nb(u.windText(c.windGusts))}.',
            semanticsLabel: c.windSpeed == null
                ? 'Gió: $kNoData'
                : 'Gió ${u.windText(c.windSpeed)}'
                      '${dir == null ? '' : ', thổi từ hướng ${WeatherFormat.compass(dir)} (${dir.round()} độ)'}'
                      '${c.windGusts == null ? '' : ', giật tới ${u.windText(c.windGusts)}'}',
            visual: dir == null
                ? null
                : Center(
                    child: CompassDial(
                      degrees: dir,
                      size: 104,
                      centerText: wind == null
                          ? '--'
                          : [wind.value, ?wind.unit].join('\n'),
                    ),
                  ),
          );
        case HomeMetric.humidity:
          return MetricTile(
            title: 'Độ ẩm',
            icon: Icons.water_drop_outlined,
            value: c.humidity == null
                ? null
                : WeatherFormat.percent(c.humidity),
            sentence: humiditySentence(c.dewPoint),
          );
        case HomeMetric.visibility:
          return MetricTile(
            footer: currentReferenceLabel(c, 'visibility'),
            title: 'Tầm nhìn',
            icon: Icons.visibility_outlined,
            value: vis == null ? null : u.distanceText(vis),
            label: vis == null ? null : _visibilityLabel(vis),
            sentence: vis == null
                ? null
                : vis >= 10
                ? 'Trời trong, nhìn xa rõ.'
                : 'Tầm nhìn bị hạn chế bởi mây, mưa hoặc bụi.',
          );
        case HomeMetric.pressure:
          return MetricTile(
            footer:
                currentReferenceLabel(c, 'pressure_msl') ??
                currentReferenceLabel(c, 'surface_pressure'),
            title: 'Áp suất',
            icon: Icons.speed_rounded,
            value: pres?.value,
            unit: pres?.unit,
            label: p == null ? null : pressureCaption(p),
            sentence: 'Áp suất mực nước biển.',
            visual: p == null
                ? null
                : Center(child: PressureGauge(hpa: p, size: 88)),
          );
        case HomeMetric.rain:
          return MetricTile(
            title: 'Lượng mưa',
            icon: Icons.umbrella_outlined,
            value: c.precipitationMm == null
                ? null
                : u.rainText(c.precipitationMm),
            label: 'Trong giờ hiện tại',
            sentence: [
              rain.past24 == null
                  ? 'Chưa có số liệu 24 giờ qua.'
                  : '24 giờ qua: ${u.rainText(rain.past24)}.',
              if (rain.next24 != null)
                'Dự báo 24 giờ tới: ${u.rainText(rain.next24)}.',
            ].join(' '),
          );
        case HomeMetric.cloud:
          return MetricTile(
            title: 'Mây',
            icon: Icons.cloud_outlined,
            value: cloud == null ? null : WeatherFormat.percent(cloud),
            label: cloud == null ? null : _cloudLabel(cloud),
            sentence: 'Tỉ lệ bầu trời bị mây che phủ.',
          );
      }
    }

    Widget keyed(HomeMetric m) =>
        KeyedSubtree(key: ValueKey('metric-${m.name}'), child: tile(m));

    return Semantics(
      container: true,
      label: 'Chi tiết hiện tại',
      child: LayoutBuilder(
        builder: (context, box) {
          // Man rong: 3 cot (>= 900) / 2 cot (>= 600) va o "ca hang" cung
          // xep vao luoi (khong con moi o mot hang tren may tinh).
          final cols = box.maxWidth >= 900 ? 3 : 2;
          final packAll = box.maxWidth >= 600;
          final tileW = (box.maxWidth - Space.cardGap * (cols - 1)) / cols;
          Widget line(List<Widget> items) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cols; i++) ...[
                  if (i > 0) const SizedBox(width: Space.cardGap),
                  Expanded(
                    child: i < items.length
                        ? ConstrainedBox(
                            // O gan vuong; co chu lon thi tu cao them.
                            constraints: BoxConstraints(
                              minHeight: (tileW * 0.9)
                                  .clamp(0.0, 240.0)
                                  .toDouble(),
                            ),
                            child: items[i],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
          // Theo thu tu uu tien: o ca hang dung rieng (man hep), o nho ghep
          // thanh hang [cols] o lien tiep.
          final rows = <Widget>[];
          var pending = <Widget>[];
          void flush() {
            if (pending.isNotEmpty) rows.add(line(pending));
            pending = <Widget>[];
          }

          for (final m in order) {
            if (m.fullWidth && !packAll) {
              flush();
              rows.add(keyed(m));
              continue;
            }
            pending.add(keyed(m));
            if (pending.length == cols) flush();
          }
          flush();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: Space.cardGap),
                rows[i],
              ],
              if (order.isEmpty)
                GlassCard(
                  child: Text(
                    'Chưa chọn chỉ số nào. Bật trong Cài đặt > Chỉ số trên '
                    'trang chủ.',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                ),
              if (sourceLine != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.xs,
                    Space.s,
                    Space.xs,
                    0,
                  ),
                  child: Text(
                    '$sourceLine · Cập nhật '
                    '${ForecastFormat.dateTime(c.lastUpdated)}',
                    style: TypeScale.small.copyWith(
                      color: GlassInk.of(context).headerSecondary,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _visibilityLabel(double km) {
    if (km < 1) return 'Rất kém';
    if (km < 5) return 'Hạn chế';
    if (km < 10) return 'Trung bình';
    return 'Tốt';
  }

  static String _cloudLabel(int cover) {
    if (cover < 20) return 'Ít mây';
    if (cover < 60) return 'Mây rải rác';
    if (cover < 90) return 'Nhiều mây';
    return 'U ám';
  }
}

/// O mat troi moc / lan: gio cua ngay (theo nowHcm), cung voi vi tri mat
/// troi hien tai.
class _SunTile extends StatelessWidget {
  const _SunTile({required this.nowHcm, required this.lat, required this.lon});

  final DateTime nowHcm;

  /// Toa do dia diem dang xem (gio mat troi theo tung noi).
  final double lat;
  final double lon;

  @override
  Widget build(BuildContext context) {
    final today = SunTimes.forDate(nowHcm, lat: lat, lon: lon);
    final isDay =
        !nowHcm.isBefore(today.sunrise) && nowHcm.isBefore(today.sunset);
    final afterSunset = !nowHcm.isBefore(today.sunset);
    final next = afterSunset
        ? SunTimes.forDate(
            nowHcm.add(const Duration(days: 1)),
            lat: lat,
            lon: lon,
          )
        : today;
    final hm = ForecastFormat.hourMinute;
    final double? progress = isDay
        ? nowHcm.difference(today.sunrise).inSeconds /
              today.sunset.difference(today.sunrise).inSeconds
        : null;
    final String title = isDay ? 'Mặt trời lặn' : 'Mặt trời mọc';
    final String value = isDay ? hm(today.sunset) : hm(next.sunrise);
    final String label = isDay
        ? 'Mặt trời mọc: ${hm(today.sunrise)}'
        : 'Mặt trời lặn: ${hm(afterSunset ? today.sunset : next.sunset)}';
    final dl = today.dayLength;
    return MetricTile(
      title: title,
      icon: isDay ? Icons.wb_twilight_rounded : Icons.wb_sunny_outlined,
      value: value,
      label: label,
      sentence:
          'Ngày dài ${dl.inHours} giờ ${dl.inMinutes.remainder(60)} phút '
          '(tính theo vị trí điểm dữ liệu).',
      visual: SunArc(progress: progress),
    );
  }
}
