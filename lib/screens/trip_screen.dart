/// Man "Chuyến đi" (nhom 6): chon diem den / phuong tien / gio di, xem tuyen
/// to mau theo thoi tiet, bat dau / tam dung / ket thuc, lich su.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/weather_alerts.dart';
import '../providers/location_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/trip_provider.dart';
import '../services/gps_service.dart';
import '../services/route_service.dart';
import '../services/trip_location.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';

/// Mau tung muc nguy hiem tren tuyen.
Color hazardColor(RouteHazard h) => switch (h) {
  RouteHazard.none => const Color(0xFF34D399),
  RouteHazard.rain => const Color(0xFFFACC15),
  RouteHazard.heavy => const Color(0xFFFB923C),
  RouteHazard.storm => const Color(0xFFEF4444),
};

/// Cac doan tuyen to mau theo diem mau gan nhat (dung chung cho ban do).
List<Polyline> routeWeatherPolylines(TripRoute r, {double width = 6}) {
  final g = r.geometry;
  if (g.length < 2) return const [];
  if (r.samples.isEmpty) {
    return [Polyline(points: g, color: Palette.rain, strokeWidth: width)];
  }
  final idx = [for (final s in r.samples) nearestIndex(g, s.point)];
  final out = <Polyline>[];
  for (var i = 0; i < r.samples.length; i++) {
    final a = i == 0 ? 0 : idx[i];
    final b = i == r.samples.length - 1 ? g.length - 1 : idx[i + 1];
    if (b <= a) continue;
    out.add(
      Polyline(
        points: g.sublist(a, b + 1),
        color: hazardColor(r.samples[i].hazard),
        strokeWidth: width,
        borderColor: const Color(0x99000000),
        borderStrokeWidth: 1.5,
      ),
    );
  }
  return out;
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _durationText(double min) {
  final m = min.round();
  return m < 60 ? '$m phút' : '${m ~/ 60} giờ ${m % 60} phút';
}

class TripScreen extends StatefulWidget {
  const TripScreen({
    super.key,
    required this.locations,
    this.gps = const GeolocatorGps(),
    this.showTiles = true,
  });

  final LocationProvider locations;
  final GpsService gps;

  /// Tat lop nen OSM (test).
  final bool showTiles;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  bool _withRoute = true;
  Place? _from; // null = GPS
  Place? _to;
  TripProfile _profile = TripProfile.driving;
  DateTime? _departAt; // null = bay gio
  bool _background = false;
  final _search = TextEditingController();
  List<Place> _results = const [];
  bool _searching = false;
  String? _message;

  /// Loi quyen / dinh vi tat -> hien nut "Mở cài đặt" (Android + iOS).
  GpsStatus? _gpsIssue;

  LocationProvider get _lp => widget.locations;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    final r = await _lp.searchRemote(q) ?? _lp.search(q);
    if (!mounted) return;
    setState(() {
      _results = r.take(8).toList();
      _searching = false;
    });
  }

  Future<void> _pickTime() async {
    final trip = context.read<TripProvider>();
    final now = trip.nowHcm;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: now.hour, minute: now.minute),
      builder: (c, child) => AppThemeScope.wrapDialog(c, child!),
    );
    if (t == null || !mounted) return;
    var at = DateTime.utc(now.year, now.month, now.day, t.hour, t.minute);
    if (at.isBefore(now)) at = at.add(const Duration(days: 1));
    setState(() => _departAt = at);
  }

  Future<void> _plan() async {
    final to = _to;
    if (to == null) return;
    final trip = context.read<TripProvider>();
    setState(() {
      _message = null;
      _gpsIssue = null;
    });
    LatLng from;
    if (_from != null) {
      from = LatLng(_from!.lat, _from!.lon);
    } else {
      final fix = await widget.gps.locate();
      if (!mounted) return;
      if (fix.status != GpsStatus.ok) {
        setState(() {
          _gpsIssue = fix.status;
          _message =
              fix.detail ??
              'Không lấy được vị trí hiện tại. Hãy chọn điểm đi là một địa '
                  'điểm.';
        });
        return;
      }
      from = LatLng(fix.lat!, fix.lon!);
    }
    final r = await trip.planRoute(
      from: from,
      to: LatLng(to.lat, to.lon),
      departAt: _departAt ?? trip.nowHcm,
      profile: _profile,
    );
    if (r != null) await trip.compareDepartures();
  }

  Future<void> _start() async {
    final trip = context.read<TripProvider>();
    if (_background && tripBackgroundSupported) {
      final ok = await _explainBackground();
      if (ok != true || !mounted) return;
    }
    final st = await trip.start(
      route: _withRoute ? trip.plan : null,
      fromId: _withRoute ? _from?.id : null,
      toId: _withRoute ? _to?.id : null,
      background: _background,
    );
    if (st != GpsStatus.ok && mounted) {
      setState(() {
        _gpsIssue = st;
        _message = trip.error;
      });
    }
  }

  /// Giai thich truoc khi he thong hoi quyen vi tri.
  Future<bool?> _explainBackground() => showDialog<bool>(
    context: context,
    builder: (c) => AppThemeScope.wrapDialog(
      c,
      AlertDialog(
        title: const Text('Theo dõi khi tắt màn hình'),
        content: const Text(
          'Để cảnh báo mưa, dông khi bạn khóa máy hoặc dùng ứng dụng khác, '
          'Sky Weather cần dùng vị trí trong lúc chuyến đi đang chạy. '
          'Hệ thống sẽ hỏi quyền vị trí; trên iOS thanh trạng thái hiện biểu '
          'tượng vị trí, trên Android có thông báo cố định. Chỉ cập nhật khi '
          'bạn đi thêm khoảng 500 m để tiết kiệm pin. Tọa độ không được lưu; '
          'theo dõi dừng ngay khi bạn bấm Kết thúc.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Tiếp tục'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final trip = context.watch<TripProvider>();
    if (trip.isRunning) return _DrivingView(trip: trip);
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;
    return Scaffold(
      appBar: AppBar(title: const Text('Chuyến đi')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
        children: [
          if (trip.phase == TripPhase.ended) ...[
            _EndedCard(trip: trip, locations: _lp),
            const SizedBox(height: Space.cardGap),
          ],
          _setupCard(context, trip),
          if (_withRoute && trip.plan != null) ...[
            const SizedBox(height: Space.cardGap),
            _RouteMap(route: trip.plan!, showTiles: widget.showTiles),
            const SizedBox(height: Space.cardGap),
            _RouteSummary(trip: trip),
          ],
          const SizedBox(height: Space.cardGap),
          _startCard(context, trip),
          const SizedBox(height: Space.cardGap),
          _HistoryCard(trip: trip, locations: _lp),
        ],
      ),
    );
  }

  Widget _setupCard(BuildContext context, TripProvider trip) {
    final ink = GlassInk.of(context);
    final saved = [
      for (final s in _lp.saved) (s.labelText, _lp.placeById(s.locationId)),
    ];
    return GlassCard(
      title: 'LÊN KẾ HOẠCH',
      icon: Icons.route_rounded,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Có tuyến đường')),
                ButtonSegment(value: false, label: Text('Không có tuyến')),
              ],
              selected: {_withRoute},
              onSelectionChanged: (s) => setState(() => _withRoute = s.first),
            ),
            const SizedBox(height: Space.s),
            if (!_withRoute)
              Text(
                'Kiểm tra thời tiết tại nơi bạn đang ở mỗi khi sang khu vực '
                'khác hoặc mỗi 15 phút.',
                style: TypeScale.body.copyWith(color: ink.secondary),
              )
            else ...[
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _from?.id ?? '',
                decoration: const InputDecoration(labelText: 'Điểm đi'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Vị trí hiện tại (GPS)'),
                  ),
                  for (final (label, p) in saved)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        label == null ? p.name : '$label · ${p.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) => setState(
                  () => _from = id == null || id.isEmpty
                      ? null
                      : _lp.placeById(id),
                ),
              ),
              const SizedBox(height: Space.s),
              if (_to != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.flag_rounded),
                  title: Text('Điểm đến: ${_to!.name}'),
                  trailing: IconButton(
                    tooltip: 'Đổi điểm đến',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      trip.clearPlan();
                      setState(() => _to = null);
                    },
                  ),
                )
              else ...[
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: 'Tìm điểm đến (phường, xã)',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  onSubmitted: _runSearch,
                ),
                for (final p in _results)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.name),
                    subtitle: p.region == null ? null : Text(p.region!),
                    onTap: () => setState(() {
                      _to = p;
                      _results = const [];
                    }),
                  ),
                if (_results.isEmpty && saved.isNotEmpty)
                  Wrap(
                    spacing: Space.s,
                    children: [
                      for (final (label, p) in saved)
                        ActionChip(
                          label: Text(label ?? p.name),
                          onPressed: () => setState(() => _to = p),
                        ),
                    ],
                  ),
              ],
              const SizedBox(height: Space.s),
              SegmentedButton<TripProfile>(
                segments: [
                  for (final p in TripProfile.values)
                    ButtonSegment(value: p, label: Text(p.label)),
                ],
                selected: {_profile},
                onSelectionChanged: (s) => setState(() => _profile = s.first),
              ),
              const SizedBox(height: Space.s),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _departAt == null
                          ? 'Khởi hành: bây giờ'
                          : 'Khởi hành: ${_hhmm(_departAt!)} '
                                '${_departAt!.day}/${_departAt!.month}',
                      style: TypeScale.body.copyWith(color: Palette.white),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _departAt = null),
                    child: const Text('Bây giờ'),
                  ),
                  TextButton(
                    onPressed: _pickTime,
                    child: const Text('Chọn giờ'),
                  ),
                ],
              ),
              const SizedBox(height: Space.s),
              FilledButton.icon(
                onPressed: _to == null || trip.planning ? null : _plan,
                icon: trip.planning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.alt_route_rounded),
                label: const Text('Xem tuyến và thời tiết'),
              ),
              if (trip.planError != null) ...[
                const SizedBox(height: Space.s),
                Text(
                  trip.planError!,
                  style: TypeScale.body.copyWith(color: Palette.stale),
                ),
              ],
            ],
            if (_message != null) ...[
              const SizedBox(height: Space.s),
              Text(
                _message!,
                style: TypeScale.body.copyWith(color: Palette.stale),
              ),
              if (!kIsWeb &&
                  _gpsIssue != null &&
                  _gpsIssue != GpsStatus.unavailable)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Mở cài đặt'),
                    onPressed: () => _gpsIssue == GpsStatus.serviceDisabled
                        ? widget.gps.openLocationSettings()
                        : widget.gps.openAppSettings(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _startCard(BuildContext context, TripProvider trip) {
    final ink = GlassInk.of(context);
    final canStart = !_withRoute || trip.plan != null;
    return GlassCard(
      title: 'THEO DÕI',
      icon: Icons.notifications_active_outlined,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Âm thanh thông báo'),
              subtitle: const Text(
                'Tắt để chỉ hiện thông báo ngắn, không kêu.',
              ),
              value: trip.sound,
              onChanged: trip.setSound,
            ),
            if (tripBackgroundSupported)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tiếp tục khi tắt màn hình'),
                subtitle: const Text(
                  'Theo dõi cả khi khóa máy; tốn pin hơn một chút.',
                ),
                value: _background,
                onChanged: (v) => setState(() => _background = v),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: Text(
                  kIsWeb
                      ? 'Trên trình duyệt, chỉ theo dõi khi tab này đang mở.'
                      : 'Thiết bị này chỉ theo dõi khi ứng dụng đang mở.',
                  style: TypeScale.body.copyWith(color: ink.secondary),
                ),
              ),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                onPressed: canStart ? _start : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 28),
                label: Text(
                  _withRoute
                      ? 'Bắt đầu theo tuyến'
                      : 'Bắt đầu (không có tuyến)',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
            const SizedBox(height: Space.s),
            Text(
              'Chỉ lưu trên máy: phường đi, phường đến, thời gian và cảnh báo. '
              'Không lưu đường đi GPS.',
              style: TypeScale.label.copyWith(color: ink.secondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ban do tuyen + marker doan xau nhat + attribution.
class _RouteMap extends StatelessWidget {
  const _RouteMap({required this.route, required this.showTiles});

  final TripRoute route;
  final bool showTiles;

  @override
  Widget build(BuildContext context) {
    final g = route.geometry;
    final worst = route.worstAlert;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: SizedBox(
        height: 280,
        child: g.length < 2
            ? const Center(child: Text('Không có dữ liệu hình tuyến.'))
            : FlutterMap(
                key: ValueKey(route),
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(g),
                    padding: const EdgeInsets.all(32),
                  ),
                ),
                children: [
                  if (showTiles)
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.sky_weather_app',
                      maxNativeZoom: 19,
                    ),
                  PolylineLayer(polylines: routeWeatherPolylines(route)),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: g.first,
                        child: const Icon(
                          Icons.trip_origin_rounded,
                          color: Colors.white,
                        ),
                      ),
                      Marker(
                        point: g.last,
                        child: const Icon(
                          Icons.flag_rounded,
                          color: Colors.white,
                        ),
                      ),
                      if (worst != null)
                        Marker(
                          point: worst.point,
                          width: 40,
                          height: 40,
                          child: Semantics(
                            label: 'Đoạn xấu nhất',
                            child: Icon(
                              Icons.warning_rounded,
                              size: 36,
                              color: hazardColor(worst.hazard),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      color: const Color(0xB3FFFFFF),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        route.attribution,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _RouteSummary extends StatelessWidget {
  const _RouteSummary({required this.trip});

  final TripProvider trip;

  @override
  Widget build(BuildContext context) {
    final r = trip.plan!;
    final ink = GlassInk.of(context);
    final units = PreferencesProvider.unitsOf(context);
    final worst = r.worstAlert;
    final better = trip.betterDeparture;
    final body = TypeScale.body.copyWith(color: Palette.white);
    String? suggestion;
    if (trip.comparing) {
      suggestion = 'Đang so sánh giờ đi sớm / muộn hơn…';
    } else if (better != null) {
      final m = better.offsetMin;
      suggestion =
          'Nên đi ${m < 0 ? 'sớm' : 'muộn'} hơn ${m.abs()} phút '
          '(${_hhmm(better.route.departAt)}): ít mưa, dông hơn trên đường.';
    } else if (trip.departOptions.isNotEmpty) {
      suggestion = 'Giờ đi đã chọn là tốt nhất trong khoảng ±60 phút.';
    }
    return GlassCard(
      title: 'TÓM TẮT TUYẾN',
      icon: Icons.summarize_outlined,
      footer: '${r.attribution}. $kAlertDisclaimer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${units.distanceText(r.distanceKm)} · ${_durationText(r.durationMin)}'
            ' · đến lúc ${_hhmm(r.arriveAt)}',
            style: body.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: Space.s),
          Text(
            worst == null
                ? 'Không có đoạn mưa lớn, dông hay gió giật trên tuyến.'
                : 'Đoạn xấu nhất: ${worst.alertReason ?? worst.hazard.label}'
                      ', lúc ${_hhmm(worst.eta)}.',
            style: body,
          ),
          if (suggestion != null) ...[
            const SizedBox(height: Space.s),
            Text(suggestion, style: body.copyWith(color: ink.secondary)),
          ],
          const SizedBox(height: Space.s),
          Wrap(
            spacing: Space.m,
            children: [
              for (final h in RouteHazard.values)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 14, height: 4, color: hazardColor(h)),
                    const SizedBox(width: 4),
                    Text(h.label, style: TypeScale.label),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Man dang di: toi gian, chu to, nut lon; khong can thao tac.
class _DrivingView extends StatelessWidget {
  const _DrivingView({required this.trip});

  final TripProvider trip;

  @override
  Widget build(BuildContext context) {
    final units = PreferencesProvider.unitsOf(context);
    final paused = trip.phase == TripPhase.paused;
    final alert = trip.lastAlert;
    final big = const TextStyle(
      color: Palette.white,
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.25,
    );
    final mid = const TextStyle(color: Palette.white, fontSize: 20);
    return Scaffold(
      backgroundColor: const Color(0xCC0B1220),
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
                child: const Text(
                  'Không thao tác khi đang lái xe',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Palette.onAlert,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: Space.xl),
              Text(
                paused
                    ? 'Đã tạm dừng'
                    : trip.withRoute
                    ? 'Đang theo tuyến'
                    : 'Đang theo dõi vị trí',
                style: mid,
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
                        Text(alert.title, style: big),
                        const SizedBox(height: Space.s),
                        Text(alert.body, style: mid),
                        const SizedBox(height: Space.l),
                      ],
                      if (trip.status != null)
                        Text(
                          trip.status!,
                          style: mid.copyWith(color: Palette.secondary),
                        ),
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
                    child: SizedBox(
                      height: 72,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Palette.white,
                          side: const BorderSide(color: Palette.white),
                          textStyle: const TextStyle(fontSize: 20),
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
                    child: SizedBox(
                      height: 72,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Palette.white,
                          textStyle: const TextStyle(fontSize: 20),
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

class _EndedCard extends StatelessWidget {
  const _EndedCard({required this.trip, required this.locations});

  final TripProvider trip;
  final LocationProvider locations;

  @override
  Widget build(BuildContext context) {
    final n = trip.alerts.length;
    return GlassCard(
      title: 'CHUYẾN ĐI ĐÃ KẾT THÚC',
      icon: Icons.check_circle_outline_rounded,
      trailing: TextButton(onPressed: trip.reset, child: const Text('Đóng')),
      child: Text(
        n == 0 ? 'Không có cảnh báo trên đường.' : '$n cảnh báo trên đường.',
        style: TypeScale.body.copyWith(color: Palette.white),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.trip, required this.locations});

  final TripProvider trip;
  final LocationProvider locations;

  String _name(String? id) => id == null ? '?' : locations.placeById(id).name;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final items = trip.history;
    return GlassCard(
      title: 'LỊCH SỬ CHUYẾN ĐI',
      icon: Icons.history_rounded,
      footer: 'Chỉ lưu trên máy này, không có đường đi GPS.',
      trailing: items.isEmpty
          ? null
          : TextButton(
              onPressed: trip.clearHistory,
              child: const Text('Xóa tất cả'),
            ),
      child: Material(
        type: MaterialType.transparency,
        child: items.isEmpty
            ? Text(
                'Chưa có chuyến đi nào.',
                style: TypeScale.body.copyWith(color: ink.secondary),
              )
            : Column(
                children: [
                  for (final r in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${_name(r.fromId)} → ${_name(r.toId)}'),
                      subtitle: Text(
                        '${r.startedAt.day}/${r.startedAt.month} '
                        '${_hhmm(r.startedAt)}–${_hhmm(r.endedAt)} · '
                        '${r.alerts.length} cảnh báo',
                      ),
                      trailing: IconButton(
                        tooltip: 'Xóa chuyến đi',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => trip.deleteRecord(r.id),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Mo man chuyen di.
Future<void> openTripScreen(
  BuildContext context, {
  required LocationProvider locations,
}) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => TripScreen(locations: locations)));
