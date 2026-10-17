import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Phien ban app doc tu goi cai dat (package_info_plus, theo `version` trong
/// pubspec.yaml). Truoc khi [load] xong / khi loi: [fallback].
abstract final class AppVersion {
  /// Du phong (giu khop pubspec.yaml).
  static const String fallback = '1.1.0';

  static String _current = fallback;

  /// "1.1.0" (khong kem so build).
  static String get current => _current;

  /// Goi mot lan khi khoi dong app.
  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _current = info.version;
    } catch (e) {
      debugPrint('AppVersion.load: $e');
    }
  }
}
