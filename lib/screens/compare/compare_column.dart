part of '../compare_screen.dart';

class _CompareColumn extends StatelessWidget {
  const _CompareColumn({
    required this.series,
    required this.loading,
    required this.nowHcm,
    required this.units,
    this.highlights,
    this.reserveNameLines = false,
  });

  /// Cot dat canh nhau: giu cho 2 dong ten de cac hang so lieu thang hang.
  final bool reserveNameLines;

  final CompareHighlights? highlights;
  final CompareSeries series;
  final bool loading;
  final DateTime nowHcm;
  final UnitPrefs units;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final d = series.data;
    final c = d?.current;
    final now = nowHcm;
    final small = TypeScale.small.copyWith(color: ink.secondary);
    final value = TypeScale.label.copyWith(
      color: Palette.white,
      fontWeight: FontWeight.w600,
      fontFeatures: kTabular,
    );
    Widget metric(String title, String v, {String? note}) => Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: small),
          Text(v, style: value),
          if (note != null) Text(note, style: small),
        ],
      ),
    );

    final rain = d == null ? null : compareRain3h(d.hourlyForecast, now, units);
    final id = series.place.id;
    final badges = [
      if (highlights?.rainiestId == id)
        (Icons.water_drop_rounded, 'Mưa nhiều nhất', ink.rain),
      if (highlights?.hottestId == id)
        (Icons.local_fire_department_rounded, 'Nóng nhất', ink.warning),
    ];
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ky hieu duong + nhan o hang rieng: ten dia diem duoc ca be
          // ngang cot va xuong dong, khong bi cat "Phường Bến T…".
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: _LegendSwatch(style: series.style),
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  // Khong co nhan (Nha/Noi lam) -> de trong, khong hien
                  // "TP.HCM cũ"; giu hang de cac cot thang hang. Nhan ngan +
                  // toi da 2 dong: ten tu dat dai van doc du, khong "Nơi làm…".
                  series.label ?? '',
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: small,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Builder(
            builder: (context) {
              final nameStyle = TypeScale.body.copyWith(
                color: Palette.white,
                fontWeight: FontWeight.w600,
              );
              final name = Text(
                series.place.name,
                maxLines: 2,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              );
              if (!reserveNameLines) return name;
              return Stack(
                children: [
                  ExcludeSemantics(
                    child: Opacity(
                      opacity: 0,
                      child: Text(' \n ', maxLines: 2, style: nameStyle),
                    ),
                  ),
                  name,
                ],
              );
            },
          ),
          const SizedBox(height: Space.s),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.l),
              child: Center(
                child: CupertinoActivityIndicator(color: Palette.white),
              ),
            )
          else if (c == null)
            Text(
              series.error?.message ?? 'Không tải được dữ liệu.',
              style: small.copyWith(color: Palette.white),
            )
          else ...[
            Row(
              children: [
                WeatherIcon.fromCode(
                  c.weatherCode,
                  isDay: isDayAt(
                    now,
                    lat: series.place.lat,
                    lon: series.place.lon,
                  ),
                  size: 28,
                ),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${units.tempNumber(c.temperature)}°',
                      style: TypeScale.bigValue.copyWith(color: Palette.white),
                    ),
                  ),
                ),
              ],
            ),
            metric(
              'Cảm giác',
              c.feelsLike == null
                  ? 'Chưa có'
                  : '${units.tempNumber(c.feelsLike!)}°',
            ),
            metric('Mưa 3 giờ tới', rain!.value, note: rain.note),
            metric('Gió', units.windText(c.windSpeed)),
            metric(
              'AQI (US)',
              c.usAqi == null ? 'Chưa có' : '${c.usAqi}',
              note: c.usAqi == null ? 'chưa có số liệu' : null,
            ),
          ],
          // Huy hieu + "Dữ liệu cũ" nam DUOI so lieu: cot co huy hieu
          // khong day hang so lieu xuong, cac cot van thang hang.
          if (badges.isNotEmpty) const SizedBox(height: Space.xs),
          for (final (icon, text, color) in badges)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      text,
                      style: small.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (series.result?.fromCache == true && c != null)
            Text('Dữ liệu cũ', style: small.copyWith(color: ink.warning)),
        ],
      ),
    );
  }
}
