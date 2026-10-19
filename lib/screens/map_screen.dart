/// Ban do thoi tiet TP.HCM: nen OpenStreetMap (flutter_map), ranh gioi thanh
/// pho, moi o luoi du lieu (~0.07 x 0.08 do) la mot hinh chu nhat to mau.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/units.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/weather_icons.dart';
import '../ui/weather/widgets/bottom_pill_bar.dart' show showGlassSheet;
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/metric_tile.dart' show kNoData;
import '../utils/formatters.dart';
import '../providers/preferences_provider.dart';
import '../widgets/source_badge.dart' show SourceTag;

/// Lop hien thi tren ban do.
enum MapLayerKind { temperature, rain, wind }

extension MapLayerText on MapLayerKind {
  String get label => switch (this) {
    MapLayerKind.temperature => 'Nhiệt độ',
    MapLayerKind.rain => 'Mưa',
    MapLayerKind.wind => 'Gió',
  };

  IconData get icon => switch (this) {
    MapLayerKind.temperature => Icons.thermostat_rounded,
    MapLayerKind.rain => Icons.water_drop_outlined,
    MapLayerKind.wind => Icons.air_rounded,
  };
}

/// Goc xoay (radian, chieu kim dong ho tu huong Bac) cua mui ten gio.
/// [fromDeg] la huong gio THOI TU -> mui ten chi huong thoi TOI (+180 do).
double windArrowAngle(double fromDeg) =>
    ((fromDeg + 180) % 360) * math.pi / 180;

/// Gio giat tu nguong nay (km/h) duoc nhan manh.
const double kStrongGustKmh = 50;

const List<String> _weekdays = [
  'thứ Hai',
  'thứ Ba',
  'thứ Tư',
  'thứ Năm',
  'thứ Sáu',
  'thứ Bảy',
  'Chủ nhật',
];

String _hm(DateTime t) => DateFormat('HH:mm').format(t);

/// "18:00 thứ Bảy 17/10" (gio TP.HCM).
String mapClockLabel(DateTime t) =>
    '${_hm(t)} ${_weekdays[t.weekday - 1]} ${DateFormat('dd/MM').format(t)}';

/// Nhan khung tren ban do, vd "Thực tế (dữ liệu phân tích) lúc 15:00",
/// "Dự báo lúc 18:00 thứ Bảy". null neu khong co thoi diem.
String? mapFrameLabel(DataSource? source, DateTime? valid) {
  if (valid == null) return null;
  return switch (source) {
    DataSource.observed => 'Thực tế (dữ liệu phân tích) lúc ${_hm(valid)}',
    DataSource.forecast =>
      'Dự báo lúc ${_hm(valid)} ${_weekdays[valid.weekday - 1]}',
    DataSource.ai =>
      'Dự báo AI lúc ${_hm(valid)} ${_weekdays[valid.weekday - 1]}',
    _ => 'Dữ liệu lúc ${_hm(valid)} ${_weekdays[valid.weekday - 1]}',
  };
}

/// Nguon phan "3 gio toi" theo `outlook_source`.
String? outlookSourceLabel(String? s) => switch (s) {
  'forecast' => 'Dự báo Open-Meteo',
  'ai' => 'Dự báo AI Sky Weather',
  _ => null,
};

/// Nhan offset: "Bây giờ", "+3 giờ".
String offsetLabel(int h) => h == 0 ? 'Bây giờ' : '+$h giờ';

/// Mo ta gio bang chu (danh sach thay the / Semantics).
String windText(MapCell c, [UnitPrefs units = const UnitPrefs()]) {
  if (c.windSpeed == null) return 'gió không có dữ liệu';
  final b = StringBuffer('gió ${units.windText(c.windSpeed)}');
  if (c.windDirection != null) {
    b.write(
      ', thổi từ hướng ${WeatherFormat.compass(c.windDirection)} '
      'về hướng ${WeatherFormat.compass(c.windDirection! + 180)}',
    );
  }
  if (c.windGusts != null) {
    b.write(', giật ${units.windText(c.windGusts)}');
    if (c.windGusts! >= kStrongGustKmh) b.write(' (giật mạnh)');
  }
  return b.toString();
}

/// Mot muc chu giai: mau + nhan (khong chi dua vao mau).
@immutable
class LegendEntry {
  const LegendEntry(this.color, this.label);
  final Color color;
  final String label;
}

/// Thang mau theo gia tri cua lop (dung chung cho diem danh dau va chu giai).
abstract final class MapScale {
  /// Nguong nhiet do (do C): < 24, 24-27, 27-30, 30-33, >= 33.
  static const List<double> tempSteps = [24, 27, 30, 33];
  static const List<Color> tempColors = [
    Palette.tempCool,
    Palette.tempMild,
    Palette.tempWarm,
    Palette.tempHot,
    Palette.tempVeryHot,
  ];

  /// Nguong kha nang mua (%): < 20, 20-40, 40-60, 60-80, >= 80.
  static const List<int> rainSteps = [20, 40, 60, 80];
  static const List<Color> rainColors = [
    Color(0xFFE0F2FE),
    Color(0xFFBAE6FD),
    Color(0xFF7DD3FC),
    Color(0xFF38BDF8),
    Color(0xFF0EA5E9),
  ];

  /// Nguong gio (km/h): < 10, 10-20, 20-30, 30-40, >= 40.
  static const List<int> windSteps = [10, 20, 30, 40];
  static const List<Color> windColors = [
    Color(0xFFE2E8F0),
    Color(0xFFA7F3D0),
    Color(0xFFFDE68A),
    Color(0xFFFDBA74),
    Color(0xFFFCA5A5),
  ];

  /// Nhan gio giat manh.
  static const Color gust = Color(0xFFB91C1C);

  static const Color noData = Color(0xFFCBD5E1);

  /// Chu tren nen mau sang.
  static const Color ink = Palette.onAlert;

  static Color forTemp(double? c) {
    if (c == null) return noData;
    var i = 0;
    while (i < tempSteps.length && c >= tempSteps[i]) {
      i++;
    }
    return tempColors[i];
  }

  /// Khoang nhiet do (min, max) cua khung dang xem; null = khong co du lieu.
  static (double, double)? tempRange(Iterable<MapCell> cells) {
    double? lo, hi;
    for (final c in cells) {
      final t = c.temperature;
      if (t == null) continue;
      lo = lo == null || t < lo ? t : lo;
      hi = hi == null || t > hi ? t : hi;
    }
    return lo == null ? null : (lo, hi!);
  }

  /// Mau tuong doi: [lo] -> mau mat nhat, [hi] -> nong nhat, noi suy muot
  /// giua 5 moc. Khoang < 1 do thi mo rong quanh trung binh (tranh phong dai
  /// chenh lech nho thanh do / xanh).
  static Color forTempIn(double? c, double lo, double hi) {
    if (c == null) return noData;
    final mid = (lo + hi) / 2;
    final half = math.max((hi - lo) / 2, 0.5);
    final t = ((c - (mid - half)) / (2 * half)).clamp(0.0, 1.0);
    final x = t * (tempColors.length - 1);
    final i = x.floor().clamp(0, tempColors.length - 2);
    return Color.lerp(tempColors[i], tempColors[i + 1], x - i)!;
  }

  static Color forRain(int? percent) {
    if (percent == null) return noData;
    var i = 0;
    while (i < rainSteps.length && percent >= rainSteps[i]) {
      i++;
    }
    return rainColors[i];
  }

  static Color forWind(double? kmh) {
    if (kmh == null) return noData;
    var i = 0;
    while (i < windSteps.length && kmh >= windSteps[i]) {
      i++;
    }
    return windColors[i];
  }

  static Color colorFor(
    MapLayerKind layer,
    MapCell c, [
    (double, double)? range,
  ]) => switch (layer) {
    MapLayerKind.temperature =>
      range == null
          ? forTemp(c.temperature)
          : forTempIn(c.temperature, range.$1, range.$2),
    MapLayerKind.rain => forRain(c.rainPercent),
    MapLayerKind.wind => forWind(c.windSpeed),
  };

  /// Chu giai cua lop. [temp] doi do C sang don vi dang chon.
  static List<LegendEntry> legend(
    MapLayerKind layer,
    String Function(double c) temp, [
    UnitPrefs units = const UnitPrefs(),
    (double, double)? range,
  ]) {
    if (layer == MapLayerKind.temperature && range != null) {
      // Thang tuong doi: nhan la nhiet do that tai tung moc.
      final (lo, hi) = range;
      final mid = (lo + hi) / 2;
      final half = math.max((hi - lo) / 2, 0.5);
      final n = tempColors.length - 1;
      return [
        for (var i = 0; i <= n; i++)
          LegendEntry(tempColors[i], '${temp(mid - half + 2 * half * i / n)}°'),
      ];
    }
    if (layer == MapLayerKind.temperature) {
      final s = tempSteps;
      return [
        LegendEntry(tempColors[0], '< ${temp(s[0])}°'),
        for (var i = 1; i < s.length; i++)
          LegendEntry(tempColors[i], '${temp(s[i - 1])}–${temp(s[i])}°'),
        LegendEntry(tempColors.last, '≥ ${temp(s.last)}°'),
      ];
    }
    if (layer == MapLayerKind.wind) {
      final w = windSteps;
      // Nguong tinh theo km/h; nhan theo don vi dang chon.
      String v(num x) => units.windParts(x.toDouble()).value;
      return [
        LegendEntry(windColors[0], '< ${units.windText(w[0].toDouble())}'),
        for (var i = 1; i < w.length; i++)
          LegendEntry(windColors[i], '${v(w[i - 1])}–${v(w[i])}'),
        LegendEntry(windColors.last, '≥ ${v(w.last)}'),
      ];
    }
    final s = rainSteps;
    return [
      LegendEntry(rainColors[0], '< ${s[0]}%'),
      for (var i = 1; i < s.length; i++)
        LegendEntry(rainColors[i], '${s[i - 1]}–${s[i]}%'),
      LegendEntry(rainColors.last, '≥ ${s.last}%'),
    ];
  }
}

/// Du lieu mot diem danh dau (tach khoi widget de kiem thu).
@immutable
class CellMarkerData {
  const CellMarkerData({
    required this.cell,
    required this.value,
    required this.color,
    required this.semantics,
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
  return [
    for (final c in cells)
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
        semantics: [
          names?.call(c) ?? 'Ô ${c.cellId}',
          c.temperature == null
              ? 'nhiệt độ không có dữ liệu'
              : 'nhiệt độ ${temp(c.temperature!)} độ',
          c.rainPercent == null
              ? 'khả năng mưa không có dữ liệu'
              : 'khả năng mưa 3 giờ tới ${c.rainPercent}%',
          windText(c, units),
          if (c.alert) 'có cảnh báo mưa dông',
        ].join(', '),
      ),
  ];
}

/// Ghi chu ve do phan giai (trung thuc ve du lieu).
const String kMapResolutionNote =
    'Mỗi ô ≈ 8 km; các phường trong cùng ô dùng chung dữ liệu';

const String kOsmAttribution = '© OpenStreetMap contributors';

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
const Color kLabelDark = Color(0xFF000000);

/// Nen ban do khi khong co tile (o duoc tron len nen nay).
const Color kMapBase = Color(0xFF1B2333);

/// Mau o sau khi tron do mo len nen toi.
Color cellFillOnBase(Color c) =>
    Color.alphaBlend(c.withValues(alpha: kCellFillAlpha), kMapBase);

/// Khung nhin mac dinh: phan dat lien TP.HCM moi (bao cac o luoi, khong gom
/// Con Dao - keo ban do hoac dung danh sach de toi).
final LatLngBounds _cityBounds = LatLngBounds(
  const LatLng(10.33, 106.37),
  const LatLng(11.46, 107.58),
);

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.locations,
    this.focusLocationId,
    this.showTiles = true,
  });

  final LocationProvider locations;

  /// Dia diem dang xem o Home (danh dau rieng).
  final String? focusLocationId;

  /// Tat lop nen OSM (test).
  final bool showTiles;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  /// Chuyen mau o giua cac khung (300 ms; tat khi giam chuyen dong).
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 1,
  );
  Map<String, Color> _fromColors = const {};
  Map<String, Color> _toColors = const {};

  MapLayerKind _layer = MapLayerKind.rain;
  bool _tilesFailed = false;

  /// Chieu rong o tren man hinh (px) theo zoom hien tai.
  double _cellPx = 0;
  DateTime? _requestedAt;
  bool _requested = false;

  /// Offset dang keo (chua tai); null = theo provider.
  int? _dragOffset;
  Timer? _debounce;
  Timer? _play;
  final MapController _map = MapController();

  LocationProvider get _lp => widget.locations;

  int get _shownOffset => _dragOffset ?? _lp.mapOffset;

  @override
  void dispose() {
    _debounce?.cancel();
    _play?.cancel();
    _fade.dispose();
    _map.dispose();
    super.dispose();
  }

  /// Keo slider: cap nhat nhan ngay, tai khung sau 300 ms (debounce).
  Color _cellColor(String id, Color target) {
    final from = _fromColors[id];
    if (from == null || _fade.value >= 1) return target;
    return Color.lerp(from, target, Motion.enter.transform(_fade.value))!;
  }

  /// Doi khung / lop: bat dau tween tu mau dang hien sang mau moi.
  void _retarget(List<CellMarkerData> markers, bool reduceMotion) {
    final next = {for (final m in markers) m.cell.cellId: m.color};
    if (mapEquals(next, _toColors)) return;
    _fromColors = {
      for (final e in _toColors.entries) e.key: _cellColor(e.key, e.value),
    };
    _toColors = next;
    if (reduceMotion || _fromColors.isEmpty) {
      _fade.value = 1;
    } else {
      _fade.forward(from: 0);
    }
  }

  void _onSlide(int h) {
    _stopPlay();
    setState(() => _dragOffset = h);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _lp.setMapOffset(h);
    });
  }

  void _onSlideEnd(int h) {
    _debounce?.cancel();
    _lp.setMapOffset(h);
    setState(() => _dragOffset = null);
  }

  void _stopPlay() {
    if (_play == null) return;
    _play!.cancel();
    _play = null;
    if (mounted) setState(() {});
  }

  /// Tu chay qua cac gio (khong dung khi giam chuyen dong).
  void _togglePlay() {
    if (_play != null) return _stopPlay();
    if (_lp.mapOffset >= _lp.mapMaxOffset) _lp.setMapOffset(0);
    _play = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) return _stopPlay();
      if (_lp.mapLoading) return;
      final next = _lp.mapOffset + 1;
      if (next > _lp.mapMaxOffset) return _stopPlay();
      _lp.setMapOffset(next);
    });
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wp = context.read<WeatherProvider>();
    final at = wp.isReplay ? wp.replayAt : null;
    if (!_requested || at != _requestedAt) {
      _requested = true;
      if (at != null) {
        _play?.cancel();
        _play = null;
      }
      _requestedAt = at;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _lp.refreshMap(at: at);
      });
    }
  }

  /// Cap nhat kich thuoc o (px) khi zoom; chi rebuild khi qua nguong nhan
  /// hoac co huy hieu doi buc (khong rebuild moi khung hinh).
  void _onCamera(MapCamera camera, bool _) {
    final px = cellPixelWidth(camera.zoom);
    if (_bucket(px) != _bucket(_cellPx)) setState(() => _cellPx = px);
  }

  static int _bucket(double px) => px < 20
      ? 0
      : px < kLabelMinPx
      ? 1
      : px < kArrowMinPx
      ? 2
      : 3;

  void _onMapTap(TapPosition _, LatLng p) {
    final c = cellAt(_lp.cells, p);
    if (c != null) _openCell(c);
  }

  void _onTileError(TileImage tile, Object error, StackTrace? st) {
    if (_tilesFailed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _tilesFailed = true);
    });
  }

  String _cellNames(MapCell c, {int max = 2}) {
    final names = [for (final id in c.locationIds) _lp.placeById(id).name];
    if (names.isEmpty) return 'Ô ${c.cellId}';
    if (names.length <= max) return names.join(', ');
    return '${names.take(max).join(', ')} và ${names.length - max} nơi khác';
  }

  /// "Xem chi tiết": dia diem da luu nam trong o, neu khong co thi dia diem
  /// gan tam o nhat.
  String? _detailTarget(MapCell c) {
    for (final s in _lp.saved) {
      if (c.locationIds.contains(s.locationId)) return s.locationId;
    }
    final gps = _lp.currentLocationId;
    if (gps != null && c.locationIds.contains(gps)) return gps;
    final inCell = [for (final id in c.locationIds) _lp.placeById(id)];
    return nearestPlace(inCell, c.lat, c.lon)?.id;
  }

  Future<void> _openCell(MapCell c) async {
    final wp = context.read<WeatherProvider>();
    final target = _detailTarget(c);
    final picked = await showGlassSheet<String>(
      context,
      title: _cellNames(c),
      builder: (ctx) => CellSheet(
        cell: c,
        provider: wp,
        placeNames: [for (final id in c.locationIds) _lp.placeById(id).name],
        stale: _lp.cellsStale,
        onDetail: target == null ? null : () => Navigator.pop(ctx, target),
      ),
    );
    if (picked != null && mounted) Navigator.pop(context, picked);
  }

  /// Danh sach thay the cho diem danh dau (doc bang chu, ke ca huong gio).
  Future<void> _openList(List<CellMarkerData> markers) async {
    final picked = await showGlassSheet<MapCell>(
      context,
      title: 'Các ô dữ liệu (${markers.length})',
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in markers)
              MergeSemantics(
                child: ListTile(
                  minTileHeight: Touch.min,
                  contentPadding: EdgeInsets.zero,
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
                  title: Text(
                    _cellNames(m.cell),
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                  subtitle: Text(
                    m.semantics.split(', ').skip(1).join(', '),
                    style: TypeScale.small.copyWith(color: Palette.secondary),
                  ),
                  onTap: () => Navigator.pop(ctx, m.cell),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _openCell(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scene = AppScene.of(context);
    final appTheme = Theme.of(context);
    return AppThemeScope(
      theme: AppThemeScope.maybeOf(context) ?? appTheme,
      child: Theme(
        data: glassThemeFor(scene.theme, appTheme),
        child: ListenableBuilder(
          listenable: _lp,
          builder: (context, _) => _build(context),
        ),
      ),
    );
  }

  Widget _build(BuildContext context) {
    final wp = context.watch<WeatherProvider>();
    final mq = MediaQuery.of(context);
    String temp(double c) => wp.formatTempValue(c);
    final cells = _lp.cells;
    final markers = buildCellMarkers(
      cells,
      _layer,
      temp: temp,
      names: (c) => _cellNames(c),
      units: PreferencesProvider.unitsOf(context),
    );
    _retarget(markers, mq.disableAnimations);
    final boundary = _lp.boundary;
    final focus = widget.focusLocationId;
    final mode = labelModeFor(_cellPx, _layer);
    final badge = switch (_bucket(_cellPx)) {
      0 => 10.0,
      1 => 12.0,
      _ => 16.0,
    };

    final map = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: _cityBounds,
          padding: EdgeInsets.fromLTRB(
            8,
            mq.padding.top + 150,
            8,
            mq.padding.bottom + 250,
          ),
        ),
        minZoom: 7,
        maxZoom: 16,
        backgroundColor: kMapBase,
        onPositionChanged: _onCamera,
        onMapReady: () => _onCamera(_map.camera, false),
        onTap: _onMapTap,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        if (widget.showTiles)
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.skyweather.app',
            maxNativeZoom: 19,
            errorTileCallback: _onTileError,
          ),
        if (boundary != null)
          PolygonLayer(
            polygons: [
              for (final r in boundary.rings)
                Polygon(
                  points: [for (final p in r) LatLng(p.$1, p.$2)],
                  color: const Color(0x14FFFFFF),
                  borderColor: const Color(0xE60B3A66),
                  borderStrokeWidth: 2.5,
                ),
            ],
          ),
        AnimatedBuilder(
          animation: _fade,
          builder: (context, _) => PolygonLayer(
            // O canh bao ve sau cung de vien cam nam tren cung.
            polygons: [
              for (final alert in [false, true])
                for (final m in markers)
                  if (m.alert == alert)
                    Polygon(
                      points: cellRect(m.cell),
                      color: _cellColor(
                        m.cell.cellId,
                        m.color,
                      ).withValues(alpha: kCellFillAlpha),
                      // Vien manh, mo: ranh gioi o nhe, khong ke o vuong.
                      borderColor: alert
                          ? Palette.alert
                          : const Color(0x1FFFFFFF),
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
                  child: IgnorePointer(child: _AlertBadge(size: badge)),
                ),
              if (_layer == MapLayerKind.wind && m.strongGust)
                Marker(
                  point: LatLng(
                    m.cell.lat - kCellDLat / 2,
                    m.cell.lon - kCellDLon / 2,
                  ),
                  width: badge,
                  height: badge,
                  alignment: Alignment.topRight,
                  child: IgnorePointer(child: _GustBadge(size: badge)),
                ),
            ],
          ],
        ),
        MarkerLayer(
          markers: [
            for (final e in _lp.pages)
              if (_lp.placeById(e.locationId) case final p
                  when _lp.hasPlaceList || !p.isDefault || cells.isEmpty)
                Marker(
                  point: LatLng(p.lat, p.lon),
                  // Vung cham 48dp; ghim 32dp nam o day (dau ghim tai diem).
                  width: 48,
                  height: 48,
                  alignment: Alignment.topCenter,
                  child: _PlacePin(
                    name: p.name,
                    current: e.isCurrentLocation,
                    focused: e.locationId == focus,
                    onTap: () => Navigator.pop(context, e.locationId),
                  ),
                ),
          ],
        ),
      ],
    );

    final first = cells.isEmpty ? null : cells.first;
    final frameLabel = mapFrameLabel(first?.source, first?.validTime);
    final reduceMotion = mq.disableAnimations;
    if (reduceMotion && _play != null) {
      _play!.cancel();
      _play = null;
    }
    final topPad = mq.padding.top + Space.s;
    return Scaffold(
      backgroundColor: kMapBase,
      body: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              container: true,
              label:
                  'Bản đồ ${_layer.label.toLowerCase()} TP.HCM, '
                  '${cells.length} ô dữ liệu. Chạm vào một ô để xem chi tiết; '
                  'nút Xem dạng danh sách đọc toàn bộ các ô.',
              child: map,
            ),
          ),
          Positioned(
            left: Space.m,
            right: Space.m,
            top: topPad,
            child: _TopBar(
              layer: _layer,
              onLayer: (l) => setState(() => _layer = l),
              loading: _lp.mapLoading,
              onRefresh: () =>
                  _lp.refreshMap(at: wp.isReplay ? wp.replayAt : null),
              onList: cells.isEmpty ? null : () => _openList(markers),
              chips: [
                if (frameLabel != null)
                  Semantics(
                    liveRegion: true,
                    child: GlassPill(
                      icon: first?.source == DataSource.observed
                          ? Icons.fact_check_outlined
                          : Icons.schedule_rounded,
                      label: frameLabel,
                    ),
                  ),
                if (wp.isReplay)
                  GlassPill(
                    icon: Icons.history_rounded,
                    label:
                        'Xem lại ${DateFormat('dd/MM HH:mm').format(wp.replayAt!)}',
                  ),
                if (_lp.cellsStale && cells.isNotEmpty)
                  GlassPill(
                    icon: Icons.schedule_rounded,
                    iconColor: Palette.stale,
                    label: _lp.cellsSavedAt == null
                        ? 'Dữ liệu cũ'
                        : 'Dữ liệu cũ · ${DateFormat('HH:mm dd/MM').format(_lp.cellsSavedAt!)}',
                  ),
              ],
            ),
          ),
          if (_tilesFailed || cells.isEmpty && !_lp.mapLoading)
            Positioned(
              left: Space.m,
              right: Space.m,
              top: topPad + 128,
              child: _MessageCard(
                messages: [
                  if (_tilesFailed)
                    'Mất bản đồ nền; dữ liệu thời tiết vẫn hiển thị.',
                  if (cells.isEmpty && !_lp.mapLoading)
                    _lp.mapError == ApiErrorKind.notFound
                        ? 'Máy chủ chưa hỗ trợ dữ liệu bản đồ.'
                        : _lp.mapError != null
                        ? 'Không tải được dữ liệu bản đồ. '
                              '${ApiException.messageFor(_lp.mapError!)}'
                        : 'Chưa có dữ liệu bản đồ.',
                ],
              ),
            ),
          Positioned(
            left: Space.m,
            right: Space.m,
            bottom: mq.padding.bottom + Space.m,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MapTimeBar(
                  value: _shownOffset,
                  max: _lp.mapMaxOffset,
                  base: HcmTime.startOfHour(wp.nowHcm),
                  locked: wp.isReplay,
                  loading: _lp.mapLoading,
                  playing: _play != null,
                  reduceMotion: reduceMotion,
                  onChanged: _onSlide,
                  onChangeEnd: _onSlideEnd,
                  onTogglePlay: _togglePlay,
                ),
                const SizedBox(height: Space.s),
                MapLegend(
                  layer: _layer,
                  entries: MapScale.legend(
                    _layer,
                    temp,
                    PreferencesProvider.unitsOf(context),
                    _layer == MapLayerKind.temperature
                        ? MapScale.tempRange(cells)
                        : null,
                  ),
                  outlookSource: first?.outlookSource,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.layer,
    required this.onLayer,
    required this.loading,
    required this.onRefresh,
    required this.onList,
    required this.chips,
  });

  final MapLayerKind layer;
  final ValueChanged<MapLayerKind> onLayer;
  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback? onList;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassSurface(
          tint: Palette.sheetBase,
          radius: Radii.pill,
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Quay lại',
                onPressed: () => Navigator.maybePop(context),
              ),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Bản đồ',
                    textAlign: TextAlign.center,
                    style: TypeScale.label.copyWith(
                      color: Palette.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              GlassIconButton(
                icon: Icons.view_list_rounded,
                tooltip: 'Xem dạng danh sách',
                onPressed: onList,
              ),
              SizedBox.square(
                dimension: Touch.min,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : GlassIconButton(
                        icon: Icons.refresh_rounded,
                        tooltip: 'Làm mới',
                        onPressed: onRefresh,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s),
        GlassSurface(
          tint: Palette.sheetBase,
          radius: Radii.pill,
          padding: const EdgeInsets.all(Space.xs),
          child: SegmentedButton<MapLayerKind>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              minimumSize: WidgetStatePropertyAll(Size(0, Touch.min - 8)),
            ),
            segments: [
              for (final l in MapLayerKind.values)
                ButtonSegment(
                  value: l,
                  label: Text(l.label, maxLines: 1),
                  icon: Icon(l.icon, size: IconSizes.sm),
                ),
            ],
            selected: {layer},
            onSelectionChanged: (s) => onLayer(s.first),
          ),
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: Space.s),
          Wrap(spacing: Space.s, runSpacing: Space.xs, children: chips),
        ],
      ],
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: GlassSurface(
        tint: Palette.sheetBase,
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in messages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.cloud_off_outlined,
                      size: IconSizes.sm,
                      color: Palette.white,
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        m,
                        style: TypeScale.small.copyWith(
                          fontSize: 13,
                          color: Palette.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Thanh thoi gian 0..[max] gio (thay radar). Xem lai: khoa, chi hien loi
/// giai thich. Giam chuyen dong: tat nut tu chay.
class MapTimeBar extends StatelessWidget {
  const MapTimeBar({
    super.key,
    required this.value,
    required this.max,
    required this.base,
    required this.locked,
    required this.loading,
    required this.playing,
    required this.reduceMotion,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onTogglePlay,
  });

  final int value;
  final int max;

  /// Gio TP.HCM ung voi offset 0.
  final DateTime base;
  final bool locked;
  final bool loading;
  final bool playing;
  final bool reduceMotion;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final VoidCallback onTogglePlay;

  static const String lockedText =
      'Chế độ xem lại chỉ xem được thời điểm đã chọn';

  /// "+3 giờ, 18:00 thứ Bảy 17/10" (Semantics + nhan).
  String textFor(int h) =>
      '${offsetLabel(h)}, ${mapClockLabel(base.add(Duration(hours: h)))}';

  @override
  Widget build(BuildContext context) {
    final small = TypeScale.small.copyWith(color: Palette.white);
    if (locked) {
      return GlassSurface(
        tint: Palette.sheetBase,
        padding: const EdgeInsets.all(Space.m),
        child: Row(
          children: [
            const Icon(
              Icons.lock_clock_outlined,
              size: IconSizes.sm + 2,
              color: Palette.white,
            ),
            const SizedBox(width: Space.s),
            Expanded(child: Text(lockedText, style: small)),
          ],
        ),
      );
    }
    final v = value.clamp(0, max);
    final ticks = max <= 0 ? [0] : [for (var i = 0; i <= 3; i++) max * i ~/ 3];
    return GlassSurface(
      tint: Palette.sheetBase,
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.m, Space.s),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GlassIconButton(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: reduceMotion
                    ? 'Tự chạy đã tắt (giảm chuyển động)'
                    : playing
                    ? 'Dừng'
                    : 'Tự chạy qua các giờ',
                onPressed: reduceMotion || max <= 0 ? null : onTogglePlay,
              ),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  '${offsetLabel(v)} · '
                  '${mapClockLabel(base.add(Duration(hours: v)))}',
                  style: TypeScale.label.copyWith(
                    color: Palette.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: kTabular,
                  ),
                ),
              ),
              if (loading)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Palette.white,
              inactiveTrackColor: Palette.track,
              thumbColor: Palette.white,
              overlayColor: Palette.highlight,
              activeTickMarkColor: Colors.transparent,
              inactiveTickMarkColor: Colors.transparent,
            ),
            child: Slider(
              value: v.toDouble(),
              max: math.max(max, 1).toDouble(),
              divisions: math.max(max, 1),
              label: offsetLabel(v),
              semanticFormatterCallback: (d) => textFor(d.round()),
              onChanged: max <= 0 ? null : (d) => onChanged(d.round()),
              onChangeEnd: max <= 0 ? null : (d) => onChangeEnd(d.round()),
            ),
          ),
          // Moc gio dat dung vi tri tren ray slider (ray thut ~24dp).
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: SizedBox(
                height: MediaQuery.textScalerOf(context).scale(11) * 1.5,
                child: Stack(
                  children: [
                    for (final t in ticks)
                      Align(
                        alignment: Alignment(
                          max <= 0 ? -1 : -1 + 2 * t / max,
                          0,
                        ),
                        child: Text(
                          offsetLabel(t),
                          maxLines: 1,
                          style: small.copyWith(
                            fontSize: 11,
                            color: Palette.secondary,
                            fontFeatures: kTabular,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chu giai lop + ghi chu do phan giai + ghi cong OSM.
class MapLegend extends StatelessWidget {
  const MapLegend({
    super.key,
    required this.layer,
    required this.entries,
    this.outlookSource,
  });

  final MapLayerKind layer;
  final List<LegendEntry> entries;

  /// `outlook_source` cua khung (lop mua: ghi nguon "3 gio toi").
  final String? outlookSource;

  @override
  Widget build(BuildContext context) {
    final small = TypeScale.small.copyWith(color: Palette.white);
    return GlassSurface(
      tint: Palette.sheetBase,
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(switch (layer) {
            MapLayerKind.temperature =>
              'NHIỆT ĐỘ · MÀU THEO THẤP–CAO KHUNG NÀY',
            MapLayerKind.rain => 'KHẢ NĂNG MƯA 3 GIỜ TỚI',
            MapLayerKind.wind => 'GIÓ (KM/H) · MŨI TÊN CHỈ HƯỚNG GIÓ THỔI TỚI',
          }, style: TypeScale.cardTitle.copyWith(color: Palette.title)),
          if (layer == MapLayerKind.rain &&
              outlookSourceLabel(outlookSource) != null)
            Text(
              'Nguồn: ${outlookSourceLabel(outlookSource)}',
              style: small.copyWith(color: Palette.secondary),
            ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: Space.m,
            runSpacing: Space.xs,
            children: [
              for (final e in entries)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: e.color,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: Palette.white, width: 1),
                      ),
                    ),
                    const SizedBox(width: Space.xs),
                    Text(
                      e.label,
                      style: small.copyWith(fontFeatures: kTabular),
                    ),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 14,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.fromBorderSide(
                                BorderSide(color: Palette.alert, width: 2),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -5,
                          top: -5,
                          child: _AlertBadge(size: 10),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Text('Ô có cảnh báo mưa/dông', style: small),
                ],
              ),
              if (layer == MapLayerKind.wind)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _GustBadge(),
                    const SizedBox(width: Space.xs),
                    Text(
                      'Giật ≥ '
                      '${PreferencesProvider.unitsOf(context).windText(kStrongGustKmh)}',
                      style: small,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Space.s),
          Text(
            kMapResolutionNote,
            style: small.copyWith(color: Palette.secondary),
          ),
          const SizedBox(height: 2),
          Text(
            kOsmAttribution,
            style: small.copyWith(fontSize: 11, color: Palette.secondary),
          ),
        ],
      ),
    );
  }
}

/// Nhan tren o (chi ve khi o du rong): so + mui ten gio (lop gio). Mau chu
/// chon theo do sang nen o, them vien sang/toi nguoc mau de luon >= 4.5:1.
class CellLabel extends StatelessWidget {
  const CellLabel({super.key, required this.data, required this.arrow});

  final CellMarkerData data;
  final bool arrow;

  @override
  Widget build(BuildContext context) {
    final ink = labelInkFor(cellFillOnBase(data.color));
    final halo = ink == Palette.white ? kLabelDark : Palette.white;
    final shadows = [
      for (final o in const [
        Offset(1, 0),
        Offset(-1, 0),
        Offset(0, 1),
        Offset(0, -1),
      ])
        Shadow(color: halo, offset: o, blurRadius: 1.5),
    ];
    final angle = data.arrowAngle;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (arrow && angle != null)
              Transform.rotate(
                key: const ValueKey('wind-arrow'),
                angle: angle,
                child: Icon(
                  Icons.navigation_rounded,
                  size: 16,
                  color: ink,
                  shadows: shadows,
                ),
              ),
            Text(
              data.value,
              style: TextStyle(
                fontSize: 13,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: ink,
                shadows: shadows,
                fontFeatures: kTabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Huy hieu canh bao o goc tren-phai cua o.
class _AlertBadge extends StatelessWidget {
  const _AlertBadge({this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Palette.alert,
        shape: BoxShape.circle,
        border: Border.all(color: MapScale.ink, width: 1),
      ),
      child: Icon(
        Icons.priority_high_rounded,
        size: size * 0.7,
        color: Palette.onAlert,
      ),
    );
  }
}

/// Nhan gio giat manh (vien trang + nen do dam, icon >= 3:1).
class _GustBadge extends StatelessWidget {
  const _GustBadge({this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: MapScale.gust,
        shape: BoxShape.circle,
        border: Border.all(color: Palette.white, width: 1),
      ),
      child: Icon(Icons.air_rounded, size: size * 0.7, color: Palette.white),
    );
  }
}

class _PlacePin extends StatelessWidget {
  const _PlacePin({
    required this.name,
    required this.current,
    required this.focused,
    required this.onTap,
  });

  final String name;
  final bool current;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          '${current ? 'Vị trí hiện tại' : 'Địa điểm đã lưu'}: $name'
          '${focused ? ', đang xem' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox.square(
            dimension: 32,
            child: Icon(
              current ? Icons.near_me_rounded : Icons.location_on_rounded,
              size: 30,
              color: focused ? Palette.alert : Palette.white,
              shadows: const [Shadow(color: Color(0xAA000000), blurRadius: 4)],
            ),
          ),
        ),
      ),
    );
  }
}

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
    final secondary = TypeScale.small.copyWith(
      fontSize: 13,
      color: Palette.secondary,
    );
    final outlook = outlookSourceLabel(c.outlookSource);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.source != null || c.validTime != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: Wrap(
              spacing: Space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (c.source != null) SourceTag(source: c.source!),
                if (c.validTime != null)
                  Text('Lúc ${mapClockLabel(c.validTime!)}', style: secondary),
              ],
            ),
          ),
        Row(
          children: [
            WeatherIcon.fromCode(
              c.weatherCode,
              isDay: isDayAt(provider.nowHcm),
              size: 44,
            ),
            const SizedBox(width: Space.m),
            Text(
              c.temperature == null
                  ? '--'
                  : provider.formatTemperature(c.temperature!),
              style: TypeScale.bigValue.copyWith(color: Palette.white),
            ),
            const SizedBox(width: Space.m),
            Expanded(
              child: Text(
                c.weatherCode == null ? kNoData : c.condition.description,
                style: body,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.m),
        _line(
          Icons.air_rounded,
          _cap(windText(c, PreferencesProvider.unitsOf(context))),
          body,
        ),
        _line(
          Icons.grain_rounded,
          'Lượng mưa trong giờ: ${PreferencesProvider.unitsOf(context).rainText(c.precipitation)}',
          body,
        ),
        _line(
          Icons.water_drop_outlined,
          'Khả năng mưa 3 giờ tới: '
          '${c.rainPercent == null ? kNoData : '${c.rainPercent}%'}',
          body,
        ),
        _line(
          Icons.umbrella_outlined,
          'Lượng mưa 3 giờ tới: '
          '${c.precipitation3h == null ? kNoData : PreferencesProvider.unitsOf(context).rainText(c.precipitation3h)}',
          body,
        ),
        if (outlook != null)
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
        if (stale)
          _line(
            Icons.schedule_rounded,
            'Dữ liệu cũ (đang ngoại tuyến)',
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
            icon: const Icon(Icons.open_in_new_rounded),
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
