import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hcm_time.dart';

/// Cai dat nguoi dung, doc tu SharedPreferences TRUOC runApp de tranh
/// nhay giao dien sang/toi o frame dau.
class AppSettings {
  static const String themeModeKey = 'themeMode'; // 'system' | 'light' | 'dark'
  static const String legacyDarkModeKey = 'isDarkMode'; // ban cu (bool)
  static const String celsiusKey = 'isCelsius';
  static const String replayEnabledKey = 'replayEnabled';

  /// Thoi diem xem lai, gio TP.HCM dang ISO "...+07:00".
  static const String replayAtKey = 'replayAt';

  final ThemeMode themeMode;
  final bool isCelsius;

  /// Che do xem lai dang bat.
  final bool replayEnabled;

  /// Thoi diem xem lai da chon (gio TP.HCM); giu ca khi tat de bat lai nhanh.
  final DateTime? replayAt;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.isCelsius = true,
    this.replayEnabled = false,
    this.replayAt,
  });

  factory AppSettings.fromPrefs(SharedPreferences prefs) {
    ThemeMode mode = ThemeMode.system;
    final stored = prefs.getString(themeModeKey);
    if (stored != null) {
      mode = ThemeMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => ThemeMode.system,
      );
    } else {
      // Chuyen tu ban cu: chi co cong tac Sang/Toi
      final legacyDark = prefs.getBool(legacyDarkModeKey);
      if (legacyDark != null) {
        mode = legacyDark ? ThemeMode.dark : ThemeMode.light;
      }
    }
    final replayAt = HcmTime.tryParse(prefs.getString(replayAtKey));
    return AppSettings(
      themeMode: mode,
      isCelsius: prefs.getBool(celsiusKey) ?? true,
      // Khong co thoi diem hop le -> khong the xem lai
      replayEnabled:
          replayAt != null && (prefs.getBool(replayEnabledKey) ?? false),
      replayAt: replayAt,
    );
  }

  /// Doc an toan; loi -> mac dinh.
  static Future<AppSettings> load() async {
    try {
      return AppSettings.fromPrefs(await SharedPreferences.getInstance());
    } catch (e) {
      debugPrint('AppSettings: load failed: $e');
      return const AppSettings();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(themeModeKey, themeMode.name);
      await prefs.setBool(celsiusKey, isCelsius);
      await prefs.setBool(replayEnabledKey, replayEnabled);
      if (replayAt != null) {
        await prefs.setString(replayAtKey, HcmTime.toIso(replayAt!));
      } else {
        await prefs.remove(replayAtKey);
      }
    } catch (e) {
      debugPrint('AppSettings: save failed: $e');
    }
  }
}
