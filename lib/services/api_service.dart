import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  ApiException(this.kind) : message = messageFor(kind);

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

/// API Service ket noi backend FastAPI (xem lib/config/api_config.dart).
class ApiService {
  /// v2: {"saved_at": ISO UTC, "payload": {current, hourly, daily, ai}}.
  /// Cache v1 (khong co saved_at) bi bo qua.
  static const String cacheKey = 'weather_cache_v2';

  final http.Client _client;
  final String? _baseUrl;

  /// Doc moi lan goi: ApiConfig.baseUrl co the doi luc chay.
  String get baseUrl => _baseUrl ?? ApiConfig.baseUrl;
  final Duration timeout;

  /// Tra ve thoi diem that hien tai (thay duoc khi test).
  final DateTime Function() clock;

  ApiService({
    http.Client? client,
    this._baseUrl,
    this.timeout = ApiConfig.timeout,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       clock = clock ?? DateTime.now;

  Future<dynamic> _getJson(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      debugPrint('ApiService: timeout $uri');
      throw ApiException(ApiErrorKind.timeout);
    } catch (e) {
      debugPrint('ApiService: network error $uri: $e');
      throw ApiException(ApiErrorKind.network);
    }
    if (response.statusCode != 200) {
      debugPrint('ApiService: HTTP ${response.statusCode} $uri');
      final code = response.statusCode;
      throw ApiException(
        code == 400 || code == 422
            ? ApiErrorKind.badRequest
            : code == 404
            ? ApiErrorKind.notFound
            : ApiErrorKind.server,
      );
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid JSON $uri: $e');
      throw ApiException(ApiErrorKind.invalidData);
    }
  }

  /// Ep kieu JSON; sai kieu -> ApiException(invalidData).
  Future<T> _getTyped<T>(String path, [Map<String, String>? query]) async {
    final json = await _getJson(path, query);
    if (json is T) return json;
    debugPrint('ApiService: unexpected JSON for $path: ${json.runtimeType}');
    throw ApiException(ApiErrorKind.invalidData);
  }

  /// GET /health (co the co latest_timestamp, data_age_hours).
  Future<BackendHealth> fetchHealth() async =>
      BackendHealth.fromJson(await _getTyped<Map<String, dynamic>>('/health'));

  /// Tham so query; [at] (gio TP.HCM) -> `at=...+07:00` (che do xem lai).
  /// [location] -> `location_id` (bo qua voi diem mac dinh "tsn" de giu
  /// tuong thich backend cu).
  static Map<String, String>? _query(
    DateTime? at, [
    Map<String, String>? q,
    String? location,
  ]) {
    final result = <String, String>{...?q};
    if (at != null) result['at'] = HcmTime.toIso(at);
    if (location != null && location != Place.defaultId) {
      result['location_id'] = location;
    }
    return result.isEmpty ? null : result;
  }

  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  }) => _getTyped<Map<String, dynamic>>(
    '/weather/current',
    _query(at, null, locationId),
  );

  Future<List<dynamic>> fetchHourlyRaw({
    int hours = ApiConfig.hourlyHours,
    DateTime? at,
    String? locationId,
  }) => _getTyped<List<dynamic>>(
    '/weather/hourly',
    _query(at, {'hours': '$hours'}, locationId),
  );

  Future<List<dynamic>> fetchDailyRaw({
    int days = ApiConfig.dailyDays,
    DateTime? at,
    String? locationId,
  }) => _getTyped<List<dynamic>>(
    '/weather/daily',
    _query(at, {'days': '$days'}, locationId),
  );

  /// GET /weather/ai-verify cho [locationId]. Diem mac dinh di qua
  /// [fetchAIVerification] (lop gia trong test ghi de ham do).
  Future<AIVerification> fetchAIVerificationFor(
    String locationId, {
    DateTime? at,
  }) => locationId == Place.defaultId
      ? fetchAIVerification(at: at)
      : _fetchAIVerification(at, locationId);

  /// GET /weather/ai-verify[?at=]. Nem ApiException (notFound neu backend
  /// chua co endpoint, invalidData neu sai dinh dang).
  Future<AIVerification> fetchAIVerification({DateTime? at}) =>
      _fetchAIVerification(at, null);

  Future<AIVerification> _fetchAIVerification(
    DateTime? at,
    String? locationId,
  ) async {
    final json = await _getTyped<Map<String, dynamic>>(
      '/weather/ai-verify',
      _query(at, null, locationId),
    );
    try {
      return AIVerification.fromJson(json);
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid AI verification: $e');
      throw ApiException(ApiErrorKind.invalidData);
    } on TypeError catch (e) {
      debugPrint('ApiService: AI verification type error: $e');
      throw ApiException(ApiErrorKind.invalidData);
    }
  }

  /// GET /weather/ai-forecast. Tra ve null neu endpoint chua san sang
  /// (404, loi mang, sai dinh dang) - KHONG bao gio tra so lieu gia.
  Future<AIForecast?> fetchAIForecast({DateTime? at}) async {
    final raw = await _fetchAIRaw(at);
    if (raw == null) return null;
    try {
      return AIForecast.fromJson(raw);
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid AI forecast: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchAIRaw([
    DateTime? at,
    String? locationId,
  ]) async {
    try {
      final json = await _getJson(
        '/weather/ai-forecast',
        _query(at, null, locationId),
      );
      return json is Map<String, dynamic> ? json : null;
    } on ApiException {
      return null;
    }
  }

  /// Tai toan bo du lieu tu backend; thanh cong thi luu cache.
  /// [at] (gio TP.HCM): che do xem lai - moi request gui `at`, KHONG ghi cache
  /// (cache chi chua du lieu truc tiep).
  /// Nem ApiException neu current/hourly/daily loi.
  Future<WeatherData> fetchWeatherData({DateTime? at}) =>
      _fetchBundle(Place.defaultId, at);

  /// Nhu [fetchWeatherData] cho dia diem [locationId]; cache rieng moi diem.
  /// Diem mac dinh di qua [fetchWeatherData] (lop gia trong test ghi de ham
  /// do).
  Future<WeatherData> fetchWeatherDataFor(String locationId, {DateTime? at}) =>
      locationId == Place.defaultId
      ? fetchWeatherData(at: at)
      : _fetchBundle(locationId, at);

  Future<WeatherData> _fetchBundle(String locationId, DateTime? at) async {
    final results = await Future.wait<dynamic>([
      fetchCurrentRaw(at: at, locationId: locationId),
      fetchHourlyRaw(at: at, locationId: locationId),
      fetchDailyRaw(at: at, locationId: locationId),
      _fetchAIRaw(at, locationId),
    ]);
    final bundle = <String, dynamic>{
      'current': results[0],
      'hourly': results[1],
      'daily': results[2],
      'ai': results[3],
    };
    final WeatherData data;
    try {
      data = WeatherData.fromJson(bundle, locationName: ApiConfig.locationName);
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid weather data: ${e.message}');
      throw ApiException(ApiErrorKind.invalidData);
    } on TypeError catch (e) {
      debugPrint('ApiService: weather data type error: $e');
      throw ApiException(ApiErrorKind.invalidData);
    }
    if (at == null) await _saveCache(bundle, locationId);
    return data;
  }

  /// Uu tien mang; neu loi thi dung cache (fromCache = true).
  /// Nem lai loi goc neu khong co cache.
  Future<WeatherResult> fetchWithCacheFallback() async {
    try {
      return WeatherResult(await fetchWeatherData(), fromCache: false);
    } on ApiException {
      final cached = await loadCachedResult();
      if (cached != null) return cached;
      rethrow;
    }
  }

  /// Khoa cache cua [locationId] (diem mac dinh giu khoa cu).
  static String cacheKeyFor(String locationId) =>
      locationId == Place.defaultId ? cacheKey : '${cacheKey}_$locationId';

  Future<void> _saveCache(
    Map<String, dynamic> bundle,
    String locationId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        cacheKeyFor(locationId),
        jsonEncode({
          'saved_at': clock().toUtc().toIso8601String(),
          'payload': bundle,
        }),
      );
    } catch (e) {
      // Cache la tuy chon, bo qua loi
      debugPrint('ApiService: save cache failed: $e');
    }
  }

  /// Doc cache v2; gio/ngay da qua bi loai bo. null neu khong co hoac hong.
  Future<WeatherResult?> loadCachedResult() => _loadCached(Place.defaultId);

  /// Cache cua [locationId]; diem mac dinh di qua [loadCachedResult].
  Future<WeatherResult?> loadCachedResultFor(String locationId) =>
      locationId == Place.defaultId
      ? loadCachedResult()
      : _loadCached(locationId);

  Future<WeatherResult?> _loadCached(String locationId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKeyFor(locationId));
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = HcmTime.tryParse(json['saved_at'] as String?);
      final payload = json['payload'];
      if (savedAt == null || payload is! Map<String, dynamic>) return null;
      final data = WeatherData.fromJson(
        payload,
        locationName: ApiConfig.locationName,
      ).withoutPastItems(HcmTime.now(clock));
      return WeatherResult(data, fromCache: true, savedAt: savedAt);
    } catch (e) {
      debugPrint('ApiService: load cache failed: $e');
      return null;
    }
  }

  Future<WeatherData?> loadCache() async => (await loadCachedResult())?.data;

  // --- Dia diem / ban do ---------------------------------------------------

  /// GET /locations. Nem ApiException (notFound neu backend chua ho tro).
  Future<List<Place>> fetchLocations() async =>
      Place.listFromJson(await _getTyped<List<dynamic>>('/locations'));

  /// GET /locations/search?q= (ket qua tot nhat truoc).
  Future<List<Place>> searchLocations(String q) async => Place.listFromJson(
    await _getTyped<List<dynamic>>('/locations/search', {'q': q}),
  );

  /// GET /locations/nearest. Nem [OutsideAreaException] khi may chu bao
  /// diem nam ngoai TP.HCM (404 co `detail` khac "Not Found"); ApiException
  /// voi loi khac (notFound = backend chua co endpoint).
  Future<Place> nearestLocation(double lat, double lon) async {
    final uri = Uri.parse('$baseUrl/locations/nearest').replace(
      queryParameters: {
        'lat': lat.toStringAsFixed(5),
        'lon': lon.toStringAsFixed(5),
      },
    );
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout);
    } catch (e) {
      debugPrint('ApiService: network error /locations/nearest: $e');
      throw ApiException(ApiErrorKind.network);
    }
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (response.statusCode == 404) {
      final detail = body is Map ? body['detail']?.toString() : null;
      if (detail != null && detail != 'Not Found') {
        throw OutsideAreaException(detail);
      }
      throw ApiException(ApiErrorKind.notFound);
    }
    if (response.statusCode != 200) {
      final code = response.statusCode;
      throw ApiException(
        code == 400 || code == 422
            ? ApiErrorKind.badRequest
            : ApiErrorKind.server,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw ApiException(ApiErrorKind.invalidData);
    }
    try {
      return Place.fromJson(body);
    } on FormatException {
      throw ApiException(ApiErrorKind.invalidData);
    }
  }

  /// GET /weather/map[?offset_hours=][&at=]: moi o luoi mot muc.
  /// [offsetHours] 0..72 (0 thi khong gui, giu tuong thich backend cu).
  Future<List<MapCell>> fetchMapCells({
    DateTime? at,
    int offsetHours = 0,
  }) async => MapCell.listFromJson(
    await _getTyped<List<dynamic>>(
      '/weather/map',
      _query(at, {if (offsetHours > 0) 'offset_hours': '$offsetHours'}),
    ),
  );

  /// GET /locations/boundary (GeoJSON).
  Future<CityBoundary> fetchBoundary() async =>
      CityBoundary.fromGeoJson(await _getJson('/locations/boundary'));
}
