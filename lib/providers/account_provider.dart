import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../services/account_merger.dart';
import '../services/account_service.dart';
import '../services/account_sync_storage.dart';

import 'account_doc_builder.dart';
import 'location_provider.dart';
import 'planner_provider.dart';
import 'preferences_provider.dart';
import 'weather_provider.dart';
import '../screens/account_screen.dart' show AccountScreen;
import '../ui/weather/widgets/adaptive_dialog.dart';

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
/// - 401: dang xuat em + bao (hop thoai iOS qua [navigatorKey] + [notice]).
class AccountProvider extends ChangeNotifier {
  AccountProvider({
    AccountService? service,
    TokenStore? store,
    this.debounce = const Duration(seconds: 2),
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _api = service ?? AccountService(),
       _ownsApi = service == null,
       _store = store ?? TokenStore.platform(),
       _clock = clock ?? DateTime.now;

  static const String metaKey = 'account_sync_meta_v1';

  /// So ngay giu bia mo dia diem da xoa.
  static const int tombstoneDays = 30;

  /// Gan vao MaterialApp.navigatorKey de bao "phien het han" (hop thoai
  /// iOS) o moi man hinh.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Dang hien hop thoai het phien (khong chong nhieu hop thoai).
  static bool _expiredAlertOpen = false;

  /// Noi dung hop thoai het phien (tieu de da noi "het han": khong lap lai).
  static const String expiredAlertTitle = 'Phiên đăng nhập đã hết hạn';
  static const String expiredAlertMessage =
      'Vui lòng đăng nhập lại để tiếp tục đồng bộ. '
      'Dữ liệu trên máy vẫn giữ nguyên.';

  static const String expiredMessage =
      'Phiên đăng nhập đã hết hạn nên bạn đã được đăng xuất. '
      'Dữ liệu trên máy vẫn giữ nguyên.';

  final AccountService _api;
  final bool _ownsApi;
  final TokenStore _store;
  final DateTime Function() _clock;
  final Duration debounce;
  final Duration retryDelay;

  LocationProvider? _lp;
  PlannerProvider? _pp;
  PreferencesProvider? _prefs;
  Future<void>? _init;
  int _sessionEpoch = 0;
  bool _disposed = false;
  Future<void> _storageWrites = Future<void>.value();
  String? _serverEndpoint;

  static const serverChangedMessage =
      'Máy chủ đã đổi. Vui lòng đăng nhập lại; dữ liệu trên máy vẫn giữ nguyên.';

  Future<void> _persistSession(AuthSession? session) {
    final write = _storageWrites.then(
      (_) => session == null ? _store.clear() : _store.write(session),
    );
    _storageWrites = write.catchError((Object e) {
      debugPrint('AccountProvider.session: $e');
    });
    return write;
  }

  bool _currentSession(AuthSession s, int epoch) =>
      !_disposed &&
      epoch == _sessionEpoch &&
      identical(_session, s) &&
      s.serverUrl == ApiConfig.normalizeBaseUrl(_api.baseUrl);

  void _serverChanged() {
    if (_disposed) return;
    final endpoint = ApiConfig.normalizeBaseUrl(_api.baseUrl);
    if (endpoint == _serverEndpoint) return;
    _serverEndpoint = endpoint;
    _notice = serverChangedMessage;
    unawaited(_clearSession());
  }

  AuthSession? _session;
  bool _ready = false;
  bool _applying = false;
  bool _busy = false;
  SyncState _state = SyncState.idle;
  String? _error;
  String? _notice;
  bool _syncing = false;
  bool _again = false;
  Timer? _debounceTimer;
  Timer? _retryTimer;

  /// Phien ban tai lieu tren may chu da biet; null = chua dong bo lan nao voi
  /// tai khoan nay tren thiet bi nay.
  final SyncMetadata _meta = SyncMetadata();
  Map<String, String> _baseline = const {};

  // --- Getters ---------------------------------------------------------------

  bool get isReady => _ready;
  bool get isLoggedIn => _session != null;
  String? get email => _session?.email;
  AuthSession? get session => _session;

  /// Dang dang nhap / dang ky / xoa...
  bool get busy => _busy;
  SyncState get state => _state;
  String? get lastError => _error;
  DateTime? get lastSyncedAt => _meta.lastSynced;
  bool get hasPendingChanges => _meta.pendingPush;

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
  }) => _init ??= _start(lp, pp, prefs);

  /// [WeatherProvider] khong con du lieu dong bo (theme/don vi o
  /// PreferencesProvider) nen khong nghe no; tham so giu cho tuong thich.
  Future<void> _start(
    LocationProvider lp,
    PlannerProvider pp,
    PreferencesProvider? prefs,
  ) async {
    _lp = lp;
    _pp = pp;
    _prefs = prefs;
    _serverEndpoint = ApiConfig.normalizeBaseUrl(_api.baseUrl);
    ApiConfig.serverChanges.addListener(_serverChanged);
    final epoch = _sessionEpoch;
    await Future.wait([lp.loadLocal(), pp.load(), ?prefs?.load()]);
    if (_disposed) return;
    final s = await _store.read();
    if (_disposed) return;
    await _loadMeta(s);
    if (_disposed) return;
    final invalid =
        s != null &&
        (s.isExpired(_clock()) ||
            s.serverUrl != ApiConfig.normalizeBaseUrl(_api.baseUrl));
    if (epoch != _sessionEpoch || invalid) {
      await _persistSession(null);
      _resetSyncMeta();
      _notice = s != null && s.isExpired(_clock())
          ? expiredMessage
          : serverChangedMessage;
    } else {
      _session = s;
      _api.bindSession(s);
    }
    if (_disposed) return;
    _baseline = _sections();
    _ready = true;
    for (final p in <ChangeNotifier>[lp, pp, ?prefs]) {
      p.addListener(_onLocalChanged);
    }
    notifyListeners();
    if (_session != null) await syncNow();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionEpoch++;
    ApiConfig.serverChanges.removeListener(_serverChanged);
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    for (final p in <ChangeNotifier?>[_lp, _pp, _prefs]) {
      p?.removeListener(_onLocalChanged);
    }
    if (_ownsApi) _api.close();
    super.dispose();
  }

  // --- Tai lieu dong bo ------------------------------------------------------

  int get _now => _clock().millisecondsSinceEpoch;

  /// Tai lieu gui len PUT /me/data (khong co toa do; thoi quen chi khi da
  /// dong y).
  Map<String, dynamic> buildDocument() => AccountDocBuilder.buildDocument(
    lp: _lp,
    pp: _pp,
    prefs: _prefs,
    settingsAt: _meta.settingsAt,
    placesAt: _meta.placesAt,
    activitiesAt: _meta.activitiesAt,
    deleted: _meta.deleted,
    added: _meta.added,
    nowMs: _now,
  );

  Map<String, String> _sections() =>
      AccountDocBuilder.buildSections(lp: _lp, pp: _pp, prefs: _prefs);

  static Set<String> _placeIds(String? json) {
    final l = json == null ? null : jsonDecode(json);
    return {for (final p in AccountMerger.maps(l)) '${p['id']}'};
  }

  /// Ghi bia mo / thoi diem them khi danh sach dia diem doi.
  void _trackPlaces(String? before, String after) {
    final old = _placeIds(before), now = _placeIds(after);
    for (final id in old.difference(now)) {
      _meta.deleted[id] = _now;
    }
    for (final id in now.difference(old)) {
      _meta.added[id] = _now;
      _meta.deleted.remove(id);
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
          _meta.placesAt = _now;
        case 'settings':
          _meta.settingsAt = _now;
        case 'activities':
          _meta.activitiesAt = _now;
      }
    }
    if (!changed) return;
    _baseline = now;
    if (_session != null) {
      _meta.pendingPush = true;
      _schedulePush();
    }
    _saveMeta();
  }

  void _schedulePush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => _run(_push));
  }

  // --- Gop & Ap dung --------------------------------------------------------

  static Map<String, dynamic> mergeDocuments(
    Map<String, dynamic> local,
    Map<String, dynamic> remote, {
    bool union = true,
    int? nowMs,
  }) => AccountMerger.mergeDocuments(local, remote, union: union, nowMs: nowMs);

  static Map<String, dynamic>? mergeHabits(Object? a, Object? b) =>
      AccountMerger.mergeHabits(a, b);

  /// Ap tai lieu da gop vao cac provider (khong coi la "nguoi dung sua").
  void _apply(Map<String, dynamic> doc) {
    _applying = true;
    try {
      AccountDocBuilder.applyDocument(doc, lp: _lp, pp: _pp, prefs: _prefs);
      _meta.placesAt = AccountMerger.ts(doc, 'places_updated_at');
      _meta.settingsAt = AccountMerger.ts(doc, 'updated_at');
      _meta.activitiesAt = AccountMerger.ts(doc, 'activities_updated_at');
      _meta.deleted = AccountMerger.stamps(doc, 'deleted_places');
      _meta.added = AccountMerger.stamps(doc, 'places_meta.added_at');
    } finally {
      _applying = false;
    }
    _baseline = _sections();
  }

  // --- Dong bo ---------------------------------------------------------------

  /// Chay [job] lan luot (khong chong nhau); 401 -> dang xuat em.
  Future<void> _run(Future<void> Function() job) async {
    final session = _session;
    final epoch = _sessionEpoch;
    if (session == null || _busy || !_currentSession(session, epoch)) return;
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
      if (!_currentSession(session, epoch)) return;
      _state = _meta.pendingPush ? SyncState.pending : SyncState.idle;
    } on AccountException catch (e) {
      if (!_currentSession(session, epoch)) return;
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
      if (!_currentSession(session, epoch)) return;
      _state = SyncState.error;
      _error = 'Dữ liệu vừa đổi trên thiết bị khác. Sẽ thử lại sau.';
      _retryTimer = Timer(retryDelay, () => _run(_pullAndPush));
    } finally {
      if (epoch == _sessionEpoch) _syncing = false;
    }
    if (!_currentSession(session, epoch)) return;
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
    final session = _session;
    final epoch = _sessionEpoch;
    if (session == null || !_currentSession(session, epoch)) return;
    final r = await _api.getData(session.token);
    if (!_currentSession(session, epoch)) return;
    final data = r.data;
    if (data == null) {
      _meta.pendingPush =
          r.version == 0 ||
          (_meta.pendingPush &&
              (_meta.version == r.version || _meta.localDeleteRevisionPending));
      _meta.version = r.version;
      _meta.localDeleteRevisionPending = false;
      if (!_meta.pendingPush) _markSynced();
    } else {
      _meta.localDeleteRevisionPending = false;
      final merged = mergeDocuments(
        buildDocument(),
        data,
        union: _meta.version == null,
        nowMs: _now,
      );
      _apply(merged);
      _meta.version = r.version;
      _meta.pendingPush = !_deepEquals(buildDocument(), data);
      if (!_meta.pendingPush) _markSynced();
    }
    if (_meta.pendingPush) await _push();
  }

  Future<void> _push() async {
    final s = _session;
    final epoch = _sessionEpoch;
    if (s == null || !_meta.pendingPush || !_currentSession(s, epoch)) return;
    if (_meta.version == null) return _pullAndPush();
    RemoteDoc r;
    try {
      r = await _put(s.token, _meta.version!, buildDocument());
    } on SyncConflict catch (c) {
      if (!_currentSession(s, epoch)) return;
      final current = c.current.data;
      if (current == null && c.current.version > 0) {
        _meta.version = c.current.version;
        _meta.localDeleteRevisionPending = false;
        _meta.pendingPush = false;
        _markSynced();
        return;
      }
      if (current != null) {
        _apply(mergeDocuments(buildDocument(), current, nowMs: _now));
      }
      r = await _put(s.token, c.current.version, buildDocument());
    }
    if (!_currentSession(s, epoch)) return;
    _meta.version = r.version;
    _meta.pendingPush = false;
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
      if (_session?.token != token) {
        throw AccountException(AccountErrorKind.unauthorized);
      }
      final places = [
        for (final p in AccountMerger.maps(doc['saved_places']))
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
    _meta.lastSynced = _clock();
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
    final epoch = ++_sessionEpoch;
    _busy = true;
    notifyListeners();
    try {
      final s = register
          ? await _api.register(email, password)
          : await _api.login(email, password);
      if (_disposed || epoch != _sessionEpoch) return serverChangedMessage;
      await _persistSession(s);
      if (_disposed || epoch != _sessionEpoch) return serverChangedMessage;
      _session = s;
      _resetSyncMeta();
      _notice = null;
      _busy = false;
      notifyListeners();
      await syncNow();
      return null;
    } on AccountException catch (e) {
      if (_disposed || epoch != _sessionEpoch) return serverChangedMessage;
      return e.message;
    } catch (e) {
      debugPrint('AccountProvider.signIn: $e');
      return 'Không lưu được phiên đăng nhập trên thiết bị này.';
    } finally {
      if (_busy && !_disposed && epoch == _sessionEpoch) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// Dang xuat (thu hoi token tren may chu neu duoc). Du lieu tren may giu.
  Future<void> signOut() async {
    final s = _session;
    if (s == null) return;
    final revocation = _api.logout(s.token).onError<AccountException>((e, _) {
      debugPrint('AccountProvider.logout: $e');
    });
    await _clearSession();
    await revocation;
  }

  /// "Xóa dữ liệu đồng bộ" (giu tai khoan + du lieu tren may).
  Future<String?> deleteSyncedData() => _guard((t) async {
    await _api.deleteData(t);
    if (_session?.token != t) return;
    _meta.version = null;
    _meta.pendingPush = false;
    _meta.localDeleteRevisionPending = true;
    try {
      final deleted = await _api.getData(t);
      if (_session?.token != t) return;
      if (deleted.data == null) _meta.version = deleted.version;
      _meta.localDeleteRevisionPending = false;
    } on AccountException catch (e) {
      if (e.kind == AccountErrorKind.unauthorized) rethrow;
      // Deletion succeeded; a failed revision read must not report a failed deletion.
    }
    _saveMeta();
  }, stopSync: true);

  /// "Xóa tài khoản" (nhap lai mat khau).
  Future<String?> deleteAccount(String password) => _guard((t) async {
    await _api.deleteAccount(t, password);
    if (_session?.token != t) return;
    await _clearSession();
  }, stopSync: true);

  /// JSON toan bo du lieu tren may chu (GET /me/export).
  Future<String> exportServerData() async {
    final s = _session;
    final epoch = _sessionEpoch;
    if (s == null) throw AccountException(AccountErrorKind.unauthorized);
    try {
      final result = await _api.export(s.token);
      if (!_currentSession(s, epoch)) {
        throw AccountException(AccountErrorKind.unauthorized);
      }
      return result;
    } on AccountException catch (e) {
      if (e.kind == AccountErrorKind.unauthorized &&
          _currentSession(s, epoch)) {
        await _expire();
      }
      rethrow;
    }
  }

  /// JSON du lieu tren may (khong can tai khoan). Co ca thoi quen va id
  /// "Vị trí hiện tại" (chi id phuong/xa, khong co toa do).
  String exportLocalData() => AccountDocBuilder.exportLocalData(
    doc: buildDocument(),
    clock: _clock,
    pp: _pp,
    lp: _lp,
    email: email,
  );

  Future<Map<String, String>> privacyPolicy() => _api.privacy();

  Future<String?> _guard(
    Future<void> Function(String token) f, {
    bool stopSync = false,
  }) async {
    final s = _session;
    var epoch = _sessionEpoch;
    if (s == null || _busy || !_currentSession(s, epoch)) return null;
    final resumeSync =
        _syncing ||
        _meta.pendingPush ||
        (_debounceTimer?.isActive ?? false) ||
        (_retryTimer?.isActive ?? false);
    var failed = false;
    if (stopSync) {
      epoch = ++_sessionEpoch;
      _debounceTimer?.cancel();
      _retryTimer?.cancel();
      _syncing = false;
      _again = false;
      _state = SyncState.idle;
      _error = null;
      _api.bindSession(s);
    }
    _busy = true;
    notifyListeners();
    try {
      await f(s.token);
      return null;
    } on AccountException catch (e) {
      failed = true;
      if (!_currentSession(s, epoch)) return serverChangedMessage;
      if (e.kind == AccountErrorKind.unauthorized) {
        await _expire();
        return expiredMessage;
      }
      return e.message;
    } finally {
      if (!_disposed && epoch == _sessionEpoch) {
        _busy = false;
        if (stopSync && (_meta.pendingPush || (failed && resumeSync))) {
          _state = SyncState.pending;
          _retryTimer = Timer(retryDelay, () => _run(_pullAndPush));
        }
        notifyListeners();
      }
    }
  }

  Future<void> _clearSession() async {
    _sessionEpoch++;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _session = null;
    _api.bindSession(null);
    _syncing = false;
    _again = false;
    _busy = false;
    _resetSyncMeta();
    _state = SyncState.idle;
    _error = null;
    _saveMeta();
    if (!_disposed) notifyListeners();
    await _persistSession(null);
  }

  /// Token het han / bi thu hoi: dang xuat em va bao.
  Future<void> _expire() async {
    await _clearSession();
    _notice = expiredMessage;
    if (_disposed) return;
    notifyListeners();
    final ctx = navigatorKey.currentState?.overlay?.context;
    if (ctx != null && ctx.mounted && !_expiredAlertOpen) {
      _expiredAlertOpen = true;
      showAppAlert<bool>(
            ctx,
            title: expiredAlertTitle,
            message: expiredAlertMessage,
            actions: const [
              AppDialogAction(label: 'Để sau', value: false),
              AppDialogAction(
                label: 'Đăng nhập lại',
                value: true,
                isDefault: true,
              ),
            ],
          )
          .then((signIn) {
            _expiredAlertOpen = false;
            // "Đăng nhập lại": mo man Tai khoan (form dang nhap).
            if (signIn ?? false) {
              navigatorKey.currentState?.push(
                MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
              );
            }
          })
          .whenComplete(() => _expiredAlertOpen = false);
    }
  }

  void _resetSyncMeta() => _meta.reset();

  Future<void> _loadMeta(AuthSession? session) => _meta.load(session, metaKey);

  Future<void> _saveMeta() => _meta.save(_session, metaKey, _now);
}
