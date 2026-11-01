import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/trip_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/services/trip_location.dart';
import 'package:sky_weather_app/services/trip_notifier.dart';

final _now = DateTime.utc(2026, 10, 21, 6);

class _Location implements TripLocationSource {
  final controller = StreamController<LatLng>.broadcast();

  @override
  Future<GpsStatus> ensurePermission() async => GpsStatus.ok;

  @override
  Stream<LatLng> watch({required bool background}) => controller.stream;
}

class _Api extends ApiService {
  _Api(this.empty);
  final bool empty;

  @override
  Future<Place> nearestLocation(double lat, double lon) async => Place(
    id: 'test',
    name: 'Test',
    kind: PlaceKind.phuong,
    lat: lat,
    lon: lon,
  );

  @override
  Future<List<dynamic>> fetchHourlyRaw({
    int hours = 24,
    DateTime? at,
    String? locationId,
  }) async => [
    if (!empty)
      {
        'timestamp': HcmTime.toIso(_now.subtract(const Duration(days: 2))),
        'temperature': 27,
        'weather_code': 3,
        'rain_probability': 0,
      },
  ];

  @override
  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  }) async => {
    'timestamp': HcmTime.toIso(_now),
    'temperature': 27,
    'weather_code': 3,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final empty in [true, false]) {
    test(
      'free trip does not reassure with ${empty ? 'empty' : 'expired'} hourly data',
      () async {
        final location = _Location();
        final trip = TripProvider(
          api: _Api(empty),
          location: location,
          notifier: const NoopTripNotifier(),
          clock: () => HcmTime.toInstant(_now),
          tickEvery: null,
        );
        addTearDown(trip.dispose);
        addTearDown(location.controller.close);
        await trip.start();
        location.controller.add(const LatLng(10.7, 106.7));
        await pumpEventQueue();
        await trip.tick();
        expect(
          trip.status,
          contains('Chưa có dữ liệu theo giờ để kiểm tra cảnh báo'),
        );
        expect(trip.status, isNot(contains('Không có cảnh báo')));
        expect(trip.status, isNot(contains('Chưa phát hiện cảnh báo')));
        expect(trip.alerts, isEmpty);
        await trip.end();
      },
    );
  }
}
