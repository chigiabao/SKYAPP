import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/hcm_time.dart';
import '../models/place.dart';
import '../services/api_service.dart';
import '../services/gps_service.dart';

/// Mot trang cua Home (PageView): vi tri hien tai hoac mot dia diem da luu.
@immutable
class HomePageEntry {
  const HomePageEntry(
    this.locationId, {
    this.isCurrentLocation = false,
    this.savedIndex,
  });

  final String locationId;

  /// Trang "Vị trí hiện tại" (GPS).
  final bool isCurrentLocation;

  /// Chi so trong [LocationProvider.saved]; null voi trang GPS / mac dinh.
  final int? savedIndex;

  @override
  bool operator ==(Object other) =>
      other is HomePageEntry &&
      other.locationId == locationId &&
      other.isCurrentLocation == isCurrentLocation &&
      other.savedIndex == savedIndex;

  @override
  int get hashCode => Object.hash(locationId, isCurrentLocation, savedIndex);
}

/// Ket qua "Dùng vị trí hiện tại".
enum GpsOutcomeKind {
  ok,
  serviceDisabled,
  denied,
  deniedForever,
  unavailable,
  outsideArea,
  unsupported,
  network,
}

@immutable
class GpsOutcome {
  const GpsOutcome(this.kind, this.message, {this.place});

  final GpsOutcomeKind kind;
  final String message;
  final Place? place;

  bool get ok => kind == GpsOutcomeKind.ok;

  /// Hien nut "Mở cài đặt".
  bool get canOpenSettings =>
      kind == GpsOutcomeKind.serviceDisabled ||
      kind == GpsOutcomeKind.denied ||
      kind == GpsOutcomeKind.deniedForever;

  /// Mo cai dat dinh vi (thay vi cai dat quyen cua app).
  bool get opensLocationSettings => kind == GpsOutcomeKind.serviceDisabled;
}

/// Danh sach dia diem, dia diem da luu, "Vị trí hiện tại" va du lieu ban do.
///
/// Moi thu doc duoc offline: danh sach dia diem, o ban do va ranh gioi duoc
/// cache trong SharedPreferences. Backend chua co cac endpoint -> chi mot
/// diem mac dinh "tsn", khong bao loi.
class LocationProvider extends ChangeNotifier {
  LocationProvider({
    ApiService? apiService,
    GpsService? gps,
    DateTime Function()? clock,
  }) : _api = apiService ?? ApiService(clock: clock),
       _gps = gps ?? const GeolocatorGps(),
       _clock = clock ?? DateTime.now;

  static const String savedKey = 'saved_places_v1';
  static const String gpsKey = 'gps_location_id';
  static const String placesKey = 'locations_cache_v1';
  static const String mapKey = 'map_cache_v1';
  static const String boundaryKey = 'boundary_cache_v1';

  final ApiService _api;
  final GpsService _gps;
  final DateTime Function() _clock;

  List<Place> _places = const [Place.fallback];
  Map<String, Place> _byId = {Place.defaultId: Place.fallback};
  bool _placesFromServer = false;
  List<SavedPlace> _saved = const [SavedPlace(locationId: Place.defaultId)];
  String? _gpsId;
  int _selected = 0;
  bool _localLoaded = false;

  List<MapCell> _cells = const [];
  DateTime? _cellsAt;
  DateTime? _cellsSavedAt;
  bool _cellsFromCache = false;
  bool _mapLoading = false;
  ApiErrorKind? _mapError;
  int _mapToken = 0;

  /// Khung gio dang xem (0 = bay gio) va cache khung theo offset (truc tiep).
  int _mapOffset = 0;
  int _cellsOffset = 0;
  int _mapMaxOffset = 72;
  final Map<int, List<MapCell>> _frames = {};
  DateTime? _framesHour;

  CityBoundary? _boundary;

  bool _gpsBusy = false;
  GpsOutcome? _gpsOutcome;

  // --- Getters ---------------------------------------------------------------

  /// Moi dia diem (it nhat diem mac dinh).
  List<Place> get places => _places;

  /// Danh sach dia diem lay tu may chu (hoac cache cua may chu).
  bool get hasPlaceList => _placesFromServer;

  List<SavedPlace> get saved => List.unmodifiable(_saved);

  /// Id dia diem cua "Vị trí hiện tại" (null = chua bat).
  String? get currentLocationId => _gpsId;

  bool get gpsBusy => _gpsBusy;
  GpsOutcome? get gpsOutcome => _gpsOutcome;

  List<MapCell> get cells => _cells;
  bool get mapLoading => _mapLoading;
  ApiErrorKind? get mapError => _mapError;

  /// Offset (gio) cua khung dang xem / dang tai.
  int get mapOffset => _mapOffset;

  /// Offset lon nhat backend cho phep (mac dinh 72).
  int get mapMaxOffset => _mapMaxOffset;

  /// So khung dang co trong cache (test).
  int get cachedFrameCount => _frames.length;

  /// Doi khung gio (truc tiep): dung cache neu co, khong thi tai.
  Future<void> setMapOffset(int hours) =>
      refreshMap(offset: hours.clamp(0, _mapMaxOffset), useCache: true);

  /// O ban do dang hien la du lieu cache (cu).
  bool get cellsStale => _cellsFromCache;

  /// Thoi diem luu cache o ban do (gio TP.HCM).
  DateTime? get cellsSavedAt => _cellsSavedAt;

  /// Thoi diem xem lai cua o ban do (null = truc tiep).
  DateTime? get cellsAt => _cellsAt;

  CityBoundary? get boundary => _boundary;

  /// Trang cua Home: [Vị trí hiện tại], dia diem da luu...; rong -> diem
  /// mac dinh.
  List<HomePageEntry> get pages {
    final out = <HomePageEntry>[
      if (_gpsId != null) HomePageEntry(_gpsId!, isCurrentLocation: true),
      for (var i = 0; i < _saved.length; i++)
        HomePageEntry(_saved[i].locationId, savedIndex: i),
    ];
    if (out.isEmpty) out.add(const HomePageEntry(Place.defaultId));
    return out;
  }

  int get selectedIndex => _selected.clamp(0, pages.length - 1);

  HomePageEntry get selectedPage => pages[selectedIndex];

  String get selectedLocationId => selectedPage.locationId;

  Place placeById(String id) =>
      _byId[id] ??
      Place(
        id: id,
        name: id == Place.defaultId ? ApiConfig.locationName : id,
        kind: PlaceKind.special,
        lat: ApiConfig.latitude,
        lon: ApiConfig.longitude,
      );

  /// Nhan cua trang (vd. "Nhà"); null neu khong co.
  String? labelFor(HomePageEntry e) {
    if (e.isCurrentLocation) return 'Vị trí hiện tại';
    final i = e.savedIndex;
    return i == null ? null : _saved[i].labelText;
  }

  /// O ban do chua dia diem [locationId]; null neu chua co du lieu.
  MapCell? cellFor(String locationId) {
    if (_cells.isEmpty) return null;
    final cellId = _byId[locationId]?.cellId;
    if (cellId != null) {
      for (final c in _cells) {
        if (c.cellId == cellId) return c;
      }
    }
    for (final c in _cells) {
      if (c.locationIds.contains(locationId)) return c;
    }
    return null;
  }

  /// Tim khong dau tren danh sach da cache (chay ca khi offline).
  List<Place> search(String query) => searchPlaces(_places, query);

  /// Tim tren may chu; null neu loi / chua ho tro.
  Future<List<Place>?> searchRemote(String query) async {
    if (foldVietnamese(query).isEmpty) return const [];
    try {
      final r = await _api.searchLocations(query);
      for (final p in r) {
        _byId.putIfAbsent(p.id, () => p);
      }
      return r;
    } on ApiException {
      return null;
    }
  }

  // --- Tai / luu -------------------------------------------------------------

  /// Doc du lieu da luu (nhanh, khong goi mang). Goi nhieu lan khong sao.
  Future<void> loadLocal() async {
    if (_localLoaded) return;
    _localLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawPlaces = prefs.getString(placesKey);
      if (rawPlaces != null) {
        final list = Place.listFromJson(jsonDecode(rawPlaces));
        if (list.isNotEmpty) _setPlaces(list, fromServer: true);
      }
      final rawSaved = prefs.getString(savedKey);
      if (rawSaved != null) {
        final json = jsonDecode(rawSaved);
        if (json is List) {
          _saved = [
            for (final e in json)
              if (SavedPlace.fromJson(e) case final SavedPlace s) s,
          ];
        }
      }
      _gpsId = prefs.getString(gpsKey);
      final rawMap = prefs.getString(mapKey);
      if (rawMap != null) {
        final json = jsonDecode(rawMap);
        if (json is Map) {
          _cells = MapCell.listFromJson(json['cells']);
          _cellsSavedAt = HcmTime.tryParse(json['saved_at']?.toString());
          _cellsFromCache = true;
          _cellsAt = null;
        }
      }
      final rawBoundary = prefs.getString(boundaryKey);
      if (rawBoundary != null) {
        final b = CityBoundary.fromGeoJson(jsonDecode(rawBoundary));
        if (!b.isEmpty) _boundary = b;
      }
    } catch (e) {
      debugPrint('LocationProvider: load failed: $e');
    }
    notifyListeners();
  }

  /// Tai danh sach dia diem, o ban do (theo [at] khi xem lai) va ranh gioi.
  /// Loi bi bo qua (giu du lieu cache).
  Future<void> refreshRemote({DateTime? at}) async {
    await loadLocal();
    await Future.wait([refreshPlaces(), refreshMap(at: at), refreshBoundary()]);
  }

  Future<void> refreshPlaces() async {
    try {
      final list = await _api.fetchLocations();
      if (list.isEmpty) return;
      _setPlaces(list, fromServer: true);
      notifyListeners();
      _write(placesKey, jsonEncode([for (final p in list) p.toJson()]));
    } on ApiException catch (e) {
      debugPrint('LocationProvider: /locations ${e.kind.name}');
    }
  }

  Future<void> refreshBoundary() async {
    try {
      final b = await _api.fetchBoundary();
      if (b.isEmpty) return;
      _boundary = b;
      notifyListeners();
      _write(boundaryKey, jsonEncode(b.toGeoJson()));
    } on ApiException catch (e) {
      debugPrint('LocationProvider: /locations/boundary ${e.kind.name}');
    }
  }

  /// GET /weather/map. Truc tiep: loi -> giu / doc cache ("Dữ liệu cũ").
  /// Xem lai ([at] != null): khong dung cache truc tiep.
  /// [offset]: khung gio (chi khi truc tiep; xem lai luon 0). [useCache]:
  /// dung khung da tai (cache bi xoa khi sang gio moi hoac lam moi).
  Future<void> refreshMap({
    DateTime? at,
    int? offset,
    bool useCache = false,
  }) async {
    final token = ++_mapToken;
    final off = at != null ? 0 : (offset ?? _mapOffset);
    _mapOffset = off;
    final hour = HcmTime.startOfHour(HcmTime.now(_clock));
    if (at != null || !useCache || _framesHour != hour) _frames.clear();
    _framesHour = hour;
    final hit = at == null ? _frames[off] : null;
    if (hit != null) {
      _cells = hit;
      _cellsAt = null;
      _cellsOffset = off;
      _cellsFromCache = false;
      _mapError = null;
      _mapLoading = false;
      notifyListeners();
      return;
    }
    _mapLoading = true;
    notifyListeners();
    try {
      final cells = await _api.fetchMapCells(at: at, offsetHours: off);
      if (token != _mapToken) return;
      _cells = cells;
      _cellsAt = at;
      _cellsOffset = off;
      _cellsFromCache = false;
      _mapError = null;
      final max = cells.isEmpty ? null : cells.first.maxOffsetHours;
      if (max != null && max >= 0) _mapMaxOffset = max;
      if (at == null) _frames[off] = cells;
      if (at == null && off == 0) {
        _cellsSavedAt = HcmTime.now(_clock);
        _write(
          mapKey,
          jsonEncode({
            'saved_at': HcmTime.toIso(_cellsSavedAt!),
            'cells': [for (final c in cells) c.toJson()],
          }),
        );
      }
    } on ApiException catch (e) {
      if (token != _mapToken) return;
      _mapError = e.kind;
      final sameMoment =
          _cellsAt == at && _cellsOffset == off && _cells.isNotEmpty;
      if (at != null || off != 0) {
        if (!sameMoment) _cells = const [];
      } else if (!sameMoment || !_cellsFromCache) {
        await _loadMapCache();
      }
    } finally {
      if (token == _mapToken) {
        _mapLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadMapCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(mapKey);
      if (raw == null) {
        _cells = const [];
        return;
      }
      final json = jsonDecode(raw);
      if (json is! Map) return;
      _cells = MapCell.listFromJson(json['cells']);
      _cellsSavedAt = HcmTime.tryParse(json['saved_at']?.toString());
      _cellsAt = null;
      _cellsOffset = 0;
      _cellsFromCache = _cells.isNotEmpty;
    } catch (e) {
      debugPrint('LocationProvider: map cache: $e');
    }
  }

  void _setPlaces(List<Place> list, {required bool fromServer}) {
    _places = list;
    _byId = {for (final p in list) p.id: p};
    _byId.putIfAbsent(Place.defaultId, () => Place.fallback);
    _placesFromServer = fromServer;
  }

  Future<void> _write(String key, String? value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    } catch (e) {
      debugPrint('LocationProvider: save $key failed: $e');
    }
  }

  Future<void> _saveSaved() =>
      _write(savedKey, jsonEncode([for (final s in _saved) s.toJson()]));

  // --- Chon trang ------------------------------------------------------------

  void select(int index) {
    final i = index.clamp(0, pages.length - 1);
    if (i == _selected) return;
    _selected = i;
    notifyListeners();
  }

  /// Chon trang cua [locationId] (uu tien dia diem da luu); false neu khong
  /// co trang nao.
  bool selectLocation(String locationId) {
    final i = pageIndexOf(locationId);
    if (i < 0) return false;
    select(i);
    return true;
  }

  int pageIndexOf(String locationId) {
    final ps = pages;
    for (var i = 0; i < ps.length; i++) {
      if (!ps[i].isCurrentLocation && ps[i].locationId == locationId) return i;
    }
    return ps.indexWhere((p) => p.locationId == locationId);
  }

  /// Giu trang dang xem sau khi danh sach trang doi.
  void _keepSelection(HomePageEntry before) {
    final ps = pages;
    var i = ps.indexOf(before);
    if (i < 0) i = ps.indexWhere((p) => p.locationId == before.locationId);
    _selected = i < 0 ? _selected.clamp(0, ps.length - 1) : i;
  }

  // --- Dia diem da luu -------------------------------------------------------

  bool isSaved(String locationId) =>
      _saved.any((s) => s.locationId == locationId);

  /// Them dia diem; false neu da co.
  bool addSaved(
    String locationId, {
    PlaceLabel label = PlaceLabel.none,
    String? customName,
  }) {
    if (isSaved(locationId)) return false;
    final before = selectedPage;
    _saved = [
      ..._saved,
      SavedPlace(locationId: locationId, label: label, customName: customName),
    ];
    _keepSelection(before);
    _saveSaved();
    notifyListeners();
    return true;
  }

  /// Xoa va tra ve muc da xoa (de "Hoàn tác").
  SavedPlace removeSavedAt(int index) {
    final before = selectedPage;
    final list = [..._saved];
    final removed = list.removeAt(index);
    _saved = list;
    _keepSelection(before);
    _saveSaved();
    notifyListeners();
    return removed;
  }

  void insertSaved(int index, SavedPlace place) {
    if (isSaved(place.locationId)) return;
    final before = selectedPage;
    final list = [..._saved];
    list.insert(index.clamp(0, list.length), place);
    _saved = list;
    _keepSelection(before);
    _saveSaved();
    notifyListeners();
  }

  /// Doi cho: [from] -> vi tri cuoi cung [to] (sau khi lay ra).
  void moveSaved(int from, int to) {
    if (from == to || from < 0 || from >= _saved.length) return;
    final before = selectedPage;
    final list = [..._saved];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    _saved = list;
    _keepSelection(before);
    _saveSaved();
    notifyListeners();
  }

  void setLabel(int index, PlaceLabel label, {String? customName}) {
    final list = [..._saved];
    list[index] = SavedPlace(
      locationId: list[index].locationId,
      label: label,
      customName: label == PlaceLabel.custom ? customName?.trim() : null,
    );
    _saved = list;
    _saveSaved();
    notifyListeners();
  }

  // --- Vi tri hien tai ------------------------------------------------------

  void clearGpsOutcome() {
    if (_gpsOutcome == null) return;
    _gpsOutcome = null;
    notifyListeners();
  }

  /// Tat "Vị trí hiện tại" (xoa id da luu).
  void disableCurrentLocation() {
    if (_gpsId == null) return;
    final before = selectedPage;
    _gpsId = null;
    _keepSelection(before);
    _write(gpsKey, null);
    notifyListeners();
  }

  /// Nguoi dung cham "Dùng vị trí hiện tại": xin quyen, lay vi tri, hoi may
  /// chu dia diem gan nhat. Toa do chi o trong ham nay - chi luu id.
  Future<GpsOutcome> useCurrentLocation() async {
    if (_gpsBusy) return _gpsOutcome ?? _outcome(GpsOutcomeKind.unavailable);
    _gpsBusy = true;
    _gpsOutcome = null;
    notifyListeners();
    GpsOutcome result;
    try {
      result = await _resolveCurrent();
    } catch (e) {
      debugPrint('LocationProvider: gps $e');
      result = _outcome(GpsOutcomeKind.unavailable);
    }
    if (result.ok) {
      final place = result.place!;
      _byId.putIfAbsent(place.id, () => place);
      _gpsId = place.id;
      _selected = 0;
      _write(gpsKey, place.id);
    }
    _gpsOutcome = result;
    _gpsBusy = false;
    notifyListeners();
    return result;
  }

  Future<GpsOutcome> _resolveCurrent() async {
    final fix = await _gps.locate();
    switch (fix.status) {
      case GpsStatus.serviceDisabled:
        return _outcome(GpsOutcomeKind.serviceDisabled);
      case GpsStatus.denied:
        return _outcome(GpsOutcomeKind.denied);
      case GpsStatus.deniedForever:
        return _outcome(GpsOutcomeKind.deniedForever);
      case GpsStatus.unavailable:
        final why = fix.detail;
        return why == null
            ? _outcome(GpsOutcomeKind.unavailable)
            : GpsOutcome(GpsOutcomeKind.unavailable, why);
      case GpsStatus.ok:
        break;
    }
    final lat = fix.lat!;
    final lon = fix.lon!;
    final b = _boundary;
    if (b != null && !b.contains(lat, lon)) {
      return _outcome(GpsOutcomeKind.outsideArea);
    }
    try {
      final place = await _api.nearestLocation(lat, lon);
      return GpsOutcome(
        GpsOutcomeKind.ok,
        'Đã chọn ${place.name}',
        place: place,
      );
    } on OutsideAreaException catch (e) {
      return GpsOutcome(GpsOutcomeKind.outsideArea, _outsideMessage(e.message));
    } on ApiException catch (e) {
      // Offline nhung biet ranh gioi + danh sach: tu tim diem gan nhat.
      if (b != null && _placesFromServer) {
        final p = nearestPlace(_places, lat, lon);
        if (p != null) {
          return GpsOutcome(GpsOutcomeKind.ok, 'Đã chọn ${p.name}', place: p);
        }
      }
      return e.kind == ApiErrorKind.notFound
          ? _outcome(GpsOutcomeKind.unsupported)
          : GpsOutcome(GpsOutcomeKind.network, e.message);
    }
  }

  static String _outsideMessage(String detail) =>
      'Ngoài vùng hỗ trợ: vị trí của bạn nằm ngoài TP.HCM. '
      'Ứng dụng chỉ có dữ liệu cho các phường, xã của TP.HCM.';

  static GpsOutcome _outcome(GpsOutcomeKind k) => GpsOutcome(k, switch (k) {
    GpsOutcomeKind.serviceDisabled =>
      'Dịch vụ định vị đang tắt. Hãy bật định vị trong cài đặt rồi thử lại.',
    GpsOutcomeKind.denied =>
      'Bạn chưa cho phép ứng dụng dùng vị trí. Hãy cấp quyền vị trí, '
          'hoặc tìm địa điểm theo tên.',
    GpsOutcomeKind.deniedForever =>
      'Quyền vị trí đã bị từ chối. Mở cài đặt của ứng dụng để cấp lại quyền.',
    GpsOutcomeKind.unavailable =>
      'Không lấy được vị trí hiện tại. Vui lòng thử lại.',
    GpsOutcomeKind.outsideArea => _outsideMessage(''),
    GpsOutcomeKind.unsupported =>
      'Máy chủ chưa hỗ trợ tìm địa điểm theo vị trí. Hãy tìm theo tên.',
    GpsOutcomeKind.network => ApiException.messageFor(ApiErrorKind.network),
    GpsOutcomeKind.ok => '',
  });

  Future<bool> openSettingsFor(GpsOutcome o) => o.opensLocationSettings
      ? _gps.openLocationSettings()
      : _gps.openAppSettings();
}
