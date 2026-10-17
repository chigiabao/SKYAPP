import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activities.dart';
import '../models/habits.dart';
import '../models/reminders.dart';
import '../models/weather.dart';
import '../models/weather_alerts.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import 'location_provider.dart';
import 'preferences_provider.dart';
import 'weather_provider.dart';

/// Cai dat canh bao + lich su thong bao trong app + hoat dong yeu thich /
/// lich hoat dong. Tinh toan tren thiet bi; luu bang SharedPreferences.
///
/// Thong bao luon hien trong app (banner, huy hieu, lich su). Khi nguoi dung
/// bat "Thông báo hệ thống" (xin quyen luc do) thi them thong bao Android qua
/// [NotificationService] + nhac truoc gio hoat dong + kiem tra dinh ky o nen
/// ([onBackgroundChanged]). Che do xem lai khong gui / khong hen gi.
class PlannerProvider extends ChangeNotifier {
  PlannerProvider({
    NotificationService? notifications,
    this.onBackgroundChanged,
    DateTime Function()? clock,
  }) : _notify = notifications ?? const NoopNotificationService(),
       _clock = clock ?? DateTime.now;

  static const String alertSettingsKey = 'planner_alert_settings_v1';
  static const String historyKey = 'planner_alert_history_v1';
  static const String activityKey = 'planner_activity_v1';
  static const String notifyKey = 'planner_notify_v1';
  static const String habitKey = 'planner_habits_v1';

  /// So chong trung rieng (khong phai lich su hien thi): "Xoá lịch sử" hay
  /// gioi han [historyLimit] khong lam gui lai canh bao con hieu luc. Muc co
  /// `end` < bay gio bi don.
  static const String ledgerKey = 'planner_alert_ledger_v1';

  final NotificationService _notify;
  final DateTime Function() _clock;

  /// Bat / tat kiem tra dinh ky o nen (workmanager); null = khong co (test,
  /// isolate nen).
  final Future<void> Function(bool enabled)? onBackgroundChanged;

  /// So muc lich su toi da.
  static const int historyLimit = 50;

  AlertSettings _settings = const AlertSettings();
  List<AlertNotice> _history = const [];
  List<AlertNotice> _ledger = const [];
  List<Activity> _favorites = kDefaultFavorites;
  Sensitivity _sensitivity = Sensitivity.normal;
  List<ActivityRoutine> _routines = const [];
  bool _loaded = false;
  Future<void>? _loading;

  /// Chuoi ghi lich su / so chong trung (lan luot, khong chen nhau).
  Future<void> _queue = Future.value();
  AppLifecycleListener? _lifecycle;
  int _held = 0;
  NotifySettings _notifySettings = const NotifySettings();
  HabitData _habits = const HabitData();
  ReminderPlan _reminders = const ReminderPlan([], 0);
  final Set<Future<void>> _pending = {};

  /// Du lieu theo gio TRUC TIEP (khong phai xem lai) - dung cho nhac.
  final Map<String, List<HourlyForecast>> _liveHours = {};
  final Map<String, String> _names = {};

  /// Canh bao moi nhat theo dia diem (sau [refreshAll] / [record]).
  final Map<String, List<AlertEvent>> _byPlace = {};

  /// Du lieu theo gio da tai cho tung dia diem (man Canh bao / Hoat dong).
  final Map<String, List<HourlyForecast>> _hours = {};
  final Map<String, ApiErrorKind> _errors = {};
  bool _refreshing = false;

  AlertSettings get settings => _settings;
  List<AlertNotice> get history => _history;
  List<Activity> get favorites => _favorites;
  Sensitivity get sensitivity => _sensitivity;
  List<ActivityRoutine> get routines => _routines;
  bool get isLoaded => _loaded;
  NotifySettings get notifySettings => _notifySettings;
  HabitData get habits => _habits;

  /// Nhac da hen (lan len lich gan nhat).
  ReminderPlan get reminderPlan => _reminders;
  DateTime get realNowHcm => HcmTime.now(_clock);
  bool get refreshing => _refreshing;
  int get unreadCount => _history.where((n) => !n.read).length;

  /// Canh bao bi giu lai trong lan danh gia gan nhat do gio yen lang.
  int get heldByQuietHours => _held;

  Map<String, List<AlertEvent>> get alertsByPlace => Map.unmodifiable(_byPlace);
  List<HourlyForecast>? hoursFor(String id) => _hours[id];
  ApiErrorKind? errorFor(String id) => _errors[id];

  /// Doc du lieu da luu (mot lan; goi lai tra ve cung Future).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(alertSettingsKey);
      if (s != null) {
        final j = jsonDecode(s);
        if (j is Map<String, dynamic>) _settings = AlertSettings.fromJson(j);
      }
      _history = _readNotices(p, historyKey) ?? const [];
      _ledger = _readNotices(p, ledgerKey) ?? const [];
      final a = p.getString(activityKey);
      if (a != null) {
        final j = jsonDecode(a);
        if (j is Map) {
          final fav = j['favorites'];
          if (fav is List) {
            _favorites = [
              for (final f in fav) ...Activity.values.where((x) => x.name == f),
            ];
          }
          _sensitivity = Sensitivity.values.firstWhere(
            (x) => x.name == j['sensitivity'],
            orElse: () => Sensitivity.normal,
          );
          final r = j['routines'];
          if (r is List) {
            _routines = [for (final e in r) ?ActivityRoutine.tryFromJson(e)];
          }
        }
      }
      final n = p.getString(notifyKey);
      if (n != null) {
        final j = jsonDecode(n);
        if (j is Map<String, dynamic>) {
          _notifySettings = NotifySettings.fromJson(j);
        }
      }
      final hb = p.getString(habitKey);
      if (hb != null) {
        final j = jsonDecode(hb);
        if (j is Map<String, dynamic>) _habits = HabitData.fromJson(j);
      }
    } catch (e) {
      // Khong co plugin (test) / du lieu hong -> mac dinh.
      debugPrint('PlannerProvider.load: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// App mo lai (AppLifecycleState.resumed) -> doc lai lich su ma tac vu nen
  /// co the da ghi. Goi mot lan trong app that.
  void attachLifecycle() {
    _lifecycle ??= AppLifecycleListener(onResume: () => syncFromDisk());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Doc lai lich su + so chong trung (isolate khac co the da ghi) va gop
  /// voi ban trong bo nho.
  Future<void> syncFromDisk() => _serial(() async {
    await load();
    final p = await _freshPrefs();
    if (p == null) return;
    _history = mergeNotices(
      _readNotices(p, historyKey) ?? const [],
      _history,
    ).take(historyLimit).toList();
    _ledger = mergeNotices(_readNotices(p, ledgerKey) ?? const [], _ledger);
    notifyListeners();
  });

  /// Chay [f] sau moi lan ghi lich su truoc do (trong isolate nay).
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _queue.then((_) => f());
    final done = r.then<void>(
      (_) {},
      onError: (Object e) => debugPrint('PlannerProvider: $e'),
    );
    _queue = done;
    _track(done);
    return r;
  }

  /// SharedPreferences da `reload()` (thay ban ghi cua isolate khac); null
  /// neu khong co plugin.
  Future<SharedPreferences?> _freshPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return p;
    } catch (e) {
      debugPrint('PlannerProvider.reload: $e');
      return null;
    }
  }

  static List<AlertNotice>? _readNotices(SharedPreferences p, String key) {
    try {
      final h = p.getString(key);
      if (h == null) return null;
      final j = jsonDecode(h);
      if (j is! List) return null;
      return [for (final e in j) ?AlertNotice.tryFromJson(e)];
    } catch (e) {
      debugPrint('PlannerProvider.read $key: $e');
      return null;
    }
  }

  static Future<void> _putNotices(
    SharedPreferences? p,
    String key,
    List<AlertNotice> v,
  ) async {
    if (p == null) return;
    await p.setString(key, jsonEncode([for (final n in v) n.toJson()]));
  }

  /// Cho moi lan ghi / gui dang do (isolate nen can truoc khi ket thuc).
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait([..._pending]);
    }
  }

  Future<void> _write(String key, Object value) {
    final f = _writeNow(key, value);
    _track(f);
    return f;
  }

  void _track(Future<void> f) {
    final g = f.catchError((Object e) => debugPrint('PlannerProvider: $e'));
    _pending.add(g);
    g.whenComplete(() => _pending.remove(g));
  }

  Future<void> _writeNow(String key, Object value) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(value));
    } catch (e) {
      debugPrint('PlannerProvider.save: $e');
    }
  }

  Future<void> _saveActivity() => _write(activityKey, {
    'favorites': [for (final f in _favorites) f.name],
    'sensitivity': _sensitivity.name,
    'routines': [for (final r in _routines) r.toJson()],
  });

  // ---- Canh bao ----

  void setSettings(AlertSettings s) {
    final quietChanged =
        s.quietEnabled != _settings.quietEnabled ||
        s.quietStart != _settings.quietStart ||
        s.quietEnd != _settings.quietEnd;
    _settings = s;
    _byPlace.clear();
    notifyListeners();
    _write(alertSettingsKey, s.toJson());
    if (quietChanged) rescheduleReminders();
  }

  // ---- Thong bao he thong + nhac ----

  /// Bat / tat thong bao he thong. Bat -> xin quyen (chi luc nay); bi tu
  /// choi -> giu tat, tra ve false.
  Future<bool> setSystemNotifications(bool on) async {
    if (on) {
      final granted = await _notify.requestPermission();
      if (!granted) return false;
    }
    _notifySettings = _notifySettings.copyWith(system: on);
    notifyListeners();
    _write(notifyKey, _notifySettings.toJson());
    try {
      await onBackgroundChanged?.call(on);
    } catch (e) {
      debugPrint('PlannerProvider.background: $e');
    }
    await rescheduleReminders();
    return true;
  }

  void setReminders(bool on) {
    _notifySettings = _notifySettings.copyWith(reminders: on);
    notifyListeners();
    _write(notifyKey, _notifySettings.toJson());
    rescheduleReminders();
  }

  /// "Tôn trọng giờ yên lặng cho lời nhắc" (mac dinh tat).
  void setReminderQuiet(bool on) {
    _notifySettings = _notifySettings.copyWith(reminderQuiet: on);
    notifyListeners();
    _write(notifyKey, _notifySettings.toJson());
    rescheduleReminders();
  }

  void setReminderMinutes(int minutes) {
    _notifySettings = _notifySettings.copyWith(minutesBefore: minutes);
    notifyListeners();
    _write(notifyKey, _notifySettings.toJson());
    rescheduleReminders();
  }

  /// Dong bo tac vu nen voi cai dat da luu (goi luc mo app).
  Future<void> syncBackground() async {
    try {
      await onBackgroundChanged?.call(_notifySettings.system);
    } catch (e) {
      debugPrint('PlannerProvider.background: $e');
    }
  }

  /// Huy nhac cu va hen lai theo lich + du bao truc tiep moi nhat (gio
  /// TP.HCM that, khong phai gio xem lai). Tat -> chi huy.
  Future<void> rescheduleReminders() async {
    final now = realNowHcm;
    final plan = _notifySettings.system && _notifySettings.reminders
        ? planReminders(
            _routines,
            nowHcm: now,
            minutesBefore: _notifySettings.minutesBefore,
            quiet: _settings,
            respectQuiet: _notifySettings.reminderQuiet,
            hoursFor: (id) => _liveHours[id],
            placeName: (id) => _names[id] ?? '',
          )
        : const ReminderPlan([], 0);
    _reminders = plan;
    notifyListeners();
    Future<void> apply() async {
      await _notify.cancelScheduled();
      for (final r in plan.reminders) {
        await _notify.schedule(r.id, r.fireAt, r.title, r.body);
      }
    }

    final f = apply();
    _track(f);
    await f.catchError((Object _) {});
  }

  /// Canh bao cua mot dia diem tu du lieu co san (khong ghi lich su).
  List<AlertEvent> alertsFor(
    String placeId,
    List<HourlyForecast> hours,
    DateTime nowHcm,
  ) => evaluateAlerts(
    hours,
    nowHcm: nowHcm,
    placeId: placeId,
    settings: _settings,
  );

  /// Danh gia [hours] cua [placeId] va ghi thong bao moi (chong trung). Che
  /// do xem lai ([replay]) chi tinh canh bao, khong ghi lich su.
  ///
  /// Chong trung dua tren so rieng ([ledgerKey]) doc lai ngay truoc khi ghi
  /// (tac vu nen workmanager o isolate khac co the vua ghi), chi sau khi
  /// [load] xong; cac lan ghi trong isolate nay chay lan luot.
  Future<List<AlertNotice>> record(
    String placeId,
    String placeName,
    List<HourlyForecast> hours,
    DateTime nowHcm, {
    bool replay = false,
  }) {
    final events = alertsFor(placeId, hours, nowHcm);
    _byPlace[placeId] = events;
    _hours[placeId] = hours;
    _names[placeId] = placeName;
    if (replay) {
      notifyListeners();
      return Future.value(const []);
    }
    _liveHours[placeId] = hours;
    return _serial(() async {
      await load();
      final p = await _freshPrefs();
      final history = p == null
          ? _history
          : _readNotices(p, historyKey) ?? const <AlertNotice>[];
      final stored = p == null
          ? _ledger
          : _readNotices(p, ledgerKey) ?? const <AlertNotice>[];
      // Lich su cu (truoc khi co so chong trung) cung duoc tinh; don muc het
      // hieu luc.
      final ledger = [
        for (final n in mergeNotices(stored, history))
          if (!n.end.isBefore(nowHcm)) n,
      ];
      final plan = planNotices(
        events,
        history: ledger,
        settings: _settings,
        nowHcm: nowHcm,
        placeName: placeName,
        units: PreferencesProvider.unitsFromPrefs(p),
      );
      _held = plan.held;
      final fresh = {for (final n in plan.notices) noticeKey(n)};
      _history = [
        ...plan.notices,
        for (final n in history)
          if (!fresh.contains(noticeKey(n))) n,
      ].take(historyLimit).toList();
      _ledger = mergeNotices(plan.notices, ledger);
      if (plan.notices.isNotEmpty || ledger.length != stored.length) {
        try {
          await _putNotices(p, historyKey, _history);
          await _putNotices(p, ledgerKey, _ledger);
        } catch (e) {
          debugPrint('PlannerProvider.save: $e');
        }
      }
      // Da qua chong trung + gio yen lang (planNotices).
      if (_notifySettings.system) {
        for (final n in plan.notices) {
          _track(
            _notify.show(
              alertNotificationId(n),
              n.title,
              '${n.body}\n$kAlertDisclaimer',
            ),
          );
        }
      }
      notifyListeners();
      return plan.notices;
    });
  }

  /// Tai du lieu moi dia diem (vi tri hien tai + da luu) roi danh gia.
  Future<void> refreshAll(WeatherProvider wp, LocationProvider lp) async {
    if (_refreshing) return;
    _refreshing = true;
    notifyListeners();
    final ids = <String>{for (final p in lp.pages) p.locationId};
    for (final id in ids) {
      List<HourlyForecast>? hours;
      if (id == wp.locationId && wp.weatherData != null) {
        hours = wp.hourlyForecast;
      } else {
        try {
          hours = (await wp.fetchWeatherFor(id)).data.hourlyForecast;
        } on ApiException catch (e) {
          _errors[id] = e.kind;
        } catch (e) {
          debugPrint('PlannerProvider.refreshAll: $e');
          _errors[id] = ApiErrorKind.invalidData;
        }
      }
      if (hours != null) {
        _errors.remove(id);
        await record(
          id,
          lp.placeById(id).name,
          hours,
          wp.nowHcm,
          replay: wp.isReplay,
        );
      }
    }
    _refreshing = false;
    notifyListeners();
    if (!wp.isReplay) await rescheduleReminders();
  }

  void markAllRead() {
    if (unreadCount == 0) return;
    final seen = {for (final n in _history) noticeKey(n)};
    _history = [for (final n in _history) n.read ? n : n.markRead()];
    notifyListeners();
    _serial(() async {
      final p = await _freshPrefs();
      if (p == null) return;
      // Chi danh dau muc nguoi dung da thay; muc tac vu nen vua ghi giu nguyen.
      _history = mergeNotices([
        for (final n in _readNotices(p, historyKey) ?? const <AlertNotice>[])
          seen.contains(noticeKey(n)) && !n.read ? n.markRead() : n,
      ], _history).take(historyLimit).toList();
      await _putNotices(p, historyKey, _history);
      notifyListeners();
    });
  }

  /// Xoa lich su hien thi. So chong trung giu nguyen: canh bao con hieu luc
  /// khong bi gui lai.
  void clearHistory() {
    _history = const [];
    notifyListeners();
    _serial(() async {
      await _putNotices(await _freshPrefs(), historyKey, const []);
    });
  }

  /// Ghi du lieu truc tiep cua mot dia diem (khong danh gia canh bao) de
  /// nhac hoat dong co diem thoi tiet. Bo qua o che do xem lai.
  void noteLiveHours(
    String placeId,
    String placeName,
    List<HourlyForecast> hours, {
    bool replay = false,
  }) {
    if (replay || hours.isEmpty) return;
    _liveHours[placeId] = hours;
    _names[placeId] = placeName;
  }

  // ---- Hoat dong ----

  bool isFavorite(Activity a) => _favorites.contains(a);

  void toggleFavorite(Activity a) {
    _favorites = isFavorite(a)
        ? [
            for (final f in _favorites)
              if (f != a) f,
          ]
        : [..._favorites, a];
    notifyListeners();
    _saveActivity();
  }

  void setSensitivity(Sensitivity s) {
    _sensitivity = s;
    notifyListeners();
    _saveActivity();
  }

  void addRoutine(ActivityRoutine r) {
    _routines = [..._routines, r];
    notifyListeners();
    _saveActivity();
    rescheduleReminders();
  }

  /// Sua lich cung id.
  void updateRoutine(ActivityRoutine r) {
    _routines = [for (final x in _routines) x.id == r.id ? r : x];
    notifyListeners();
    _saveActivity();
    rescheduleReminders();
  }

  void removeRoutine(String id) {
    _routines = [
      for (final r in _routines)
        if (r.id != id) r,
    ];
    notifyListeners();
    _saveActivity();
    rescheduleReminders();
  }

  /// Dong bo tai khoan: nhan du lieu tu thiet bi khac (null = giu nguyen).
  /// Thong bao he thong / nhac (theo thiet bi) khong dong bo.
  void importSyncData({
    AlertSettings? alerts,
    List<Activity>? favorites,
    Sensitivity? sensitivity,
    List<ActivityRoutine>? routines,
    HabitData? habits,
  }) {
    if (alerts != null) {
      _settings = alerts;
      _byPlace.clear();
      _write(alertSettingsKey, alerts.toJson());
    }
    _favorites = favorites ?? _favorites;
    _sensitivity = sensitivity ?? _sensitivity;
    _routines = routines ?? _routines;
    if (favorites != null || sensitivity != null || routines != null) {
      _saveActivity();
    }
    if (habits != null) {
      _habits = habits;
      _write(habitKey, habits.toJson());
    }
    notifyListeners();
    if (alerts != null || routines != null) rescheduleReminders();
  }

  // ---- Thoi quen (habits.dart, chi tren may) ----

  void _setHabits(HabitData h) {
    _habits = h;
    notifyListeners();
    _write(habitKey, h.toJson());
  }

  void setHabitLearning(bool on) => _setHabits(_habits.copyWith(enabled: on));

  /// Ghi lan mo app (gio that). Khong ghi khi chua dong y.
  void recordAppOpen() {
    if (_habits.enabled) _setHabits(_habits.recordOpen(realNowHcm));
  }

  /// Ghi "Đã làm" [a] luc [nowHcm] (mac dinh gio that).
  void recordDone(Activity a, {DateTime? nowHcm}) {
    if (_habits.enabled) {
      _setHabits(_habits.recordDone(a, nowHcm ?? realNowHcm));
    }
  }

  void clearHabits() => _setHabits(_habits.cleared());

  void dismissSuggestion(RoutineSuggestion s) => _setHabits(_habits.dismiss(s));

  List<RoutineSuggestion> get routineSuggestions =>
      _habits.suggestions(_routines);
}

/// [PlannerProvider] neu co trong cay widget (app that), null neu khong
/// (mot so test chi cung cap WeatherProvider).
PlannerProvider? maybePlanner(BuildContext context, {bool listen = true}) {
  try {
    return Provider.of<PlannerProvider>(context, listen: listen);
  } on ProviderNotFoundException {
    return null;
  }
}
