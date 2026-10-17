import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cau hinh ket noi backend FastAPI - chi sua o mot noi nay.
///
/// Mac dinh: web -> http://localhost:8000 (trinh duyet tren chinh may chay
/// backend); con lai -> 10.0.2.2 (Android emulator -> may host).
/// Ghi de khi chay / build, vi du thiet bi that cung mang LAN:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
///
/// Nguoi dung co the ghi de luc chay (Cai dat > Nang cao > May chu du lieu):
/// [baseUrl] doc moi lan goi nen doi co hieu luc ngay, khong can build lai.
class ApiConfig {
  /// URL da build san (dart-define hoac mac dinh theo nen tang).
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: kIsWeb ? 'http://localhost:8000' : 'http://10.0.2.2:8000',
  );

  /// Khoa shared_preferences cua URL ghi de.
  static const String baseUrlKey = 'api_base_url_override';

  static String? _override;

  /// URL dang dung: ghi de cua nguoi dung, neu khong thi [defaultBaseUrl].
  static String get baseUrl => _override ?? defaultBaseUrl;

  /// URL ghi de hien tai (null = dung mac dinh).
  static String? get baseUrlOverride => _override;

  /// Chuan hoa URL nguoi dung nhap: bo khoang trang va '/' cuoi; chi nhan
  /// http/https co ten may. Sai -> null.
  static String? normalizeBaseUrl(String input) {
    var t = input.trim();
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    final uri = Uri.tryParse(t);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return t;
  }

  /// Doc URL ghi de da luu (goi truoc runApp). Gia tri hong -> bo qua.
  static Future<void> loadBaseUrl() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(baseUrlKey);
      _override = v == null ? null : normalizeBaseUrl(v);
    } catch (e) {
      debugPrint('ApiConfig.loadBaseUrl: $e');
    }
  }

  /// Dat (hoac xoa khi null) URL ghi de va luu. Tra ve false neu URL sai.
  static Future<bool> setBaseUrl(String? url) async {
    final String? next;
    if (url == null) {
      next = null;
    } else {
      next = normalizeBaseUrl(url);
      if (next == null) return false;
    }
    _override = next == defaultBaseUrl ? null : next;
    try {
      final p = await SharedPreferences.getInstance();
      if (_override == null) {
        await p.remove(baseUrlKey);
      } else {
        await p.setString(baseUrlKey, _override!);
      }
    } catch (e) {
      debugPrint('ApiConfig.setBaseUrl: $e');
    }
    return true;
  }

  static const Duration timeout = Duration(seconds: 10);

  static const int hourlyHours = 24;
  static const int dailyDays = 7;

  /// Du lieu "hien tai" cu hon nguong nay se hien badge "Dữ liệu cũ".
  static const Duration staleThreshold = Duration(hours: 3);

  static const String locationName = 'TP. Hồ Chí Minh';

  /// Dong phu cho UI: du lieu lay tai mot diem (10.79°N, 106.63°E), khong
  /// phai trung binh toan thanh pho.
  static const String locationDetail = 'Điểm dữ liệu gần Tân Sơn Nhất';

  /// Toa do diem du lieu (do, Bac / Dong) - dung tinh gio mat troi moc/lan.
  static const double latitude = 10.7909;
  static const double longitude = 106.6313;
}
