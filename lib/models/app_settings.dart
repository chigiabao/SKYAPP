/// Cai dat che do xem lai (gia tri thuan). Doc / ghi qua `AppSettingsStore`
/// (services/app_settings_store.dart) TRUOC runApp.
///
/// °C/°F nay o `PreferencesProvider` (khoa cu 'isCelsius' duoc chuyen doi
/// khi doc lan dau).
class AppSettings {
  /// Che do xem lai dang bat.
  final bool replayEnabled;

  /// Thoi diem xem lai da chon (gio TP.HCM); giu ca khi tat de bat lai nhanh.
  final DateTime? replayAt;

  const AppSettings({this.replayEnabled = false, this.replayAt});
}
