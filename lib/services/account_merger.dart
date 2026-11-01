import 'dart:math' as math;

/// Gop du lieu dong bo giua cac thiet bi theo quy tac LWW (Last-Write-Wins)
/// va Hop (Union) danh sach / thoi quen.
class AccountMerger {
  const AccountMerger._();

  static const tombstoneDays = 30;
  static const tombstoneMs = tombstoneDays * 86400000;

  static int ts(Map<String, dynamic>? doc, String key) {
    final s = doc?['settings'];
    final v = s is Map ? s[key] : null;
    return v is num ? v.toInt() : 0;
  }

  static List<Map<String, dynamic>> maps(Object? l) => [
    if (l is List)
      for (final e in l)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  /// Hop hai danh sach theo `id`: [first] dung truoc va thang khi trung.
  static List<Map<String, dynamic>> unionById(
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
  static Map<String, int> pruned(Map<String, int> m, int nowMs) => {
    for (final e in m.entries)
      if (nowMs - e.value <= tombstoneMs) e.key: e.value,
  };

  static Map<String, int> stamps(Map<String, dynamic>? doc, String key) {
    final s = doc?['settings'];
    final m = s is Map ? s[key] : null;
    return {
      if (m is Map)
        for (final e in m.entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
  }

  /// Gop hai map id -> ms, lay ms lon hon.
  static Map<String, int> maxStamps(Map<String, int> a, Map<String, int> b) => {
    for (final k in {...a.keys, ...b.keys}) k: math.max(a[k] ?? 0, b[k] ?? 0),
  };

  static List<Map<String, dynamic>> sortedPlaces(Object? l) => maps(l)
    ..sort(
      (a, b) =>
          ((a['order'] as num?) ?? 0).compareTo((b['order'] as num?) ?? 0),
    );

  /// Gop [local] va [remote] (tai lieu dang PUT /me/data).
  static Map<String, dynamic> mergeDocuments(
    Map<String, dynamic> local,
    Map<String, dynamic> remote, {
    bool union = true,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final added = pruned(
      maxStamps(
        stamps(local, 'places_added_at'),
        stamps(remote, 'places_added_at'),
      ),
      now,
    );
    final deleted = pruned(
      maxStamps(
        stamps(local, 'deleted_places'),
        stamps(remote, 'deleted_places'),
      ),
      now,
    )..removeWhere((id, t) => (added[id] ?? 0) > t);
    final localPlaces =
        ts(local, 'places_updated_at') > ts(remote, 'places_updated_at');
    final pNew = sortedPlaces((localPlaces ? local : remote)['saved_places']);
    final pOld = sortedPlaces((localPlaces ? remote : local)['saved_places']);
    final places = [
      for (final p in union ? unionById(pNew, pOld) : pNew)
        if (!deleted.containsKey('${p['id']}')) p,
    ];

    final localActs =
        ts(local, 'activities_updated_at') >
        ts(remote, 'activities_updated_at');
    final aNew = maps((localActs ? local : remote)['activities']);
    final aOld = maps((localActs ? remote : local)['activities']);

    final localSettings = ts(local, 'updated_at') > ts(remote, 'updated_at');
    final s = (localSettings ? local : remote)['settings'];
    final settings = <String, dynamic>{
      if (s is Map) ...Map<String, dynamic>.from(s),
    };
    for (final k in const [
      'updated_at',
      'places_updated_at',
      'activities_updated_at',
    ]) {
      settings[k] = math.max(ts(local, k), ts(remote, k));
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
      'activities': union ? unionById(aNew, aOld) : aNew,
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
}
