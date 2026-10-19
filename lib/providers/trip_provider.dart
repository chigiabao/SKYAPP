/// Canh bao khi di chuyen (nhom 6).
///
/// - Khong co tuyen: moi khi sang o luoi khac (hoac moi 15 phut) kiem tra
///   thoi tiet o moi (/locations/nearest -> /weather/current + hourly 3 gio).
/// - Co tuyen: moi 10 phut lay thoi tiet doc phan tuyen con lai
///   (/route/along-weather, depart_at = bay gio) va bao truoc doan sap di qua
///   co mua lon / dong.
/// - Chong trung theo doan duong; tam dung; lich su chi luu tren may: id
///   phuong dau / cuoi, thoi gian, canh bao. KHONG luu vet GPS.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import '../models/units.dart';
import '../models/weather.dart';
import '../models/weather_alerts.dart';
import '../services/api_service.dart';
import '../services/gps_service.dart';
import '../services/route_service.dart';
import '../services/trip_location.dart';
import '../services/trip_notifier.dart';

enum TripPhase { idle, active, paused, ended }

/// Mot canh bao trong chuyen di.
@immutable
class TripAlert {
  const TripAlert({required this.at, required this.title, required this.body});

  final DateTime at; // gio TP.HCM
  final String title;
  final String body;

  Map<String, dynamic> toJson() => {
    'at': HcmTime.toIso(at),
    'title': title,
    'body': body,
  };

  static TripAlert? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final at = HcmTime.tryParse(j['at']?.toString());
    final t = j['title'];
    final b = j['body'];
    if (at == null || t is! String || b is! String) return null;
    return TripAlert(at: at, title: t, body: b);
  }
}

/// Mot chuyen di da xong. Chi id phuong, khong co toa do.
@immutable
class TripRecord {
  const TripRecord({
    required this.startedAt,
    required this.endedAt,
    required this.withRoute,
    this.fromId,
    this.toId,
    this.profile,
    this.alerts = const [],
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final bool withRoute;
  final String? fromId;
  final String? toId;
  final TripProfile? profile;
  final List<TripAlert> alerts;

  String get id => HcmTime.toIso(startedAt);

  Map<String, dynamic> toJson() => {
    'started_at': HcmTime.toIso(startedAt),
    'ended_at': HcmTime.toIso(endedAt),
    'with_route': withRoute,
    'from_id': fromId,
    'to_id': toId,
    'profile': profile?.api,
    'alerts': [for (final a in alerts) a.toJson()],
  };

  static TripRecord? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final s = HcmTime.tryParse(j['started_at']?.toString());
    final e = HcmTime.tryParse(j['ended_at']?.toString());
    if (s == null || e == null) return null;
    final a = j['alerts'];
    return TripRecord(
      startedAt: s,
      endedAt: e,
      withRoute: j['with_route'] == true,
      fromId: j['from_id'] as String?,
      toId: j['to_id'] as String?,
      profile: j['profile'] == null ? null : TripProfile.parse(j['profile']),
      alerts: [
        if (a is List)
          for (final x in a) ?TripAlert.tryFromJson(x),
      ],
    );
  }
}

/// Mot phuong an gio khoi hanh khi so sanh (lech [offsetMin] phut).
@immutable
class DepartOption {
  const DepartOption(this.offsetMin, this.route);
  final int offsetMin;
  final TripRoute route;
  int get score => routeHazardScore(route);
}

/// Diem nguy hiem cua tuyen: tong muc nguy hiem cac diem mau.
int routeHazardScore(TripRoute r) =>
    r.samples.fold(0, (s, x) => s + x.hazard.index);

class TripProvider extends ChangeNotifier {
  TripProvider({
    RouteService? routes,
    ApiService? api,
    TripLocationSource? location,
    TripNotifier? notifier,
    DateTime Function()? clock,
    UnitPrefs Function()? units,
    AlertSettings Function()? alertSettings,
    this.tickEvery = const Duration(minutes: 1),
  }) : _routes = routes ?? RouteService(),
       _api = api ?? ApiService(),
       _location = location ?? const GeolocatorTripLocation(),
       _notifier = notifier ?? TripNotifier.platform(),
       _clock = clock ?? DateTime.now,
       _units = units ?? (() => const UnitPrefs()),
       _alertSettings = alertSettings ?? (() => const AlertSettings());

  static const String historyKey = 'trip_history_v1';
  static const String soundKey = 'trip_sound_v1';
  static const int maxHistory = 30;

  /// Khong co tuyen: kiem tra lai sau moi khoang nay du chua doi o.
  static const Duration freeRecheck = Duration(minutes: 15);

  /// Co tuyen: lam moi thoi tiet doc tuyen.
  static const Duration routeRecheck = Duration(minutes: 10);

  /// Hai doan cung loai cach nhau duoi muc nay (km) coi la mot doan.
  static const double sameSegmentKm = 3;

  final RouteService _routes;
  final ApiService _api;
  final TripLocationSource _location;
  final TripNotifier _notifier;
  final DateTime Function() _clock;
  final UnitPrefs Function() _units;
  final AlertSettings Function() _alertSettings;

  /// Nhip kiem tra dinh ky (null = khong tu chay, test goi [tick]).
  final Duration? tickEvery;

  DateTime get nowHcm => HcmTime.now(_clock);

  // ---- Lap ke hoach ----

  TripRoute? _plan;
  bool _planning = false;
  String? _planError;
  List<DepartOption> _options = const [];
  bool _comparing = false;

  TripRoute? get plan => _plan;
  bool get planning => _planning;
  String? get planError => _planError;
  List<DepartOption> get departOptions => _options;
  bool get comparing => _comparing;

  /// Phuong an gio di it nguy hiem hon gio da chon (null = gio da chon tot).
  DepartOption? get betterDeparture {
    final p = _plan;
    if (p == null || _options.isEmpty) return null;
    final base = routeHazardScore(p);
    DepartOption? best;
    for (final o in _options) {
      if (o.score < base && (best == null || o.score < best.score)) best = o;
    }
    return best;
  }

  Future<TripRoute?> planRoute({
    required LatLng from,
    required LatLng to,
    required DateTime departAt,
    TripProfile profile = TripProfile.driving,
  }) async {
    _planning = true;
    _planError = null;
    _options = const [];
    notifyListeners();
    try {
      _plan = await _routes.fetchRoute(
        from: from,
        to: to,
        departAt: departAt,
        profile: profile,
      );
    } on RouteException catch (e) {
      _plan = null;
      _planError = e.message;
    }
    _planning = false;
    notifyListeners();
    return _plan;
  }

  void clearPlan() {
    _plan = null;
    _planError = null;
    _options = const [];
    notifyListeners();
  }

  /// Thoi tiet cung tuyen khi di som / muon 30, 60 phut (khong goi lai
  /// OSRM). Bo qua gio da qua.
  Future<void> compareDepartures() async {
    final p = _plan;
    if (p == null) return;
    _comparing = true;
    notifyListeners();
    final now = nowHcm.subtract(const Duration(minutes: 5));
    final out = <DepartOption>[];
    for (final m in const [-60, -30, 30, 60]) {
      final t = p.departAt.add(Duration(minutes: m));
      if (t.isBefore(now)) continue;
      try {
        out.add(
          DepartOption(
            m,
            await _routes.alongWeather(
              geometry: p.geometry,
              departAt: t,
              durationMin: p.durationMin,
              profile: p.profile,
            ),
          ),
        );
      } on RouteException catch (e) {
        debugPrint('TripProvider.compare: $e');
      }
    }
    if (identical(p, _plan)) _options = out;
    _comparing = false;
    notifyListeners();
  }

  // ---- Mua 2 gio toi tai cho (che do "Tôi sắp ra ngoài") ----

  Place? _nowPlace;
  List<HourlyForecast> _nowHours = const [];
  bool _nowLoading = false;
  String? _nowError;

  /// Phuong gan vi tri GPS nhat (null = chua co).
  Place? get nowcastPlace => _nowPlace;

  /// Cac moc gio trong 2 gio toi (gio hien tai + 2 gio sau).
  List<HourlyForecast> get nowcastHours => _nowHours;
  bool get nowcastLoading => _nowLoading;
  String? get nowcastError => _nowError;

  /// Lay du bao mua 2 gio toi tai [lat], [lon] (khong luu toa do).
  Future<void> loadNowcast(double lat, double lon) async {
    _nowLoading = true;
    _nowError = null;
    notifyListeners();
    try {
      final place = await _api.nearestLocation(lat, lon);
      final raw = await _api.fetchHourlyRaw(hours: 3, locationId: place.id);
      final from = nowHcm.subtract(const Duration(minutes: 59));
      _nowPlace = place;
      _nowHours = [
        for (final h in raw)
          if (h is Map<String, dynamic>) HourlyForecast.fromJson(h),
      ].where((h) => h.time.isAfter(from)).take(3).toList();
    } on OutsideAreaException {
      _nowError = 'Bạn đang ở ngoài TP.HCM, chưa có dự báo cho chỗ này.';
    } on ApiException catch (e) {
      _nowError = e.message;
    } on FormatException {
      _nowError = ApiException.messageFor(ApiErrorKind.invalidData);
    }
    _nowLoading = false;
    notifyListeners();
  }

  /// Ghi loi vi tri (GPS tat / chua cap quyen) cho the "mưa 2 giờ tới".
  void setNowcastError(String message) {
    _nowError = message;
    _nowLoading = false;
    notifyListeners();
  }

  // ---- Chuyen di ----

  TripPhase _phase = TripPhase.idle;
  TripRoute? _route;
  bool _background = false;
  bool _sound = true;
  String? _error;
  String? _status;
  Place? _place;
  String? _cellKey;
  LatLng? _lastPos;
  int _progressIdx = 0;
  double? _remainingKm;
  TripRoute? _ahead;
  DateTime? _startedAt;
  DateTime? _lastFreeCheck;
  DateTime? _lastRouteCheck;
  String? _fromId;
  String? _toId;
  final List<TripAlert> _alerts = [];
  final Set<String> _notifiedKeys = {};
  final List<(RouteHazard, double)> _notifiedSegments = [];
  int _notifyCount = 0;
  StreamSubscription<LatLng>? _sub;
  Timer? _timer;
  Future<void> _queue = Future.value();

  TripPhase get phase => _phase;
  bool get isRunning =>
      _phase == TripPhase.active || _phase == TripPhase.paused;
  bool get withRoute => _route != null;
  TripRoute? get route => _route;
  bool get background => _background;
  bool get sound => _sound;
  String? get error => _error;

  /// Dong trang thai ngan cho man dang di.
  String? get status => _status;
  Place? get currentPlace => _place;
  double? get remainingKm => _remainingKm;

  /// Thoi tiet doc phan tuyen con lai (lan lam moi gan nhat).
  TripRoute? get ahead => _ahead;
  List<TripAlert> get alerts => List.unmodifiable(_alerts);
  TripAlert? get lastAlert => _alerts.isEmpty ? null : _alerts.last;
  DateTime? get startedAt => _startedAt;

  /// Cho cac xu ly vi tri / kiem tra dang xep hang (dung trong test).
  Future<void> get idle => _queue;

  void setSound(bool on) {
    _sound = on;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((p) => p.setBool(soundKey, on))
        .catchError((Object _) => false);
  }

  /// Bat dau. [route] null = che do khong co tuyen. [background] chi co tac
  /// dung tren iOS / Android.
  Future<GpsStatus> start({
    TripRoute? route,
    String? fromId,
    String? toId,
    bool background = false,
  }) async {
    if (isRunning) return GpsStatus.ok;
    _error = null;
    final st = await _location.ensurePermission();
    if (st != GpsStatus.ok) {
      _error = st == GpsStatus.serviceDisabled
          ? 'Dịch vụ định vị đang tắt. Hãy bật định vị rồi thử lại.'
          : 'Chưa được cấp quyền vị trí nên không thể theo dõi chuyến đi.';
      notifyListeners();
      return st;
    }
    unawaited(_notifier.requestPermission().catchError((Object _) => false));
    _phase = TripPhase.active;
    _route = route;
    _background = background && tripBackgroundSupported;
    _startedAt = nowHcm;
    _fromId = fromId;
    _toId = toId;
    _place = null;
    _cellKey = null;
    _lastPos = null;
    _progressIdx = 0;
    _remainingKm = route?.distanceKm;
    _ahead = route;
    _lastFreeCheck = null;
    _lastRouteCheck = null;
    _alerts.clear();
    _notifiedKeys.clear();
    _notifiedSegments.clear();
    _status = route == null
        ? 'Đang chờ vị trí đầu tiên…'
        : 'Đang kiểm tra thời tiết dọc tuyến…';
    _resumeTracking();
    if (route != null) _enqueue(_checkRoute);
    notifyListeners();
    return GpsStatus.ok;
  }

  /// Tam dung theo doi (tat GPS, khong thong bao).
  void pause() {
    if (_phase != TripPhase.active) return;
    _stopTracking();
    _phase = TripPhase.paused;
    _status = 'Đã tạm dừng theo dõi.';
    notifyListeners();
  }

  void resume() {
    if (_phase != TripPhase.paused) return;
    _phase = TripPhase.active;
    _status = 'Đang theo dõi.';
    _resumeTracking();
    notifyListeners();
    unawaited(tick());
  }

  /// Ket thuc va luu vao lich su (khong co toa do).
  Future<void> end() async {
    if (!isRunning) return;
    _stopTracking();
    final started = _startedAt ?? nowHcm;
    _phase = TripPhase.ended;
    _status = null;
    final rec = TripRecord(
      startedAt: started,
      endedAt: nowHcm,
      withRoute: _route != null,
      fromId: _fromId,
      toId: _toId ?? _place?.id,
      profile: _route?.profile,
      alerts: List.of(_alerts),
    );
    _lastPos = null;
    notifyListeners();
    await _saveHistory([rec, ..._history].take(maxHistory).toList());
  }

  /// Ve trang thai chua di (sau khi xem tom tat).
  void reset() {
    if (isRunning) return;
    _phase = TripPhase.idle;
    _route = null;
    _ahead = null;
    _alerts.clear();
    notifyListeners();
  }

  /// Kiem tra dinh ky (Timer goi moi phut).
  Future<void> tick() {
    if (_phase != TripPhase.active) return _queue;
    final now = nowHcm;
    if (_route != null) {
      final last = _lastRouteCheck;
      if (last == null || now.difference(last) >= routeRecheck) {
        _enqueue(_checkRoute);
      }
    } else {
      final last = _lastFreeCheck;
      final p = _place;
      if (p != null && (last == null || now.difference(last) >= freeRecheck)) {
        _enqueue(() => _checkFree(p));
      } else if (p == null && _lastPos != null) {
        final pos = _lastPos!;
        _enqueue(() => _locateFree(pos));
      }
    }
    return _queue;
  }

  void _resumeTracking() {
    _sub?.cancel();
    _sub = _location
        .watch(background: _background)
        .listen(
          _onPosition,
          onError: (Object e) {
            debugPrint('TripProvider.position: $e');
            _status = 'Mất tín hiệu vị trí; sẽ thử lại khi có vị trí mới.';
            notifyListeners();
          },
        );
    _timer?.cancel();
    final every = tickEvery;
    if (every != null) _timer = Timer.periodic(every, (_) => tick());
  }

  void _stopTracking() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
  }

  void _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) async {
      try {
        await job();
      } catch (e) {
        debugPrint('TripProvider: $e');
      }
    });
  }

  void _onPosition(LatLng p) {
    if (_phase != TripPhase.active) return;
    _lastPos = p;
    if (_route != null) {
      _updateProgress(p);
      // Diem di la GPS: chi ghi id phuong gan nhat (khong ghi toa do).
      if (_fromId == null) {
        _enqueue(() async {
          _fromId ??= (await _api.nearestLocation(p.latitude, p.longitude)).id;
        });
      }
      notifyListeners();
    } else {
      _enqueue(() => _locateFree(p));
    }
  }

  // ---- Khong co tuyen ----

  Future<void> _locateFree(LatLng p) async {
    if (_phase != TripPhase.active) return;
    final Place place;
    try {
      place = await _api.nearestLocation(p.latitude, p.longitude);
    } on OutsideAreaException {
      _status = 'Đang ở ngoài TP.HCM, tạm không kiểm tra.';
      notifyListeners();
      return;
    } on ApiException catch (e) {
      _status = e.message;
      notifyListeners();
      return;
    }
    _fromId ??= place.id;
    final key = place.cellId ?? place.id;
    if (key == _cellKey) {
      _place = place;
      return;
    }
    _cellKey = key;
    _place = place;
    await _checkFree(place);
  }

  Future<void> _checkFree(Place place) async {
    if (_phase != TripPhase.active) return;
    final now = nowHcm;
    _lastFreeCheck = now;
    try {
      final raw = await _api.fetchHourlyRaw(hours: 3, locationId: place.id);
      final hours = <HourlyForecast>[
        for (final h in raw)
          if (h is Map<String, dynamic>) HourlyForecast.fromJson(h),
      ];
      String nowText = '';
      try {
        final c = CurrentWeather.fromJson(
          await _api.fetchCurrentRaw(locationId: place.id),
          locationName: place.name,
        );
        nowText = ' · ${c.temperature.round()}°, ${c.condition.description}';
      } catch (_) {}
      final settings = _alertSettings().copyWith(lookaheadHours: 3);
      final events = evaluateAlerts(
        hours,
        nowHcm: now,
        placeId: place.id,
        settings: settings,
      ).where((e) => e.level >= settings.minNotifyLevel);
      _status = events.isEmpty
          ? '${place.name}$nowText. Không có cảnh báo trong 3 giờ tới.'
          : '${place.name}$nowText';
      for (final e in events) {
        if (!_notifiedKeys.add('free|${e.key}')) continue;
        await _emit(
          '${e.type.label} tại ${place.name}',
          e.title,
          e.detailFor(_units()),
        );
      }
    } on ApiException catch (e) {
      _status = e.message;
    } on FormatException {
      _status = ApiException.messageFor(ApiErrorKind.invalidData);
    }
    notifyListeners();
  }

  // ---- Co tuyen ----

  void _updateProgress(LatLng p) {
    final r = _route!;
    if (r.geometry.length < 2) return;
    final i = nearestIndex(r.geometry, p);
    // Chi tien len (tranh nhay lui khi tuyen di vong).
    if (i > _progressIdx) _progressIdx = i;
    final cum = cumulativeKm(r.geometry);
    _remainingKm = cum.last - cum[_progressIdx];
  }

  Future<void> _checkRoute() async {
    final r = _route;
    if (r == null || _phase != TripPhase.active) return;
    final now = nowHcm;
    _lastRouteCheck = now;
    if (_lastPos != null) _updateProgress(_lastPos!);
    final rest = r.geometry.sublist(_progressIdx);
    if (rest.length < 2 || (_remainingKm ?? 1) < 0.3) {
      _status = 'Sắp tới nơi.';
      notifyListeners();
      return;
    }
    final cum = cumulativeKm(r.geometry);
    final traveled = cum[_progressIdx];
    final total = cum.last <= 0 ? r.distanceKm : cum.last;
    final duration = total <= 0
        ? null
        : r.durationMin * (total - traveled) / total;
    final TripRoute fresh;
    try {
      fresh = await _routes.alongWeather(
        geometry: rest,
        departAt: now,
        durationMin: duration,
        profile: r.profile,
      );
    } on RouteException catch (e) {
      _status = 'Chưa làm mới được thời tiết dọc tuyến: ${e.message}';
      notifyListeners();
      return;
    }
    if (_phase != TripPhase.active) return;
    _ahead = fresh;
    await _alertSegments(fresh, traveled);
    notifyListeners();
  }

  /// Gom cac diem mau lien tiep co mua lon / dong thanh doan; bao doan chua
  /// bao (cung loai, cach doan da bao < [sameSegmentKm] thi bo qua).
  Future<void> _alertSegments(TripRoute fresh, double traveledKm) async {
    final cum = cumulativeKm(fresh.geometry);
    final groups = <List<RouteSample>>[];
    var open = false;
    for (final s in fresh.samples) {
      if (s.isRainOrStormAlert) {
        if (!open) groups.add([]);
        groups.last.add(s);
        open = true;
      } else {
        open = false;
      }
    }
    if (groups.isEmpty) {
      _status = 'Không có mưa lớn hay dông trên phần đường còn lại.';
      return;
    }
    final units = _units();
    for (final g in groups) {
      final first = g.first;
      final kind = g.any((s) => s.isStorm)
          ? RouteHazard.storm
          : RouteHazard.heavy;
      final ahead = fresh.geometry.isEmpty
          ? 0.0
          : cum[nearestIndex(fresh.geometry, first.point)];
      final abs = traveledKm + ahead;
      final dup = _notifiedSegments.any(
        (x) => x.$1 == kind && (x.$2 - abs).abs() < sameSegmentKm,
      );
      final label = kind == RouteHazard.storm ? 'Dông' : 'Mưa lớn';
      final where = ahead < 0.5
          ? 'Ngay phía trước'
          : 'Khoảng ${units.distanceText(ahead)} nữa';
      final body = '$where, lúc ${_hhmm(first.eta)}.';
      _status = 'Phía trước: $label. $body';
      if (dup) continue;
      _notifiedSegments.add((kind, abs));
      await _emit('Phía trước: $label', body, first.alertReason);
    }
  }

  Future<void> _emit(String title, String body, [String? extra]) async {
    final text = extra == null || extra.isEmpty ? body : '$body $extra';
    _alerts.add(TripAlert(at: nowHcm, title: title, body: text));
    final id = 6000 + (_notifyCount++ % 100);
    try {
      await _notifier.notify(id, title, text, sound: _sound);
    } catch (e) {
      debugPrint('TripProvider.notify: $e');
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  // ---- Lich su (nhom 9) ----

  List<TripRecord> _history = const [];
  List<TripRecord> get history => _history;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _sound = p.getBool(soundKey) ?? true;
      final raw = p.getString(historyKey);
      if (raw != null) {
        final j = jsonDecode(raw);
        _history = [
          if (j is List)
            for (final x in j) ?TripRecord.tryFromJson(x),
        ];
      }
    } catch (e) {
      debugPrint('TripProvider.load: $e');
    }
    notifyListeners();
  }

  Future<void> deleteRecord(String id) => _saveHistory([
    for (final r in _history)
      if (r.id != id) r,
  ]);

  Future<void> clearHistory() => _saveHistory(const []);

  Future<void> _saveHistory(List<TripRecord> list) async {
    _history = list;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      if (list.isEmpty) {
        await p.remove(historyKey);
      } else {
        await p.setString(
          historyKey,
          jsonEncode([for (final r in list) r.toJson()]),
        );
      }
    } catch (e) {
      debugPrint('TripProvider.save: $e');
    }
  }

  @override
  void dispose() {
    _stopTracking();
    super.dispose();
  }
}
