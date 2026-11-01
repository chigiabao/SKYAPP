import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../config/map_tiles.dart';
import '../../models/place.dart';
import '../../providers/location_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../map_screen.dart';
import 'map_legend.dart';

/// Cac lop ban do: nen OSM, ranh gioi, o mau, nhan / huy hieu, ghim dia diem.
List<Widget> mapLayers({
  required bool showTiles,
  required ErrorTileCallBack onTileError,
  Key? tileKey,
  required CityBoundary? boundary,
  required Animation<double> fade,
  required Color Function(String id, Color target) cellColor,
  required List<CellMarkerData> markers,
  required CellLabelMode mode,
  required double badge,
  required MapLayerKind layer,
  required LocationProvider lp,
  required List<MapCell> cells,
  required String? focus,
  required ValueChanged<String> onPlaceTap,
}) => [
  if (showTiles)
    TileLayer(
      key: tileKey,
      urlTemplate: kMapTileUrl,
      fallbackUrl: kMapTileFallbackUrl.isEmpty ? null : kMapTileFallbackUrl,
      userAgentPackageName: kMapTileUserAgent,
      maxNativeZoom: 19,
      errorTileCallback: onTileError,
    ),
  if (boundary != null)
    PolygonLayer(
      polygons: [
        for (final r in boundary.rings)
          Polygon(
            points: [for (final p in r) LatLng(p.$1, p.$2)],
            color: DataColors.boundaryFill,
            borderColor: DataColors.boundaryStroke,
            borderStrokeWidth: 2.5,
          ),
      ],
    ),
  AnimatedBuilder(
    animation: fade,
    builder: (context, _) => PolygonLayer(
      // O canh bao ve sau cung de vien cam nam tren cung.
      polygons: [
        for (final alert in [false, true])
          for (final m in markers)
            if (m.alert == alert)
              Polygon(
                points: cellRect(m.cell),
                color: cellColor(
                  m.cell.cellId,
                  m.color,
                ).withValues(alpha: kCellFillAlpha),
                // Vien manh, mo: ranh gioi o nhe, khong ke o vuong.
                borderColor: alert ? Palette.alert : DataColors.cellBorder,
                borderStrokeWidth: alert ? 2 : 0.5,
              ),
      ],
    ),
  ),
  MarkerLayer(
    markers: [
      if (mode != CellLabelMode.none)
        for (final m in markers)
          Marker(
            point: LatLng(m.cell.lat, m.cell.lon),
            width: kArrowMinPx,
            height: kArrowMinPx - 4,
            child: IgnorePointer(
              child: CellLabel(
                data: m,
                arrow: mode == CellLabelMode.valueArrow,
              ),
            ),
          ),
      for (final m in markers) ...[
        if (m.alert)
          Marker(
            point: LatLng(
              m.cell.lat + kCellDLat / 2,
              m.cell.lon + kCellDLon / 2,
            ),
            width: badge,
            height: badge,
            alignment: Alignment.bottomLeft,
            child: IgnorePointer(child: MapAlertBadge(size: badge)),
          ),
        if (layer == MapLayerKind.wind && m.strongGust)
          Marker(
            point: LatLng(
              m.cell.lat - kCellDLat / 2,
              m.cell.lon - kCellDLon / 2,
            ),
            width: badge,
            height: badge,
            alignment: Alignment.topRight,
            child: IgnorePointer(child: MapGustBadge(size: badge)),
          ),
      ],
    ],
  ),
  MarkerLayer(
    markers: [
      for (final e in lp.pages)
        if (lp.placeById(e.locationId) case final p
            when lp.hasPlaceList || !p.isDefault || cells.isEmpty)
          Marker(
            point: LatLng(p.lat, p.lon),
            // Vung cham 48dp; ghim 32dp nam o day (dau ghim tai diem).
            width: 48,
            height: 48,
            alignment: Alignment.topCenter,
            child: MapPlacePin(
              name: p.name,
              current: e.isCurrentLocation,
              focused: e.locationId == focus,
              onTap: () => onPlaceTap(e.locationId),
            ),
          ),
    ],
  ),
];
