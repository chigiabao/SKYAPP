import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/hcm_time.dart';

/// Doc / ghi [AppSettings] tu SharedPreferences.
class AppSettingsStore {
  const AppSettingsStore._();

  static const String replayEnabledKey = 'replayEnabled';

  /// Thoi diem xem lai, gio TP.HCM dang ISO "...+07:00".
  static const String replayAtKey = 'replayAt';

  static AppSettings fromPrefs(SharedPreferences prefs) {
    final replayAt = HcmTime.tryParse(prefs.getString(replayAtKey));
    return AppSettings(
      // Khong co thoi diem hop le -> khong the xem lai
      replayEnabled:
          replayAt != null && (prefs.getBool(replayEnabledKey) ?? false),
      replayAt: replayAt,
    );
  }

  /// Doc an toan; loi -> mac dinh.
  static Future<AppSettings> load() async {
    try {
      return fromPrefs(await SharedPreferences.getInstance());
    } catch (e) {
      debugPrint('AppSettings: load failed: $e');
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(replayEnabledKey, s.replayEnabled);
      final replayAt = s.replayAt;
      if (replayAt != null) {
        await prefs.setString(replayAtKey, HcmTime.toIso(replayAt));
      } else {
        await prefs.remove(replayAtKey);
      }
    } catch (e) {
      debugPrint('AppSettings: save failed: $e');
    }
  }
}
