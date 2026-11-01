/// Ban do thoi tiet TP.HCM: nen OpenStreetMap (flutter_map), ranh gioi thanh
/// pho, moi o luoi du lieu (~0.07 x 0.08 do) la mot hinh chu nhat to mau.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../providers/preferences_provider.dart';
import 'map/map_scale.dart';
import 'map/map_cells.dart';
import 'map/map_layers.dart';
import 'map/map_overlays.dart';
import 'map/map_legend.dart';
import 'map/cell_sheet.dart';

export 'map/map_scale.dart';
export 'map/map_cells.dart';
export 'map/map_overlays.dart' show MapTimeBar;
export 'map/map_legend.dart' show MapLegend, CellLabel;
export 'map/cell_sheet.dart' show CellSheet;

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.locations,
    this.focusLocationId,
    this.showTiles = true,
    this.onOpenPlace,
  });

  final LocationProvider locations;

  /// Tab Ban do: "Xem chi tiết" goi ham nay (chuyen ve tab Hom nay) thay vi
  /// pop man hinh; null -> pop tra ve id (khi duoc push).
  final ValueChanged<String>? onOpenPlace;

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
  int _tileGeneration = 0;

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

  void _onTileError(int generation) {
    if (_tilesFailed || generation != _tileGeneration) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _tileGeneration && !_tilesFailed) {
        setState(() => _tilesFailed = true);
      }
    });
  }

  String _cellNames(MapCell c) => mapCellNames(_lp, c);

  Future<void> _openCell(MapCell c) async {
    final picked = await showMapCellSheet(
      context,
      cell: c,
      locations: _lp,
      provider: context.read<WeatherProvider>(),
    );
    if (picked != null && mounted) _openPlace(picked);
  }

  void _openPlace(String id) {
    final open = widget.onOpenPlace;
    open != null ? open(id) : Navigator.pop(context, id);
  }

  /// Danh sach thay the cho diem danh dau (doc bang chu, ke ca huong gio).
  Future<void> _openList(List<CellMarkerData> markers) async {
    final picked = await showMapCellList(
      context,
      markers: markers,
      names: _cellNames,
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
    // Chi rebuild khi don vi, che do xem lai hoac moc gio thay doi.
    final (isReplay, replayAt, base) = context
        .select<WeatherProvider, (bool, DateTime?, DateTime)>(
          (p) => (p.isReplay, p.replayAt, HcmTime.startOfHour(p.nowHcm)),
        );
    final units = PreferencesProvider.unitsOf(context);
    final mq = MediaQuery.of(context);
    final cells = _lp.cells;
    final markers = buildCellMarkers(
      cells,
      _layer,
      temp: units.tempNumber,
      names: (c) => _cellNames(c),
      units: units,
    );
    _retarget(markers, mq.disableAnimations);
    final boundary = _lp.boundary;
    final tileGeneration = _tileGeneration;
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
          bounds: kMapCityBounds,
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
      children: mapLayers(
        showTiles: widget.showTiles,
        tileKey: ValueKey(tileGeneration),
        onTileError: (_, _, _) => _onTileError(tileGeneration),
        boundary: boundary,
        fade: _fade,
        cellColor: _cellColor,
        markers: markers,
        mode: mode,
        badge: badge,
        layer: _layer,
        lp: _lp,
        cells: cells,
        focus: focus,
        onPlaceTap: _openPlace,
      ),
    );

    final first = cells.isEmpty ? null : cells.first;
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
            // Thong bao xep ngay duoi nhan trang thai (khong chong len khi
            // nhan xuong dong o man hep / rong).
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MapTopBar(
                  layer: _layer,
                  onLayer: (l) => setState(() => _layer = l),
                  loading: _lp.mapLoading,
                  onRefresh: () {
                    setState(() {
                      _tilesFailed = false;
                      _tileGeneration++;
                    });
                    _lp.refreshMap(at: isReplay ? replayAt : null);
                  },
                  onList: cells.isEmpty ? null : () => _openList(markers),
                  chips: mapStatusChips(
                    cells: cells,
                    isReplay: isReplay,
                    replayAt: replayAt,
                    lp: _lp,
                    nowHcm: context.read<WeatherProvider>().nowHcm,
                  ),
                ),
                if (_tilesFailed || cells.isEmpty && !_lp.mapLoading) ...[
                  const SizedBox(height: Space.s),
                  MapMessageCard(
                    messages: mapMessages(
                      tilesFailed: _tilesFailed,
                      cells: cells,
                      lp: _lp,
                    ),
                  ),
                ],
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
                  base: base,
                  locked: isReplay,
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
                    units.tempNumber,
                    units,
                    _layer == MapLayerKind.temperature
                        ? MapScale.tempRange(cells)
                        : null,
                  ),
                  outlookSource: first?.outlookSource,
                  hasMissing: markers.any((m) => m.color == MapScale.noData),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
