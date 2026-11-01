/// Du lieu diem danh dau, hinh hoc o luoi va mau nhan.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../config/map_tiles.dart';
import '../../models/place.dart';
import '../../models/data_source.dart';
import '../../models/units.dart';
import '../../providers/location_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../map_screen.dart';
import 'map_scale.dart';

/// Du lieu mot diem danh dau (tach khoi widget de kiem thu).
@immutable
class CellMarkerData {
  const CellMarkerData({
    required this.cell,
    required this.value,
    required this.color,
    required this.semantics,
    this.summary = '',
    this.details = '',
    this.arrowAngle,
  });

  final MapCell cell;

  /// Lop gio: goc mui ten (radian); null = khong ve mui ten.
  final double? arrowAngle;
  bool get strongGust => (cell.windGusts ?? 0) >= kStrongGustKmh;

  /// Gia tri hien tren diem ("31°", "45%", "--").
  final String value;
  final Color color;
  final String semantics;

  /// Tom tat ngan dung du lieu o ("30° · Mưa 18% · Gió 14 km/h"), cho danh
  /// sach o; KHONG cat tu [semantics] (ten phuong co the chua ", ").
  final String summary;

  /// [semantics] khong kem ten o (doc cho trinh doc man hinh sau ten).
  final String details;
  bool get alert => cell.alert;
}

/// Tao du lieu diem danh dau cho [layer].
List<CellMarkerData> buildCellMarkers(
  List<MapCell> cells,
  MapLayerKind layer, {
  required String Function(double c) temp,
  String Function(MapCell c)? names,
  UnitPrefs units = const UnitPrefs(),
}) {
  final range = layer == MapLayerKind.temperature
      ? MapScale.tempRange(cells)
      : null;
  final markers = <CellMarkerData>[];
  for (final c in cells) {
    final readingLabel = c.source == DataSource.observed
        ? mapFrameLabel(c.source, c.validTime, observedAt: c.observedAt)
        : null;
    final details = [
      ?readingLabel,
      c.temperature == null
          ? 'nhiệt độ không có dữ liệu'
          : 'nhiệt độ ${temp(c.temperature!)} độ',
      c.rainPercent == null
          ? 'khả năng mưa không có dữ liệu'
          : 'khả năng mưa 3 giờ tới ${c.rainPercent}%',
      windText(c, units),
      if (c.alert) 'có cảnh báo mưa dông',
    ].join(', ');
    markers.add(
      CellMarkerData(
        cell: c,
        value: switch (layer) {
          MapLayerKind.temperature =>
            c.temperature == null ? '--' : '${temp(c.temperature!)}°',
          MapLayerKind.rain =>
            c.rainPercent == null ? '--' : '${c.rainPercent}%',
          MapLayerKind.wind =>
            c.windSpeed == null ? '--' : '${c.windSpeed!.round()}',
        },
        color: MapScale.colorFor(layer, c, range),
        arrowAngle: layer == MapLayerKind.wind && c.windDirection != null
            ? windArrowAngle(c.windDirection!)
            : null,
        summary: [
          ?readingLabel,
          c.temperature == null ? '--°' : '${temp(c.temperature!)}°',
          'Mưa ${c.rainPercent == null ? '--' : '${c.rainPercent}%'}',
          'Gió ${units.windText(c.windSpeed)}',
          if (c.alert) 'Cảnh báo',
        ].join(' · '),
        details: details,
        semantics: '${names?.call(c) ?? 'Ô ${c.cellId}'}, $details',
      ),
    );
  }
  return markers;
}

/// Ghi chu ve do phan giai (trung thuc ve du lieu).
const String kMapResolutionNote =
    'Mỗi ô ≈ 8 km; các phường trong cùng ô dùng chung dữ liệu';

const String kOsmAttribution = kMapTileAttribution;

/// Kich thuoc o luoi Open-Meteo (do), do tu khoang cach tam o trong
/// backend/data/locations/cells.json: vi do ~0.0703, kinh do ~0.0795.
const double kCellDLat = 0.0703;
const double kCellDLon = 0.0795;

/// Do mo nen o (van thay ban do nen).
const double kCellFillAlpha = 0.58;

/// Nguong hien nhan theo chieu rong o tren man hinh (px).
const double kLabelMinPx = 36;
const double kArrowMinPx = 44;

/// 4 dinh hinh chu nhat cua o (tam o +- nua buoc luoi).
List<LatLng> cellRect(MapCell c) {
  const a = kCellDLat / 2, b = kCellDLon / 2;
  return [
    LatLng(c.lat + a, c.lon - b),
    LatLng(c.lat + a, c.lon + b),
    LatLng(c.lat - a, c.lon + b),
    LatLng(c.lat - a, c.lon - b),
  ];
}

/// O chua diem [p] (nhieu o thi lay o co tam gan nhat); null neu ngoai luoi.
MapCell? cellAt(Iterable<MapCell> cells, LatLng p) {
  MapCell? best;
  var bestD = double.infinity;
  for (final c in cells) {
    final dy = (p.latitude - c.lat).abs() / kCellDLat;
    final dx = (p.longitude - c.lon).abs() / kCellDLon;
    if (dy > 0.5 || dx > 0.5) continue;
    final d = dx * dx + dy * dy;
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// Chieu rong mot o (px) o muc zoom [zoom] (Web Mercator, 256 px/tile).
double cellPixelWidth(double zoom) => kCellDLon * 256 * math.pow(2, zoom) / 360;

/// Muc nhan tren o: khong (chi mau), so, so + mui ten gio.
enum CellLabelMode { none, value, valueArrow }

CellLabelMode labelModeFor(double px, MapLayerKind layer) {
  if (px < kLabelMinPx) return CellLabelMode.none;
  if (layer == MapLayerKind.wind && px >= kArrowMinPx) {
    return CellLabelMode.valueArrow;
  }
  return CellLabelMode.value;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Mau chu (trang hoac muc toi) tuong phan cao nhat tren nen [bg].
Color labelInkFor(Color bg) =>
    _contrast(kLabelDark, bg) >= _contrast(Palette.white, bg)
    ? kLabelDark
    : Palette.white;

/// Chu toi tren o (den: tuong phan cao nhat voi nen trung tinh).
const Color kLabelDark = DataColors.mapLabelDark;

/// Nen ban do khi khong co tile (o duoc tron len nen nay).
const Color kMapBase = DataColors.mapBase;

/// Mau o sau khi tron do mo len nen toi.
Color cellFillOnBase(Color c) =>
    Color.alphaBlend(c.withValues(alpha: kCellFillAlpha), kMapBase);

/// Khung nhin mac dinh: phan dat lien TP.HCM moi (bao cac o luoi, khong gom
/// Con Dao - keo ban do hoac dung danh sach de toi).
final LatLngBounds kMapCityBounds = LatLngBounds(
  const LatLng(10.33, 106.37),
  const LatLng(11.46, 107.58),
);

/// Ten cac dia diem trong o (toi da [max], con lai ghi "và N nơi khác").
String mapCellNames(LocationProvider lp, MapCell c, {int max = 2}) {
  final names = [for (final id in c.locationIds) lp.placeById(id).name];
  if (names.isEmpty) return 'Ô ${c.cellId}';
  if (names.length <= max) return names.join(', ');
  return '${names.take(max).join(', ')} và ${names.length - max} nơi khác';
}

/// "Xem chi tiết": dia diem da luu nam trong o, neu khong co thi dia diem
/// gan tam o nhat.
String? mapDetailTarget(LocationProvider lp, MapCell c) {
  for (final s in lp.saved) {
    if (c.locationIds.contains(s.locationId)) return s.locationId;
  }
  final gps = lp.currentLocationId;
  if (gps != null && c.locationIds.contains(gps)) return gps;
  final inCell = [for (final id in c.locationIds) lp.placeById(id)];
  return nearestPlace(inCell, c.lat, c.lon)?.id;
}
