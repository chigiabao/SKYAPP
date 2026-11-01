/// Bottom sheet chi tiet mot o va danh sach cac o.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/place.dart';
import '../../models/weather.dart';
import '../../providers/location_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/app_scene.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/weather_icons.dart';
import '../../ui/weather/widgets/bottom_pill_bar.dart' show showGlassSheet;
import '../../ui/weather/widgets/metric_tile.dart' show kNoData;
import '../../widgets/source_badge.dart' show SourceTag;
import '../map_screen.dart';
import '../../ui/weather/widgets/ios_list.dart';

Future<String?> showMapCellSheet(
  BuildContext context, {
  required MapCell cell,
  required LocationProvider locations,
  required WeatherProvider provider,
}) {
  final target = mapDetailTarget(locations, cell);
  return showGlassSheet<String>(
    context,
    title: mapCellNames(locations, cell),
    builder: (ctx) => CellSheet(
      cell: cell,
      provider: provider,
      placeNames: [
        for (final id in cell.locationIds) locations.placeById(id).name,
      ],
      stale: locations.cellsStale,
      onDetail: target == null ? null : () => Navigator.pop(ctx, target),
    ),
  );
}

Future<MapCell?> showMapCellList(
  BuildContext context, {
  required List<CellMarkerData> markers,
  required String Function(MapCell c) names,
}) => showGlassSheet<MapCell>(
  context,
  title: 'Các ô dữ liệu (${markers.length})',
  builder: (ctx) => CellListSheet(
    markers: markers,
    names: names,
    onPick: (c) => Navigator.pop(ctx, c),
  ),
);

/// Noi dung bottom sheet cua mot o.
class CellSheet extends StatelessWidget {
  const CellSheet({
    super.key,
    required this.cell,
    required this.provider,
    required this.placeNames,
    required this.stale,
    required this.onDetail,
  });

  final MapCell cell;
  final WeatherProvider provider;
  final List<String> placeNames;
  final bool stale;
  final VoidCallback? onDetail;

  @override
  Widget build(BuildContext context) {
    final c = cell;
    final body = TypeScale.body.copyWith(color: Palette.white);
    final secondary = TypeScale.footnote.copyWith(
      fontWeight: FontWeight.w500,
      color: Palette.secondary,
    );
    final outlook = outlookSourceLabel(c.outlookSource);
    final frameLabel = mapFrameLabel(
      c.source,
      c.validTime,
      observedAt: c.observedAt,
    );
    final units = PreferencesProvider.unitsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.source != null || frameLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: Wrap(
              spacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (c.source != null) SourceTag(source: c.source!),
                if (frameLabel != null) Text(frameLabel, style: secondary),
              ],
            ),
          ),
        Wrap(
          spacing: Space.m,
          runSpacing: Space.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            WeatherIcon.fromCode(
              c.weatherCode,
              isDay: isDayAt(
                c.source == DataSource.observed
                    ? c.observedAt ?? provider.nowHcm
                    : c.validTime ?? provider.nowHcm,
                lat: c.lat,
                lon: c.lon,
              ),
              size: 44,
            ),
            Text(
              c.temperature == null ? '--' : units.tempText(c.temperature!),
              style: TypeScale.bigValue.copyWith(color: Palette.white),
            ),
            Text(
              c.weatherCode == null ? kNoData : c.condition.description,
              style: body,
            ),
          ],
        ),
        const SizedBox(height: Space.m),
        // Chi hien hang co so lieu (an hang thieu thay vi ghi "Không có dữ liệu").
        if (c.windSpeed != null)
          _line(Icons.air_rounded, _cap(windText(c, units)), body),
        if (c.precipitation != null)
          _line(
            Icons.grain_rounded,
            'Lượng mưa trong giờ: ${units.rainText(c.precipitation)}',
            body,
          ),
        if (c.rainPercent != null)
          _line(
            Icons.water_drop_outlined,
            'Khả năng mưa 3 giờ tới: ${c.rainPercent}%',
            body,
          ),
        if (c.precipitation3h != null)
          _line(
            Icons.umbrella_outlined,
            'Lượng mưa 3 giờ tới: ${units.rainText(c.precipitation3h)}',
            body,
          ),
        if (outlook != null &&
            (c.rainPercent != null || c.precipitation3h != null))
          Padding(
            padding: const EdgeInsets.only(left: IconSizes.sm + 2 + Space.s),
            child: Text('Nguồn 3 giờ tới: $outlook', style: secondary),
          ),
        if (c.alert)
          _line(
            Icons.warning_amber_rounded,
            'Có cảnh báo mưa/dông trong ô này',
            body.copyWith(fontWeight: FontWeight.w600),
            color: Palette.alert,
          ),
        if (stale || c.isStaleAt(provider.nowHcm))
          _line(
            Icons.schedule_rounded,
            stale ? 'Đang dùng bản lưu trên máy' : 'Dữ liệu cũ',
            body,
            color: Palette.stale,
          ),
        const SizedBox(height: Space.m),
        Text(
          'CÁC PHƯỜNG, XÃ TRONG Ô',
          style: TypeScale.cardTitle.copyWith(color: Palette.title),
        ),
        const SizedBox(height: Space.xs),
        Text(placeNames.isEmpty ? kNoData : placeNames.join(', '), style: body),
        const SizedBox(height: Space.s),
        Text(kMapResolutionNote, style: secondary),
        const SizedBox(height: Space.l),
        if (onDetail != null)
          ElevatedButton.icon(
            onPressed: onDetail,
            iconAlignment: IconAlignment.end,
            icon: const Icon(CupertinoIcons.chevron_right),
            label: const Text('Xem chi tiết'),
          ),
      ],
    );
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _line(IconData icon, String text, TextStyle style, {Color? color}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: IconSizes.sm + 2, color: color ?? Palette.white),
            const SizedBox(width: Space.s),
            Expanded(child: Text(text, style: style)),
          ],
        ),
      );
}

/// Danh sach thay the cho diem danh dau (doc bang chu, ke ca huong gio).
class CellListSheet extends StatelessWidget {
  const CellListSheet({
    super.key,
    required this.markers,
    required this.names,
    required this.onPick,
  });

  final List<CellMarkerData> markers;
  final String Function(MapCell c) names;
  final ValueChanged<MapCell> onPick;

  @override
  Widget build(BuildContext context) {
    return IosListSection(
      margin: EdgeInsets.zero,
      dividerIndent: Space.l + 28 + Space.m,
      children: [
        for (final m in markers)
          IosListRow(
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: m.color,
              child: m.arrowAngle == null
                  ? null
                  : Transform.rotate(
                      key: const ValueKey('list-wind-arrow'),
                      angle: m.arrowAngle!,
                      child: const Icon(
                        Icons.navigation_rounded,
                        size: 16,
                        color: MapScale.ink,
                      ),
                    ),
            ),
            title: names(m.cell),
            subtitle: m.summary,
            trailing: Text(
              m.value,
              style: TypeScale.headline.copyWith(
                fontFeatures: TypeScale.tabular,
              ),
            ),
            chevron: true,
            semanticsLabel: '${names(m.cell)}, ${m.details}',
            onTap: () => onPick(m.cell),
          ),
      ],
    );
  }
}
