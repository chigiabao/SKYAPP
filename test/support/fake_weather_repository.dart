// Lop gia dung chung cho test: thay ApiService (khong mang, khong cache that).
import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/services/weather_repository.dart';

/// Mot lan goi [FakeWeatherRepository.fetchWeatherDataFor].
typedef FakeFetch = ({String id, DateTime? at});

/// [WeatherRepository] trong bo nho cho test.
///
/// - [onFetch] tra du lieu (hoac nem loi) cho moi lan tai; null -> nem
///   `ApiException(network)`. Moi lan goi duoc ghi vao [fetches].
/// - [cached]: ket qua cua [loadCachedResultFor] theo id.
/// - Cac endpoint dia diem / ban do / AI mac dinh nem `notFound` (nhu
///   backend chua ho tro), tru khi gan [places] hoac [onNearest].
class FakeWeatherRepository implements WeatherRepository {
  FakeWeatherRepository({
    this.onFetch,
    Map<String, WeatherResult>? cached,
    this.places,
    this.onNearest,
    this._baseUrl,
  }) : cached = cached ?? {};

  /// Du lieu co dinh, khong phu thuoc dia diem; [build] nhan `at` (xem lai).
  FakeWeatherRepository.fixed(WeatherData Function(DateTime? at) build)
    : this(onFetch: (_, at) async => build(at));

  Future<WeatherData> Function(String id, DateTime? at)? onFetch;
  final Map<String, WeatherResult> cached;
  List<Place>? places;
  Future<Place> Function(double lat, double lon)? onNearest;

  /// Nhu ApiService: null -> doc [ApiConfig.baseUrl] moi lan (doi may chu).
  final String? _baseUrl;

  @override
  String get baseUrl => _baseUrl ?? ApiConfig.baseUrl;

  final List<FakeFetch> fetches = [];
  final List<String> evicted = [];
  bool closed = false;

  @override
  Future<WeatherData> fetchWeatherDataFor(String locationId, {DateTime? at}) {
    fetches.add((id: locationId, at: at));
    final fetch = onFetch;
    if (fetch == null) {
      return Future.error(ApiException(ApiErrorKind.network));
    }
    return fetch(locationId, at);
  }

  @override
  Future<WeatherResult?> loadCachedResultFor(String locationId) async =>
      cached[locationId];

  @override
  Future<void> evictCache(String locationId) async {
    evicted.add(locationId);
    cached.remove(locationId);
  }

  @override
  Future<AIVerification> fetchAIVerificationFor(
    String locationId, {
    DateTime? at,
  }) => _unsupported();

  @override
  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  }) => _unsupported();

  @override
  Future<List<dynamic>> fetchHourlyRaw({
    int hours = ApiConfig.hourlyHours,
    DateTime? at,
    String? locationId,
  }) => _unsupported();

  @override
  Future<List<Place>> fetchLocations() async =>
      places ?? await _unsupported<List<Place>>();

  @override
  Future<List<Place>> searchLocations(String q) async {
    final all = places;
    if (all == null) return _unsupported();
    final needle = q.toLowerCase();
    return [
      for (final p in all)
        if (p.name.toLowerCase().contains(needle)) p,
    ];
  }

  @override
  Future<Place> nearestLocation(double lat, double lon) =>
      onNearest?.call(lat, lon) ?? _unsupported();

  @override
  Future<List<MapCell>> fetchMapCells({DateTime? at, int offsetHours = 0}) =>
      _unsupported();

  @override
  Future<CityBoundary> fetchBoundary() => _unsupported();

  @override
  void close() => closed = true;

  static Future<T> _unsupported<T>() =>
      Future.error(ApiException(ApiErrorKind.notFound));
}
