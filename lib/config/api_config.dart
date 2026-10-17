import 'package:flutter/foundation.dart';

/// Cau hinh ket noi backend FastAPI - chi sua o mot noi nay.
///
/// Mac dinh: web -> http://localhost:8000 (trinh duyet tren chinh may chay
/// backend); con lai -> 10.0.2.2 (Android emulator -> may host).
/// Ghi de khi chay / build, vi du thiet bi that cung mang LAN:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: kIsWeb ? 'http://localhost:8000' : 'http://10.0.2.2:8000',
  );

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
