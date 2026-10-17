import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activities.dart';
import '../models/habits.dart';
import '../models/place.dart';
import '../models/weather_alerts.dart';
import '../services/account_service.dart';
import 'location_provider.dart';
import 'planner_provider.dart';
import 'preferences_provider.dart';
import 'weather_provider.dart';

/// Trang thai dong bo.
enum SyncState {
  idle,
  syncing,

  /// Mat mang / may chu loi: da xep hang, se thu lai.
  pending,
  error,
}

/// Tai khoan TUY CHON + dong bo mot tai lieu JSON (sync.py) giua cac thiet bi.
///
/// Gom tu [LocationProvider] (dia diem da luu: id, nhan, ten rieng, thu tu -
/// KHONG co toa do, khong gui id "Vị trí hiện tại"), [WeatherProvider] (giao
/// dien, don vi), [PlannerProvider] (nguong canh bao, gio yen lang, hoat dong,
/// lich; thoi quen CHI khi nguoi dung da dong y).
///
/// - Dang nhap / mo app: keo ve, phan nao sua sau hon thi thang (lan dau tren
///   thiet bi nay: hop dia diem + hoat dong hai ben).
/// - Du lieu doi: day len sau [debounce].
/// - 409: gop theo id (dia diem / lich: hop hai ben, ban moi hon dung truoc
///   va thang), cai dat theo `updated_at` moi hon; thu lai MOT lan.
/// - Mat mang: giu "cho day", thu lai sau [retryDelay] / lan doi tiep theo /
///   lan mo app sau.
/// - Xoa dia diem: ghi "bia mo" (id + thoi diem, giu [tombstoneDays] ngay) de
///   ban gop 409 / thiet bi khac khong lam dia diem song lai; them lai sau do
///   thang bia mo.
/// - [PreferencesProvider] (don vi, chi so trang chu, tro nang) di trong
///   `settings.preferences`; nguong rieng theo dia diem trong
///   `settings.alerts.places`.
/// - 401: dang xuat em + bao (SnackBar qua [messengerKey] + [notice]).
class AccountProvider extends ChangeNotifier {
  AccountProvider({
    AccountService? service,
    TokenStore? store,
    this.debounce = const Duration(seconds: 2),
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _api = service ?? AccountService(),
       _store = store ?? TokenStore.platform(),
       _clock = clock ?? DateTime.now;

  static const String metaKey = 'account_sync_meta_v1';

  /// So ngay giu bia mo dia diem da xoa.
  static const int tombstoneDays = 30;
  static const int _tombstoneMs = tombstoneDays * 24 * 3600 * 1000;

  /// Gan vao MaterialApp.scaffoldMessengerKey de bao "phien het han" o moi
  /// man hinh.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static const String expiredMessage =
      'Phiên đăng nhập đã hết hạn nên bạn đã được đăng xuất. '
      'Dữ liệu trên máy vẫn giữ nguyên.';

  final AccountService _api;
  final TokenStore _store;
  final DateTime Function() _clock;
  final Duration debounce;
  final Duration retryDelay;

  LocationProvider? _lp;
  WeatherProvider? _wp;
  PlannerProvider? _pp;
  PreferencesProvider? _prefs;
  Future<void>? _init;

  AuthSession? _session;
  bool _ready = false;
  bool _applying = false;
  bool _busy = false;
  SyncState _state = SyncState.idle;
  String? _error;
  String? _notice;
  DateTime? _lastSynced;
  bool _syncing = false;
  bool _again = false;
  Timer? _debounceTimer;
  Timer? _retryTimer;

  /// Phien ban tai lieu tren may chu da biet; null = chua dong bo lan nao voi
  /// tai khoan nay tren thiet bi nay.
  int? _version;
  bool _pendingPush = false;

  /// Thoi diem (ms) sua gan nhat moi phan - dung khi gop.
  int _placesAt = 0;
  int _settingsAt = 0;
  int _activitiesAt = 0;
  Map<String, String> _baseline = const {};

  /// Bia mo: id dia diem da xoa -> ms; va id -> ms lan them gan nhat.
  Map<String, int> _deleted = {};
  Map<String, int> _added = {};

  // --- Getters ---------------------------------------------------------------

  bool get isReady => _ready;
  bool get isLoggedIn => _session != null;
  String? get email => _session?.email;
  AuthSession? get session => _session;

  /// Dang dang nhap / dang ky / xoa...
  bool get busy => _busy;
  SyncState get state => _state;
  String? get lastError => _error;
  DateTime? get lastSyncedAt => _lastSynced;
  bool get hasPendingChanges => _pendingPush;

  /// Thong bao mot lan (vd. phien het han); [clearNotice] sau khi hien.
  String? get notice => _notice;

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  // --- Khoi tao --------------------------------------------------------------

  /// Noi voi cac provider du lieu va bat dau (goi mot lan).
  Future<void> attach(
    LocationProvider lp,
    WeatherProvider wp,
    PlannerProvider pp, {
    PreferencesProvider? prefs,
  }) => _init ??= _start(lp, wp, pp, prefs);

  Future<void> _start(
    LocationProvider lp,
    WeatherProvider wp,
    PlannerProvider pp,
    PreferencesProvider? prefs,
  ) async {
    _lp = lp;
    _wp = wp;
    _pp = pp;
    _prefs = prefs;
    await Future.wait([lp.loadLocal(), pp.load(), ?prefs?.load()]);
    await _loadMeta();
    final s = await _store.read();
    if (s != null && s.isExpired(_clock())) {
      await _store.clear();
      _resetSyncMeta();
      _notice = expiredMessage;
    } else {
      _session = s;
    }
    _baseline = _sections();
    _ready = true;
    for (final p in <ChangeNotifier>[lp, wp, pp, ?prefs]) {
      p.addListener(_onLocalChanged);
    }
    notifyListeners();
    if (_session != null) await syncNow();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    for (final p in <ChangeNotifier?>[_lp, _wp, _pp, _prefs]) {
      p?.removeListener(_onLocalChanged);
    }
    super.dispose();
  }

  // --- Tai lieu dong bo ------------------------------------------------------

  int get _now => _clock().millisecondsSinceEpoch;

  static String _hhmm(int h) => '${h.toString().padLeft(2, '0')}:00';

  List<Map<String, dynamic>> _placesJson() {
    final saved = _lp?.saved ?? const <SavedPlace>[];
    return [
      for (var i = 0; i < saved.length; i++)
        {
          'id': saved[i].locationId,
          'label': saved[i].label.name,
          'custom_name': _cut(saved[i].customName, 100),
          'order': i,
        },
    ];
  }

  static String? _cut(String? s, int max) =>
      s == null || s.length <= max ? s : s.substring(0, max);

  Map<String, dynamic> _settingsCore() {
    final wp = _wp, pp = _pp;
    final a = pp?.settings ?? const AlertSettings();
    return {
      if (wp != null) 'theme': wp.themeMode.name,
      if (wp != null) 'units': {'temperature': wp.isCelsius ? 'c' : 'f'},
      'priority_metrics': <String>[],
      'alert_thresholds': {
        'rainProbability': a.rainProbability,
        'heavyRainMm': a.heavyRainMm,
        'heatTemp': a.heatTemp,
        'heatIndex': a.heatIndex,
        'uvIndex': a.uvIndex,
        'windGust': a.windGust,
        'aqi': a.aqi,
      },
      'quiet_hours': a.quietEnabled
          ? {'start': _hhmm(a.quietStart), 'end': _hhmm(a.quietEnd)}
          : null,
      'alerts': a.toJson(),
      if (pp != null) ...{
        'activity_favorites': [for (final f in pp.favorites) f.name],
        'activity_sensitivity': pp.sensitivity.name,
      },
      if (_prefs != null) 'preferences': _prefs!.exportSettings(),
    };
  }

  List<Map<String, dynamic>> _activitiesJson() => [
    for (final r in _pp?.routines ?? const <ActivityRoutine>[]) r.toJson(),
  ];

  bool get _habitsConsent => _pp?.habits.enabled ?? false;

  /// Tai lieu gui len PUT /me/data (khong co toa do; thoi quen chi khi da
  /// dong y).
  Map<String, dynamic> buildDocument() => {
    'saved_places': _placesJson(),
    'settings': {
      ..._settingsCore(),
      'updated_at': _settingsAt,
      'places_updated_at': _placesAt,
      'activities_updated_at': _activitiesAt,
      'deleted_places': _pruned(_deleted, _now),
      'places_added_at': _pruned(_added, _now),
    },
    'activities': _activitiesJson(),
    'habits_consent': _habitsConsent,
    'habits': _habitsConsent ? _pp!.habits.toJson() : null,
  };

  Map<String, String> _sections() => {
    'places': jsonEncode(_placesJson()),
    'settings': jsonEncode(_settingsCore()),
    'activities': jsonEncode(_activitiesJson()),
    'habits': jsonEncode(_habitsConsent ? _pp!.habits.toJson() : null),
  };

  static Set<String> _placeIds(String? json) {
    final l = json == null ? null : jsonDecode(json);
    return {for (final p in _maps(l)) '${p['id']}'};
  }

  /// Ghi bia mo / thoi diem them khi danh sach dia diem doi.
  void _trackPlaces(String? before, String after) {
    final old = _placeIds(before), now = _placeIds(after);
    for (final id in old.difference(now)) {
      _deleted[id] = _now;
    }
    for (final id in now.difference(old)) {
      _added[id] = _now;
      _deleted.remove(id);
    }
  }

  void _onLocalChanged() {
    if (!_ready || _applying) return;
    final now = _sections();
    if (_baseline['places'] != now['places']) {
      _trackPlaces(_baseline['places'], now['places']!);
    }
    var changed = false;
    for (final e in now.entries) {
      if (_baseline[e.key] == e.value) continue;
      changed = true;
      switch (e.key) {
        case 'places':
          _placesAt = _now;
        case 'settings':
          _settingsAt = _now;
        case 'activities':
          _activitiesAt = _now;
      }
    }
    if (!changed) return;
    _baseline = now;
    if (_session != null) {
      _pendingPush = true;
      _schedulePush();
    }
    _saveMeta();
  }

  void _schedulePush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => _run(_push));
  }

  // --- Gop -------------------------------------------------------------------

  static int _ts(Map<String, dynamic>? doc, String key) {
    final s = doc?['settings'];
    final v = s is Map ? s[key] : null;
    return v is num ? v.toInt() : 0;
  }

  static List<Map<String, dynamic>> _maps(Object? l) => [
    if (l is List)
      for (final e in l)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  /// Hop hai danh sach theo `id`: [first] dung truoc va thang khi trung.
  static List<Map<String, dynamic>> _unionById(
    List<Map<String, dynamic>> first,
    List<Map<String, dynamic>> second,
  ) {
    final ids = <String>{};
    return [
      for (final e in [...first, ...second])
        if (ids.add('${e['id']}')) e,
    ];
  }

  /// Map id -> ms con han (bo muc qua [tombstoneDays] ngay).
  static Map<String, int> _pruned(Map<String, int> m, int nowMs) => {
    for (final e in m.entries)
      if (nowMs - e.value <= _tombstoneMs) e.key: e.value,
  };

  static Map<String, int> _stamps(Map<String, dynamic>? doc, String key) {
    final s = doc?['settings'];
    final m = s is Map ? s[key] : null;
    return {
      if (m is Map)
        for (final e in m.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
  }

  /// Gop hai map id -> ms, lay ms lon hon.
  static Map<String, int> _maxStamps(
    Map<String, int> a,
    Map<String, int> b,
  ) => {
    for (final k in {...a.keys, ...b.keys}) k: math.max(a[k] ?? 0, b[k] ?? 0),
  };

  static List<Map<String, dynamic>> _sortedPlaces(Object? l) => _maps(l)
    ..sort(
      (a, b) =>
          ((a['order'] as num?) ?? 0).compareTo((b['order'] as num?) ?? 0),
    );

  /// Gop [local] va [remote] (tai lieu dang PUT /me/data).
  ///
  /// Moi phan: ban co `*_updated_at` lon hon thang (bang nhau -> may chu).
  /// [union] (xung dot 409 / lan dau tren thiet bi): dia diem va lich hoat
  /// dong hop theo id, ban moi hon dung truoc va thang khi trung. Thoi quen
  /// (neu ca hai dong y) lay so lon hon tung gio. `habits_consent` theo
  /// [local] (lua chon cua nguoi dung tren thiet bi nay).
  ///
  /// Bia mo (`settings.deleted_places`) hop hai ben; dia diem bi bo neu thoi
  /// diem xoa sau lan them gan nhat (`settings.places_added_at`, thieu = 0).
  /// Muc qua [tombstoneDays] ngay (theo [nowMs]) bi bo.
  static Map<String, dynamic> mergeDocuments(
    Map<String, dynamic> local,
    Map<String, dynamic> remote, {
    bool union = true,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final added = _pruned(
      _maxStamps(
        _stamps(local, 'places_added_at'),
        _stamps(remote, 'places_added_at'),
      ),
      now,
    );
    final deleted = _pruned(
      _maxStamps(
        _stamps(local, 'deleted_places'),
        _stamps(remote, 'deleted_places'),
      ),
      now,
    )..removeWhere((id, t) => (added[id] ?? 0) > t);
    final localPlaces =
        _ts(local, 'places_updated_at') > _ts(remote, 'places_updated_at');
    final pNew = _sortedPlaces((localPlaces ? local : remote)['saved_places']);
    final pOld = _sortedPlaces((localPlaces ? remote : local)['saved_places']);
    final places = [
      for (final p in union ? _unionById(pNew, pOld) : pNew)
        if (!deleted.containsKey('${p['id']}')) p,
    ];

    final localActs =
        _ts(local, 'activities_updated_at') >
        _ts(remote, 'activities_updated_at');
    final aNew = _maps((localActs ? local : remote)['activities']);
    final aOld = _maps((localActs ? remote : local)['activities']);

    final localSettings = _ts(local, 'updated_at') > _ts(remote, 'updated_at');
    final s = (localSettings ? local : remote)['settings'];
    final settings = <String, dynamic>{
      if (s is Map) ...Map<String, dynamic>.from(s),
    };
    for (final k in const [
      'updated_at',
      'places_updated_at',
      'activities_updated_at',
    ]) {
      settings[k] = math.max(_ts(local, k), _ts(remote, k));
    }
    settings['deleted_places'] = deleted;
    settings['places_added_at'] = added;

    final consent = local['habits_consent'] == true;
    final remoteHabits = remote['habits_consent'] == true
        ? remote['habits']
        : null;
    return {
      'saved_places': [
        for (var i = 0; i < places.length; i++) {...places[i], 'order': i},
      ],
      'settings': settings,
      'activities': union ? _unionById(aNew, aOld) : aNew,
      'habits_consent': consent,
      'habits': consent ? mergeHabits(local['habits'], remoteHabits) : null,
    };
  }

  /// Thoi quen hai thiet bi: so lan lon hon moi gio, hop danh sach bo qua.
  static Map<String, dynamic>? mergeHabits(Object? a, Object? b) {
    if (a is! Map) return b is Map ? Map<String, dynamic>.from(b) : null;
    if (b is! Map) return Map<String, dynamic>.from(a);
    Map<String, dynamic> maxMap(Object? x, Object? y) {
      final mx = x is Map ? x : const {}, my = y is Map ? y : const {};
      return {
        for (final k in {...mx.keys, ...my.keys})
          '$k': math.max(
            (mx[k] as num?)?.toInt() ?? 0,
            (my[k] as num?)?.toInt() ?? 0,
          ),
      };
    }

    final da = a['done'] is Map ? a['done'] as Map : const {};
    final db = b['done'] is Map ? b['done'] as Map : const {};
    return {
      'enabled': true,
      'opens': maxMap(a['opens'], b['opens']),
      'done': {
        for (final k in {...da.keys, ...db.keys}) '$k': maxMap(da[k], db[k]),
      },
      'dismissed': {
        for (final l in [a['dismissed'], b['dismissed']])
          if (l is List) ...l.whereType<String>(),
      }.toList()..sort(),
    };
  }

  /// Ap tai lieu da gop vao cac provider (khong coi la "nguoi dung sua").
  void _apply(Map<String, dynamic> doc) {
    final lp = _lp, wp = _wp, pp = _pp;
    _applying = true;
    try {
      final places = [
        for (final p in _sortedPlaces(doc['saved_places']))
          if (p['id'] is String && (p['id'] as String).isNotEmpty)
            SavedPlace(
              locationId: p['id'] as String,
              label: PlaceLabel.values.firstWhere(
                (l) => l.name == p['label'],
                orElse: () => PlaceLabel.none,
              ),
              customName: p['custom_name'] is String
                  ? p['custom_name'] as String
                  : null,
            ),
      ];
      if (lp != null &&
          jsonEncode([for (final s in places) s.toJson()]) !=
              jsonEncode([for (final s in lp.saved) s.toJson()])) {
        lp.importSaved(places);
      }

      final s = doc['settings'] is Map
          ? Map<String, dynamic>.from(doc['settings'] as Map)
          : const <String, dynamic>{};
      if (wp != null) {
        final theme = ThemeMode.values.where((m) => m.name == s['theme']);
        if (theme.isNotEmpty) wp.setThemeMode(theme.first);
        final units = s['units'];
        final t = units is Map ? units['temperature'] : null;
        if ((t == 'c' || t == 'f') && wp.isCelsius != (t == 'c')) {
          wp.setTemperatureUnit(t == 'c');
        }
      }
      final prefs = _prefs, pj = s['preferences'];
      if (prefs != null &&
          pj is Map &&
          jsonEncode(pj) != jsonEncode(prefs.exportSettings())) {
        prefs.importSettings(Map<String, dynamic>.from(pj));
      }
      if (pp != null) {
        final alerts = s['alerts'];
        final fav = s['activity_favorites'];
        final sens = Sensitivity.values.where(
          (x) => x.name == s['activity_sensitivity'],
        );
        final habits = doc['habits'];
        pp.importSyncData(
          alerts: alerts is Map
              ? AlertSettings.fromJson(Map<String, dynamic>.from(alerts))
              : null,
          favorites: fav is List
              ? [
                  for (final f in fav)
                    ...Activity.values.where((x) => x.name == f),
                ]
              : null,
          sensitivity: sens.isEmpty ? null : sens.first,
          routines: doc['activities'] is List
              ? [
                  for (final r in doc['activities'] as List)
                    ?ActivityRoutine.tryFromJson(r),
                ]
              : null,
          habits: _habitsConsent && habits is Map
              ? HabitData.fromJson(Map<String, dynamic>.from(habits))
              : null,
        );
      }
      _placesAt = _ts(doc, 'places_updated_at');
      _settingsAt = _ts(doc, 'updated_at');
      _activitiesAt = _ts(doc, 'activities_updated_at');
      _deleted = _stamps(doc, 'deleted_places');
      _added = _stamps(doc, 'places_added_at');
    } finally {
      _applying = false;
    }
    _baseline = _sections();
  }

  // --- Dong bo ---------------------------------------------------------------

  /// Chay [job] lan luot (khong chong nhau); 401 -> dang xuat em.
  Future<void> _run(Future<void> Function() job) async {
    if (_session == null) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    _retryTimer?.cancel();
    _state = SyncState.syncing;
    _error = null;
    notifyListeners();
    try {
      await job();
      _state = _pendingPush ? SyncState.pending : SyncState.idle;
    } on AccountException catch (e) {
      if (e.kind == AccountErrorKind.unauthorized) {
        await _expire();
      } else if (e.isTransient) {
        _state = SyncState.pending;
        _error = e.message;
        _retryTimer = Timer(retryDelay, () => _run(_pullAndPush));
      } else {
        _state = SyncState.error;
        _error = e.message;
      }
    } on SyncConflict {
      _state = SyncState.error;
      _error = 'Dữ liệu vừa đổi trên thiết bị khác. Sẽ thử lại sau.';
      _retryTimer = Timer(retryDelay, () => _run(_pullAndPush));
    } finally {
      _syncing = false;
    }
    _saveMeta();
    notifyListeners();
    if (_again && _session != null) {
      _again = false;
      _schedulePush();
    }
  }

  /// Dong bo ngay: keo ve, gop, day len neu can.
  Future<void> syncNow() => _run(_pullAndPush);

  Future<void> _pullAndPush() async {
    final token = _session!.token;
    final r = await _api.getData(token);
    final data = r.data;
    if (data == null) {
      _version = r.version;
      _pendingPush = true;
    } else {
      final merged = mergeDocuments(
        buildDocument(),
        data,
        union: _version == null,
        nowMs: _now,
      );
      _apply(merged);
      _version = r.version;
      _pendingPush = !_deepEquals(buildDocument(), data);
      if (!_pendingPush) _markSynced();
    }
    if (_pendingPush) await _push();
  }

  Future<void> _push() async {
    final s = _session;
    if (s == null) return;
    if (_version == null) return _pullAndPush();
    RemoteDoc r;
    try {
      r = await _put(s.token, _version!, buildDocument());
    } on SyncConflict catch (c) {
      final current = c.current.data;
      if (current != null) {
        _apply(mergeDocuments(buildDocument(), current, nowMs: _now));
      }
      r = await _put(s.token, c.current.version, buildDocument());
    }
    _version = r.version;
    _pendingPush = false;
    _markSynced();
  }

  /// PUT; 422 "Địa điểm không tồn tại" -> bo cac id do (chi trong ban gui)
  /// va gui lai mot lan.
  Future<RemoteDoc> _put(
    String token,
    int base,
    Map<String, dynamic> doc,
  ) async {
    try {
      return await _api.putData(token, base, doc);
    } on AccountException catch (e) {
      final bad = e.unknownLocationIds;
      if (bad == null || bad.isEmpty) rethrow;
      final places = [
        for (final p in _maps(doc['saved_places']))
          if (!bad.contains(p['id'])) p,
      ];
      return _api.putData(token, base, {
        ...doc,
        'saved_places': [
          for (var i = 0; i < places.length; i++) {...places[i], 'order': i},
        ],
      });
    }
  }

  void _markSynced() {
    _lastSynced = _clock();
  }

  static bool _deepEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      return a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  // --- Tai khoan -------------------------------------------------------------

  /// Dang nhap / dang ky; tra ve thong bao loi (null = thanh cong).
  Future<String?> signIn(
    String email,
    String password, {
    bool register = false,
  }) async {
    if (_busy) return null;
    _busy = true;
    notifyListeners();
    try {
      final s = register
          ? await _api.register(email, password)
          : await _api.login(email, password);
      await _store.write(s);
      _session = s;
      _resetSyncMeta();
      _notice = null;
      _busy = false;
      notifyListeners();
      await syncNow();
      return null;
    } on AccountException catch (e) {
      return e.message;
    } catch (e) {
      debugPrint('AccountProvider.signIn: $e');
      return 'Không lưu được phiên đăng nhập trên thiết bị này.';
    } finally {
      if (_busy) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Dang xuat (thu hoi token tren may chu neu duoc). Du lieu tren may giu.
  Future<void> signOut() async {
    final s = _session;
    if (s == null) return;
    try {
      await _api.logout(s.token);
    } on AccountException catch (e) {
      debugPrint('AccountProvider.logout: $e');
    }
    await _clearSession();
  }

  /// "Xoá dữ liệu đồng bộ" (giu tai khoan + du lieu tren may).
  Future<String?> deleteSyncedData() => _guard((t) async {
    await _api.deleteData(t);
    _version = 0;
    _pendingPush = false;
    _saveMeta();
  });

  /// "Xoá tài khoản" (nhap lai mat khau).
  Future<String?> deleteAccount(String password) => _guard((t) async {
    await _api.deleteAccount(t, password);
    await _clearSession();
  });

  /// JSON toan bo du lieu tren may chu (GET /me/export).
  Future<String> exportServerData() async {
    final s = _session;
    if (s == null) throw AccountException(AccountErrorKind.unauthorized);
    try {
      return await _api.export(s.token);
    } on AccountException catch (e) {
      if (e.kind == AccountErrorKind.unauthorized) await _expire();
      rethrow;
    }
  }

  /// JSON du lieu tren may (khong can tai khoan). Co ca thoi quen va id
  /// "Vị trí hiện tại" (chi id phuong/xa, khong co toa do).
  String exportLocalData() {
    final doc = buildDocument();
    return const JsonEncoder.withIndent('  ').convert({
      'exported_at': _clock().toUtc().toIso8601String(),
      'app': 'Sky Weather',
      'note':
          'Dữ liệu lưu trên thiết bị này. Không có toạ độ GPS; '
          'vị trí hiện tại chỉ lưu mã phường/xã.',
      ...doc,
      'habits': _pp?.habits.toJson(),
      'current_location_id': _lp?.currentLocationId,
      'notification_settings': _pp?.notifySettings.toJson(),
      'account_email': email,
    });
  }

  Future<Map<String, String>> privacyPolicy() => _api.privacy();

  Future<String?> _guard(Future<void> Function(String token) f) async {
    final s = _session;
    if (s == null || _busy) return null;
    _busy = true;
    notifyListeners();
    try {
      await f(s.token);
      return null;
    } on AccountException catch (e) {
      if (e.kind == AccountErrorKind.unauthorized) {
        await _expire();
        return expiredMessage;
      }
      return e.message;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _clearSession() async {
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    await _store.clear();
    _session = null;
    _resetSyncMeta();
    _state = SyncState.idle;
    _error = null;
    _saveMeta();
    notifyListeners();
  }

  /// Token het han / bi thu hoi: dang xuat em va bao.
  Future<void> _expire() async {
    await _clearSession();
    _notice = expiredMessage;
    notifyListeners();
    messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text(expiredMessage)),
    );
  }

  void _resetSyncMeta() {
    _version = null;
    _pendingPush = false;
    _lastSynced = null;
  }

  // --- Luu meta --------------------------------------------------------------

  Future<void> _loadMeta() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(metaKey);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is! Map) return;
      int i(String k) => j[k] is int ? j[k] as int : 0;
      _version = j['version'] is int ? j['version'] as int : null;
      _pendingPush = j['pending'] == true;
      _placesAt = i('places_at');
      _settingsAt = i('settings_at');
      _activitiesAt = i('activities_at');
      Map<String, int> m(String k) => {
        if (j[k] is Map)
          for (final e in (j[k] as Map).entries)
            if (e.value is int) '${e.key}': e.value as int,
      };
      _deleted = m('deleted_places');
      _added = m('places_added_at');
      final last = j['last_synced'];
      _lastSynced = last is int
          ? DateTime.fromMillisecondsSinceEpoch(last)
          : null;
    } catch (e) {
      debugPrint('AccountProvider.meta: $e');
    }
  }

  Future<void> _saveMeta() async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        metaKey,
        jsonEncode({
          'version': _version,
          'pending': _pendingPush,
          'places_at': _placesAt,
          'settings_at': _settingsAt,
          'activities_at': _activitiesAt,
          'deleted_places': _pruned(_deleted, _now),
          'places_added_at': _pruned(_added, _now),
          'last_synced': _lastSynced?.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      debugPrint('AccountProvider.saveMeta: $e');
    }
  }
}
