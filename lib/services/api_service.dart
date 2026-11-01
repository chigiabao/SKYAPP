import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/place.dart';
import '../models/weather.dart';
import 'weather_repository.dart';

export 'weather_repository.dart';

/// API Service ket noi backend FastAPI (xem lib/config/api_config.dart).
class ApiService implements WeatherRepository {
  /// v2: {"saved_at": ISO UTC, "payload": {current, hourly, daily, ai}}.
  /// Cache v1 (khong co saved_at) bi bo qua.
  static const String cacheKey = 'weather_cache_v2';

  final http.Client _client;
  final String? _baseUrl;

  /// Doc moi lan goi: ApiConfig.baseUrl co the doi luc chay.
  @override
  String get baseUrl => _baseUrl ?? ApiConfig.baseUrl;
  final Duration timeout;

  /// Rieng /weather/bundle: lan dau sau khi server khoi dong mat ~8 s.
  final Duration bundleTimeout;

  /// Tra ve thoi diem that hien tai (thay duoc khi test).
  final DateTime Function() clock;

  /// So cache dia diem toi da (ngoai diem mac dinh); cai luu cu nhat bi xoa
  /// khi luu them. Mac dinh chi gioi han tren web: SharedPreferences la
  /// localStorage (~5 MB) va moi lan tai truoc trang ke ben deu ghi cache.
  /// null = khong gioi han.
  final int? maxLocationCaches;

  static const int webMaxLocationCaches = 8;

  ApiService({
    http.Client? client,
    this._baseUrl,
    this.timeout = ApiConfig.timeout,
    this.bundleTimeout = ApiConfig.bundleTimeout,
    DateTime Function()? clock,
    this.maxLocationCaches = kIsWeb ? webMaxLocationCaches : null,
  }) : _client = client ?? http.Client(),
       clock = clock ?? DateTime.now;

  Future<dynamic> _getJson(
    String path, [
    Map<String, String>? query,
    Duration? timeoutOverride,
  ]) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeoutOverride ?? timeout);
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
            : code == 404 || code == 405
            ? ApiErrorKind.notFound
            : ApiErrorKind.server,
        statusCode: code,
        detail: _detailOf(response),
      );
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid JSON $uri: $e');
      throw ApiException(ApiErrorKind.invalidData);
    }
  }

  /// `detail` trong than loi JSON (FastAPI); null neu khong co.
  static String? _detailOf(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return body is Map ? body['detail']?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  /// Ep kieu JSON; sai kieu -> ApiException(invalidData).
  Future<T> _getTyped<T>(
    String path, [
    Map<String, String>? query,
    Duration? timeoutOverride,
  ]) async {
    final json = await _getJson(path, query, timeoutOverride);
    if (json is T) return json;
    debugPrint('ApiService: unexpected JSON for $path: ${json.runtimeType}');
    throw ApiException(ApiErrorKind.invalidData);
  }

  /// GET /health dang JSON tho (Cai dat > May chu: kiem tra truoc khi luu).
  Future<Map<String, dynamic>> fetchHealthJson() =>
      _getTyped<Map<String, dynamic>>('/health');

  /// Dong http.Client; chi goi khi ApiService tu tao client (khong truyen
  /// [client]) va khong dung nua.
  @override
  void close() => _client.close();

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

  @override
  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  }) => _getTyped<Map<String, dynamic>>(
    '/weather/current',
    _query(at, null, locationId),
  );

  @override
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

  /// GET /weather/ai-verify[?at=] cho diem mac dinh.
  Future<AIVerification> fetchAIVerification({DateTime? at}) =>
      fetchAIVerificationFor(Place.defaultId, at: at);

  /// GET /weather/ai-verify cho [locationId]. Nem ApiException (notFound neu
  /// backend chua co endpoint, invalidData neu sai dinh dang).
  @override
  Future<AIVerification> fetchAIVerificationFor(
    String locationId, {
    DateTime? at,
  }) async {
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

  /// GET /weather/ai-forecast tho; null neu endpoint chua san sang (404, loi
  /// mang, sai dinh dang) - KHONG bao gio tra so lieu gia.
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
      fetchWeatherDataFor(Place.defaultId, at: at);

  /// baseUrl da biet khong co /weather/bundle (backend cu) -> goi 4 API le.
  String? _noBundleFor;

  /// So lan [evictCache] theo id: request bat dau truoc khi dia diem bi xoa
  /// khong ghi lai cache (neu khong se de lai cache mo coi).
  final Map<String, int> _evictions = {};

  /// Nhu [fetchWeatherData] cho dia diem [locationId]; cache rieng moi diem.
  @override
  Future<WeatherData> fetchWeatherDataFor(
    String locationId, {
    DateTime? at,
  }) async {
    final server = baseUrl;
    final evictions = _evictions[locationId] ?? 0;
    final bundle =
        await _fetchCombined(locationId, at) ??
        await _fetchSeparate(locationId, at);
    final WeatherData data;
    try {
      data = WeatherData.fromJson(bundle);
    } on FormatException catch (e) {
      debugPrint('ApiService: invalid weather data: ${e.message}');
      throw ApiException(ApiErrorKind.invalidData);
    } on TypeError catch (e) {
      debugPrint('ApiService: weather data type error: $e');
      throw ApiException(ApiErrorKind.invalidData);
    }
    if (server != baseUrl) throw ApiException(ApiErrorKind.network);
    if (at == null && (_evictions[locationId] ?? 0) == evictions) {
      await _saveCache(bundle, locationId, server);
    }
    return data;
  }

  /// GET /weather/bundle: mot request cho ca current/hourly/daily/AI.
  /// null neu backend chua co endpoint (404/405) -> goi 4 API le.
  Future<Map<String, dynamic>?> _fetchCombined(
    String locationId,
    DateTime? at,
  ) async {
    final base = baseUrl;
    if (_noBundleFor == base) return null;
    final Map<String, dynamic> json;
    try {
      json = await _getTyped<Map<String, dynamic>>('/weather/bundle', {
        'location_id': locationId,
        ...?_query(at),
        'hours': '${ApiConfig.hourlyHours}',
        'days': '${ApiConfig.dailyDays}',
      }, bundleTimeout);
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.notFound) rethrow;
      _noBundleFor = base;
      return null;
    }
    final ai = json['ai_forecast'];
    return {
      'current': json['current'],
      'hourly': json['hourly'],
      'daily': json['daily'],
      'ai': ai is Map<String, dynamic> ? ai : null,
      'forecast_error': json['forecast_error'],
      'ai_error': json['ai_error'],
    };
  }

  /// Backend cu: 4 request song song.
  Future<Map<String, dynamic>> _fetchSeparate(
    String locationId,
    DateTime? at,
  ) async {
    final results = await Future.wait<dynamic>([
      fetchCurrentRaw(at: at, locationId: locationId),
      fetchHourlyRaw(at: at, locationId: locationId),
      fetchDailyRaw(at: at, locationId: locationId),
      _fetchAIRaw(at, locationId),
    ]);
    return {
      'current': results[0],
      'hourly': results[1],
      'daily': results[2],
      'ai': results[3],
    };
  }

  /// Khoa cache cua [locationId] (diem mac dinh giu khoa cu).
  static String cacheKeyFor(String locationId) =>
      locationId == Place.defaultId ? cacheKey : '${cacheKey}_$locationId';

  Future<void> _saveCache(
    Map<String, dynamic> bundle,
    String locationId,
    String server,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        cacheKeyFor(locationId),
        jsonEncode({
          'server_url': ApiConfig.normalizeBaseUrl(server),
          'saved_at': clock().toUtc().toIso8601String(),
          'payload': bundle,
        }),
      );
      await _pruneLocationCaches(prefs, locationId);
    } catch (e) {
      // Cache la tuy chon, bo qua loi
      debugPrint('ApiService: save cache failed: $e');
    }
  }

  /// Giu toi da [maxLocationCaches] cache dia diem, xoa cai luu cu nhat
  /// (khong xoa cache cua [keep] va cua diem mac dinh).
  Future<void> _pruneLocationCaches(
    SharedPreferences prefs,
    String keep,
  ) async {
    final max = maxLocationCaches;
    if (max == null) return;
    final keepKey = cacheKeyFor(keep);
    final others = [
      for (final k in prefs.getKeys())
        if (k.startsWith('${cacheKey}_') && k != keepKey) k,
    ];
    final excess = others.length + (keep == Place.defaultId ? 0 : 1) - max;
    if (excess <= 0) return;
    DateTime savedAt(String key) {
      try {
        final json = jsonDecode(prefs.getString(key) ?? '');
        final at = json is Map ? json['saved_at'] : null;
        return (at is String ? DateTime.tryParse(at) : null) ?? DateTime.utc(0);
      } catch (_) {
        return DateTime.utc(0);
      }
    }

    final at = {for (final k in others) k: savedAt(k)};
    others.sort((a, b) => at[a]!.compareTo(at[b]!));
    for (final k in others.take(excess)) {
      await prefs.remove(k);
    }
  }

  @override
  Future<void> evictCache(String locationId) async {
    if (locationId == Place.defaultId) return;
    _evictions[locationId] = (_evictions[locationId] ?? 0) + 1;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(cacheKeyFor(locationId));
    } catch (e) {
      debugPrint('ApiService: evict cache failed: $e');
    }
  }

  /// Doc cache v2; gio/ngay da qua bi loai bo. null neu khong co hoac hong.
  Future<WeatherResult?> loadCachedResult() =>
      loadCachedResultFor(Place.defaultId);

  /// Cache cua [locationId] (nhu [loadCachedResult]).
  @override
  Future<WeatherResult?> loadCachedResultFor(String locationId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKeyFor(locationId));
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['server_url'] != ApiConfig.normalizeBaseUrl(baseUrl)) {
        return null;
      }
      final savedAt = HcmTime.tryParse(json['saved_at'] as String?);
      final payload = json['payload'];
      if (savedAt == null || payload is! Map<String, dynamic>) return null;
      final data = WeatherData.fromJson(payload)
          .withoutPastItems(HcmTime.now(clock));
      return WeatherResult(data, fromCache: true, savedAt: savedAt);
    } catch (e) {
      debugPrint('ApiService: load cache failed: $e');
      return null;
    }
  }

  // --- Dia diem / ban do ---------------------------------------------------

  /// GET /locations. Nem ApiException (notFound neu backend chua ho tro).
  @override
  Future<List<Place>> fetchLocations() async =>
      Place.listFromJson(await _getTyped<List<dynamic>>('/locations'));

  /// GET /locations/search?q= (ket qua tot nhat truoc).
  @override
  Future<List<Place>> searchLocations(String q) async => Place.listFromJson(
    await _getTyped<List<dynamic>>('/locations/search', {'q': q}),
  );

  /// GET /locations/nearest. Nem [OutsideAreaException] khi may chu bao
  /// diem nam ngoai TP.HCM (404 co `detail` khac "Not Found"); ApiException
  /// voi loi khac (notFound = backend chua co endpoint).
  @override
  Future<Place> nearestLocation(double lat, double lon) async {
    final Map<String, dynamic> json;
    try {
      json = await _getTyped<Map<String, dynamic>>('/locations/nearest', {
        'lat': lat.toStringAsFixed(5),
        'lon': lon.toStringAsFixed(5),
      });
    } on ApiException catch (e) {
      final detail = e.detail;
      if (e.statusCode == 404 && detail != null && detail != 'Not Found') {
        throw OutsideAreaException(detail);
      }
      rethrow;
    }
    try {
      return Place.fromJson(json);
    } on FormatException {
      throw ApiException(ApiErrorKind.invalidData);
    }
  }

  /// GET /weather/map[?offset_hours=][&at=]: moi o luoi mot muc.
  /// [offsetHours] 0..72 (0 thi khong gui, giu tuong thich backend cu).
  @override
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
  @override
  Future<CityBoundary> fetchBoundary() async =>
      CityBoundary.fromGeoJson(await _getJson('/locations/boundary'));
}
