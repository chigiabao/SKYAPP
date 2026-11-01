import 'dart:convert';

import '../models/activities.dart';
import '../models/habits.dart';
import '../models/place.dart';
import '../models/weather_alerts.dart';
import '../services/account_merger.dart';
import 'location_provider.dart';
import 'planner_provider.dart';
import 'preferences_provider.dart';

/// Chuyen doi qua lai giua cac Provider va JSON document PUT /me/data.
class AccountDocBuilder {
  const AccountDocBuilder._();

  static String _hhmm(int h) => '${h.toString().padLeft(2, '0')}:00';

  static String? cut(String? s, int max) =>
      s == null || s.length <= max ? s : s.substring(0, max);

  static List<Map<String, dynamic>> placesJson(LocationProvider? lp) {
    final saved = lp?.saved ?? const <SavedPlace>[];
    return [
      for (var i = 0; i < saved.length; i++)
        {
          'id': saved[i].locationId,
          'label': saved[i].label.name,
          'custom_name': cut(saved[i].customName, 100),
          'order': i,
        },
    ];
  }

  static Map<String, dynamic> settingsCore(
    PlannerProvider? pp,
    PreferencesProvider? prefs,
  ) {
    final a = pp?.settings ?? const AlertSettings();
    return {
      if (prefs != null)
        'units': {'temperature': prefs.units.isCelsius ? 'c' : 'f'},
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
      if (prefs != null) 'preferences': prefs.exportSettings(),
    };
  }

  static List<Map<String, dynamic>> activitiesJson(PlannerProvider? pp) => [
    for (final r in pp?.routines ?? const <ActivityRoutine>[]) r.toJson(),
  ];

  static Map<String, dynamic> buildDocument({
    required LocationProvider? lp,
    required PlannerProvider? pp,
    required PreferencesProvider? prefs,
    required int settingsAt,
    required int placesAt,
    required int activitiesAt,
    required Map<String, int> deleted,
    required Map<String, int> added,
    required int nowMs,
  }) {
    final habitsConsent = pp?.habits.enabled ?? false;
    return {
      'saved_places': placesJson(lp),
      'settings': {
        ...settingsCore(pp, prefs),
        'updated_at': settingsAt,
        'places_updated_at': placesAt,
        'activities_updated_at': activitiesAt,
        'deleted_places': AccountMerger.pruned(deleted, nowMs),
        'places_added_at': AccountMerger.pruned(added, nowMs),
      },
      'activities': activitiesJson(pp),
      'habits_consent': habitsConsent,
      'habits': habitsConsent ? pp!.habits.toJson() : null,
    };
  }

  static Map<String, String> buildSections({
    required LocationProvider? lp,
    required PlannerProvider? pp,
    required PreferencesProvider? prefs,
  }) {
    final habitsConsent = pp?.habits.enabled ?? false;
    return {
      'places': jsonEncode(placesJson(lp)),
      'settings': jsonEncode(settingsCore(pp, prefs)),
      'activities': jsonEncode(activitiesJson(pp)),
      'habits': jsonEncode(habitsConsent ? pp!.habits.toJson() : null),
    };
  }

  /// Ap tai lieu da gop vao cac provider.
  static void applyDocument(
    Map<String, dynamic> doc, {
    required LocationProvider? lp,
    required PlannerProvider? pp,
    required PreferencesProvider? prefs,
  }) {
    final places = [
      for (final p in AccountMerger.sortedPlaces(doc['saved_places']))
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
    final raw = s['preferences'];
    // Ban app cu con gui 'themeMode' (da bo): bo qua truoc khi so sanh.
    final pj = raw is Map
        ? (Map<String, dynamic>.from(raw)..remove('themeMode'))
        : null;
    if (prefs != null &&
        pj != null &&
        jsonEncode(pj) != jsonEncode(prefs.exportSettings())) {
      prefs.importSettings(pj);
    }
    // Truong cap tren (tuong thich ban cu khong luu °C/°F trong preferences).
    if (prefs != null) {
      final units = s['units'];
      final t = units is Map ? units['temperature'] : null;
      if (t == 'c' || t == 'f') prefs.setTemperatureUnit(t == 'c');
    }
    if (pp != null) {
      final alerts = s['alerts'];
      final fav = s['activity_favorites'];
      final sens = Sensitivity.values.where(
        (x) => x.name == s['activity_sensitivity'],
      );
      final habits = doc['habits'];
      final habitsConsent = pp.habits.enabled;
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
        habits: habitsConsent && habits is Map
            ? HabitData.fromJson(Map<String, dynamic>.from(habits))
            : null,
      );
    }
  }

  static String exportLocalData({
    required Map<String, dynamic> doc,
    required DateTime Function() clock,
    required PlannerProvider? pp,
    required LocationProvider? lp,
    required String? email,
  }) {
    return const JsonEncoder.withIndent('  ').convert({
      'exported_at': clock().toUtc().toIso8601String(),
      'app': 'Sky Weather',
      'note':
          'Dữ liệu lưu trên thiết bị này. Không có tọa độ GPS; '
          'vị trí hiện tại chỉ lưu mã phường/xã.',
      ...doc,
      'habits': pp?.habits.toJson(),
      'current_location_id': lp?.currentLocationId,
      'notification_settings': pp?.notifySettings.toJson(),
      'account_email': email,
    });
  }
}
