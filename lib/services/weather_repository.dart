import '../config/api_config.dart';
import '../models/place.dart';
import '../models/weather.dart';

/// Loai loi khi goi backend.
enum ApiErrorKind {
  network,
  timeout,
  server,
  invalidData,
  badRequest,
  notFound,
}

/// Loi khi goi backend. [message] la cau tieng Viet than thien de hien thi;
/// chi tiet ky thuat chi ghi qua debugPrint.
class ApiException implements Exception {
  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  /// Truong `detail` cua phan hoi loi (FastAPI); khong hien thi truc tiep.
  final String? detail;

  ApiException(this.kind, {this.statusCode, this.detail})
    : message = messageFor(kind);

  bool get isTransient => switch (kind) {
    ApiErrorKind.network || ApiErrorKind.timeout => true,
    ApiErrorKind.server =>
      statusCode == null ||
          statusCode! >= 500 ||
          const {408, 425, 429}.contains(statusCode),
    _ => false,
  };

  static String messageFor(ApiErrorKind kind) {
    switch (kind) {
      case ApiErrorKind.network:
        return 'Không có kết nối mạng hoặc không tới được máy chủ.';
      case ApiErrorKind.timeout:
        return 'Máy chủ không phản hồi.';
      case ApiErrorKind.server:
        return 'Máy chủ đang gặp lỗi.';
      case ApiErrorKind.invalidData:
        return 'Dữ liệu từ máy chủ không hợp lệ.';
      case ApiErrorKind.badRequest:
        return 'Máy chủ không chấp nhận yêu cầu (thời điểm xem lại không hợp '
            'lệ hoặc chưa được hỗ trợ).';
      case ApiErrorKind.notFound:
        return 'Máy chủ chưa hỗ trợ chức năng này.';
    }
  }

  @override
  String toString() => 'ApiException(${kind.name}): $message';
}

/// GET /locations/nearest: diem nam ngoai TP.HCM (404 co `detail`).
class OutsideAreaException implements Exception {
  const OutsideAreaException([this.message = defaultMessage]);

  static const String defaultMessage = 'Ngoài vùng hỗ trợ (TP.HCM)';
  final String message;

  @override
  String toString() => 'OutsideAreaException: $message';
}

/// Ket qua tai du lieu: tu mang hay tu cache.
class WeatherResult {
  final WeatherData data;
  final bool fromCache;

  /// Thoi diem luu cache (gio TP.HCM); null neu du lieu tu mang.
  final DateTime? savedAt;

  const WeatherResult(this.data, {required this.fromCache, this.savedAt});
}

/// Nguon du lieu thoi tiet / dia diem ma cac provider phu thuoc vao.
/// Ban that: [ApiService] (backend FastAPI + cache SharedPreferences); test
/// dung lop gia (test/support/fake_weather_repository.dart).
///
/// Loi mang/may chu nem [ApiException]; [nearestLocation] co the nem them
/// [OutsideAreaException].
abstract interface class WeatherRepository {
  /// Dia chi backend dang dung (doi duoc luc chay).
  String get baseUrl;

  /// Du lieu current/hourly/daily/AI cua [locationId]. [at] (gio TP.HCM):
  /// che do xem lai, khong ghi cache. Thanh cong (truc tiep) thi luu cache.
  Future<WeatherData> fetchWeatherDataFor(String locationId, {DateTime? at});

  /// Cache cua [locationId]; null neu khong co, hong hoac cua may chu khac.
  Future<WeatherResult?> loadCachedResultFor(String locationId);

  /// Xoa cache cua [locationId] (dia diem da bo khoi danh sach). Diem mac
  /// dinh khong bi xoa.
  Future<void> evictCache(String locationId);

  /// GET /weather/ai-verify cho [locationId].
  Future<AIVerification> fetchAIVerificationFor(
    String locationId, {
    DateTime? at,
  });

  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  });

  Future<List<dynamic>> fetchHourlyRaw({
    int hours = ApiConfig.hourlyHours,
    DateTime? at,
    String? locationId,
  });

  Future<List<Place>> fetchLocations();

  Future<List<Place>> searchLocations(String q);

  Future<Place> nearestLocation(double lat, double lon);

  Future<List<MapCell>> fetchMapCells({DateTime? at, int offsetHours = 0});

  Future<CityBoundary> fetchBoundary();

  /// Giai phong ket noi; chi chu so huu goi (vd. main.dart khi app dong).
  void close();
}
