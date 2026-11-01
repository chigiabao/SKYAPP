import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cau hinh ket noi backend FastAPI - chi sua o mot noi nay.
///
/// Mac dinh: web -> cung origin voi trang web; Android -> 10.0.2.2
/// (emulator -> may host), iOS/desktop -> localhost.
/// Ghi de khi chay / build, vi du thiet bi that cung mang LAN:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
///
/// Nguoi dung co the ghi de luc chay (Cai dat > Nang cao > May chu du lieu):
/// [baseUrl] doc moi lan goi nen doi co hieu luc ngay, khong can build lai.
class ApiConfig {
  /// URL da build san (dart-define hoac mac dinh theo nen tang).
  static String get defaultBaseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb) return Uri.base.origin;
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8000'
        : 'http://localhost:8000';
  }

  /// Khoa shared_preferences cua URL ghi de.
  static const String baseUrlKey = 'api_base_url_override';
  static const String webOriginMigrationKey = 'api_same_origin_v1';

  static String? _override;

  static final ValueNotifier<int> serverChanges = ValueNotifier(0);

  static void _setOverride(String? value) {
    final before = baseUrl;
    _override = value;
    if (baseUrl != before) serverChanges.value++;
  }

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
        uri.userInfo.isNotEmpty ||
        RegExp(r'\s').hasMatch(t) ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    try {
      if (uri.port < 1 || uri.port > 65535) return null;
    } on FormatException {
      return null;
    }
    return uri
        .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
        .toString();
  }

  /// Doc URL ghi de da luu (goi truoc runApp). Gia tri hong -> bo qua.
  static Future<void> loadBaseUrl() async {
    try {
      final p = await SharedPreferences.getInstance();
      // Old preview URLs must not keep an upgraded web install on a dead port.
      if (kIsWeb && p.getBool(webOriginMigrationKey) != true) {
        final saved = p.getString(baseUrlKey);
        final normalized = saved == null ? null : normalizeBaseUrl(saved);
        final uri = normalized == null ? null : Uri.parse(normalized);
        if (uri != null &&
            const {'localhost', '127.0.0.1'}.contains(uri.host) &&
            const {8000, 8022, 8024, 8036}.contains(uri.port) &&
            (uri.path.isEmpty || uri.path == '/')) {
          await p.remove(baseUrlKey);
        }
        await p.setBool(webOriginMigrationKey, true);
      }
      final v = p.getString(baseUrlKey);
      _setOverride(v == null ? null : normalizeBaseUrl(v));
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
    _setOverride(next == defaultBaseUrl ? null : next);
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

  /// GET /weather/bundle: lan goi dau sau khi server khoi dong ~8 s (nap
  /// climatology + mo hinh AI).
  static const Duration bundleTimeout = Duration(seconds: 20);

  /// 48 gio: du thay gio di lam sang mai.
  static const int hourlyHours = 48;
  static const int dailyDays = 7;

  /// Du lieu "hien tai" cu hon nguong nay se hien badge "Dữ liệu cũ".
  static const Duration staleThreshold = Duration(hours: 3);

  /// Ten diem mac dinh ('tsn'), trung ten trong danh sach dia diem va dong
  /// phu [locationDetail] (ke ca khi ngoai tuyen chua tai duoc danh sach).
  static const String locationName = 'Tân Sơn Nhất';

  /// Dong phu cho UI: du lieu lay tai mot diem (10.79°N, 106.63°E), khong
  /// phai trung binh toan thanh pho.
  static const String locationDetail = 'Điểm dữ liệu gần Tân Sơn Nhất';

  /// Toa do diem du lieu (do, Bac / Dong) - dung tinh gio mat troi moc/lan.
  static const double latitude = 10.7909;
  static const double longitude = 106.6313;
}
