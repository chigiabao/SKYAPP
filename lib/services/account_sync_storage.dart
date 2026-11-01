import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_merger.dart';
import 'account_service.dart';

/// Cac thong so theo doi tien trinh va phien ban dong bo.
class SyncMetadata {
  int? version;
  bool pendingPush = false;
  bool localDeleteRevisionPending = false;
  int placesAt = 0;
  int settingsAt = 0;
  int activitiesAt = 0;
  Map<String, int> deleted = {};
  Map<String, int> added = {};
  DateTime? lastSynced;

  void reset() {
    version = null;
    pendingPush = false;
    localDeleteRevisionPending = false;
    lastSynced = null;
  }

  Future<void> load(AuthSession? session, String metaKey) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(metaKey);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is! Map) return;
      int i(String k) => j[k] is int ? j[k] as int : 0;
      final sameAccount =
          session != null &&
          j['server_url'] == session.serverUrl &&
          j['account_email'] == session.email;
      version = sameAccount && j['version'] is int ? j['version'] as int : null;
      pendingPush = sameAccount && j['pending'] == true;
      localDeleteRevisionPending =
          sameAccount && j['local_delete_revision_pending'] == true;
      placesAt = i('places_at');
      settingsAt = i('settings_at');
      activitiesAt = i('activities_at');
      Map<String, int> m(String k) => {
        if (j[k] is Map)
          for (final e in (j[k] as Map).entries)
            if (e.value is int) '${e.key}': e.value as int,
      };
      deleted = m('deleted_places');
      added = m('places_added_at');
      final last = j['last_synced'];
      lastSynced = sameAccount && last is int
          ? DateTime.fromMillisecondsSinceEpoch(last)
          : null;
    } catch (e) {
      debugPrint('SyncMetadata.load: $e');
    }
  }

  Future<void> save(AuthSession? session, String metaKey, int nowMs) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        metaKey,
        jsonEncode({
          'server_url': session?.serverUrl,
          'account_email': session?.email,
          'version': version,
          'pending': pendingPush,
          'local_delete_revision_pending': localDeleteRevisionPending,
          'places_at': placesAt,
          'settings_at': settingsAt,
          'activities_at': activitiesAt,
          'deleted_places': AccountMerger.pruned(deleted, nowMs),
          'places_added_at': AccountMerger.pruned(added, nowMs),
          'last_synced': lastSynced?.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      debugPrint('SyncMetadata.save: $e');
    }
  }
}
