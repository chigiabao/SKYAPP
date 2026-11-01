part of '../planner_provider.dart';

class _PlannerLoadedData {
  const _PlannerLoadedData({
    this.settings,
    required this.history,
    required this.ledger,
    this.favorites,
    this.sensitivity,
    this.routines,
    this.notifySettings,
    this.commute,
    this.habits,
  });

  final AlertSettings? settings;
  final List<AlertNotice> history;
  final List<AlertNotice> ledger;
  final List<Activity>? favorites;
  final Sensitivity? sensitivity;
  final List<ActivityRoutine>? routines;
  final NotifySettings? notifySettings;
  final CommuteSettings? commute;
  final HabitData? habits;
}

class _PlannerStorage {
  static Future<SharedPreferences?> freshPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return p;
    } catch (e) {
      debugPrint('PlannerProvider.reload: $e');
      return null;
    }
  }

  static List<AlertNotice>? readNotices(SharedPreferences p, String key) {
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

  static Future<void> putNotices(
    SharedPreferences? p,
    String key,
    List<AlertNotice> v,
  ) async {
    if (p == null) return;
    await p.setString(key, jsonEncode([for (final n in v) n.toJson()]));
  }

  static Future<void> writeNow(String key, Object value) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(value));
    } catch (e) {
      debugPrint('PlannerProvider.save: $e');
    }
  }

  static _PlannerLoadedData loadAll(SharedPreferences p) {
    AlertSettings? settings;
    final s = p.getString(PlannerProvider.alertSettingsKey);
    if (s != null) {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) settings = AlertSettings.fromJson(j);
    }
    final history = readNotices(p, PlannerProvider.historyKey) ?? const [];
    final ledger = readNotices(p, PlannerProvider.ledgerKey) ?? const [];

    List<Activity>? favorites;
    Sensitivity? sensitivity;
    List<ActivityRoutine>? routines;
    final a = p.getString(PlannerProvider.activityKey);
    if (a != null) {
      final j = jsonDecode(a);
      if (j is Map) {
        final fav = j['favorites'];
        if (fav is List) {
          favorites = [
            for (final f in fav) ...Activity.values.where((x) => x.name == f),
          ];
        }
        sensitivity = Sensitivity.values.firstWhere(
          (x) => x.name == j['sensitivity'],
          orElse: () => Sensitivity.normal,
        );
        final r = j['routines'];
        if (r is List) {
          routines = [for (final e in r) ?ActivityRoutine.tryFromJson(e)];
        }
      }
    }

    NotifySettings? notifySettings;
    final n = p.getString(PlannerProvider.notifyKey);
    if (n != null) {
      final j = jsonDecode(n);
      if (j is Map<String, dynamic>) {
        notifySettings = NotifySettings.fromJson(j);
      }
    }

    CommuteSettings? commute;
    final cm = p.getString(PlannerProvider.commuteKey);
    if (cm != null) {
      final j = jsonDecode(cm);
      if (j is Map<String, dynamic>) commute = CommuteSettings.fromJson(j);
    }

    HabitData? habits;
    final hb = p.getString(PlannerProvider.habitKey);
    if (hb != null) {
      final j = jsonDecode(hb);
      if (j is Map<String, dynamic>) habits = HabitData.fromJson(j);
    }

    return _PlannerLoadedData(
      settings: settings,
      history: history,
      ledger: ledger,
      favorites: favorites,
      sensitivity: sensitivity,
      routines: routines,
      notifySettings: notifySettings,
      commute: commute,
      habits: habits,
    );
  }
}
