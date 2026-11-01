// TripSetupController: luong GPS / lap tuyen / bat dau cua man "Chuyến đi"
// tach khoi widget. Du lieu gia CHI dung trong test, khong goi mang.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/trip_provider.dart';
import 'package:sky_weather_app/screens/trip/trip_setup_controller.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/services/route_service.dart';
import 'package:sky_weather_app/services/trip_location.dart';
import 'package:sky_weather_app/services/trip_notifier.dart';

import 'support/fake_weather_repository.dart';

class _Gps implements GpsService {
  _Gps(this.fix);
  GpsFix fix;
  int calls = 0;

  @override
  Future<GpsFix> locate() async {
    calls++;
    return fix;
  }

  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<bool> openLocationSettings() async => false;
}

class _Location implements TripLocationSource {
  GpsStatus status = GpsStatus.ok;

  @override
  Future<GpsStatus> ensurePermission() async => status;

  @override
  Stream<LatLng> watch({required bool background}) =>
      const Stream<LatLng>.empty();
}

const _dest = Place(
  id: 'q1',
  name: 'Bến Thành',
  kind: PlaceKind.phuong,
  lat: 10.77,
  lon: 106.70,
);

class _Routes extends RouteService {
  Completer<TripRoute>? pending;
  int calls = 0;
  final result = TripRoute(
    profile: TripProfile.driving,
    departAt: DateTime(2026, 10, 17, 14),
    arriveAt: DateTime(2026, 10, 17, 14, 20),
    distanceKm: 8,
    durationMin: 20,
    geometry: const [LatLng(10.77, 106.69), LatLng(10.81, 106.71)],
    samples: const [],
  );

  @override
  Future<TripRoute> fetchRoute({
    required LatLng from,
    required LatLng to,
    required DateTime departAt,
    TripProfile profile = TripProfile.driving,
  }) async {
    calls++;
    return pending == null ? result : pending!.future;
  }

  @override
  Future<TripRoute> alongWeather({
    required List<LatLng> geometry,
    required DateTime departAt,
    double? durationMin,
    TripProfile profile = TripProfile.driving,
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late _Location location;
  late TripProvider trip;
  late _Routes routes;

  setUp(() {
    location = _Location();
    routes = _Routes();
    trip = TripProvider(
      routes: routes,
      api: FakeWeatherRepository(),
      location: location,
      notifier: const NoopTripNotifier(),
      clock: () => DateTime.utc(2026, 10, 17, 7),
      tickEvery: null,
    );
  });

  tearDown(() {
    trip.dispose();
    routes.close();
  });

  for (final input in ['from', 'to', 'profile', 'time']) {
    test('changing $input clears the old route and disables start', () async {
      final c = TripSetupController(
        gps: _Gps(const GpsFix(GpsStatus.ok, lat: 10.77, lon: 106.69)),
      )..pickDestination(_dest, trip);
      addTearDown(c.dispose);
      await c.plan(trip);
      expect(c.canStart(trip), isTrue);
      expect(trip.planFromLabel, 'Vị trí hiện tại (GPS)');
      expect(trip.planToLabel, _dest.name);
      switch (input) {
        case 'from':
          c.setFrom(_dest, trip);
        case 'to':
          c.pickDestination(_dest, trip);
        case 'profile':
          c.setProfile(TripProfile.foot, trip);
        case 'time':
          c.setDepartAt(DateTime(2026, 10, 17, 15), trip);
      }
      expect(trip.plan, isNull);
      expect(c.canStart(trip), isFalse);
      expect(trip.departOptions, isEmpty);
    });
  }

  test(
    'late route cannot restore a plan invalidated by new endpoints',
    () async {
      routes.pending = Completer<TripRoute>();
      final c = TripSetupController(
        gps: _Gps(const GpsFix(GpsStatus.ok, lat: 10.77, lon: 106.69)),
      )..pickDestination(_dest, trip);
      addTearDown(c.dispose);
      final request = c.plan(trip);
      await Future<void>.delayed(Duration.zero);
      expect(trip.planning, isTrue);
      c.setFrom(_dest, trip);
      routes.pending!.complete(routes.result);
      await request;
      expect(trip.plan, isNull);
      expect(trip.planning, isFalse);
      expect(c.canStart(trip), isFalse);
    },
  );

  test('late GPS cannot route the previous endpoint selection', () async {
    final done = Completer<GpsFix>();
    final gps = _Gps(const GpsFix(GpsStatus.ok));
    final c = TripSetupController(gps: _DelayedGps(gps, done.future))
      ..pickDestination(_dest, trip);
    addTearDown(c.dispose);
    final request = c.plan(trip);
    c.setFrom(_dest, trip);
    done.complete(const GpsFix(GpsStatus.ok, lat: 10.77, lon: 106.69));
    await request;
    expect(routes.calls, 0);
    expect(trip.plan, isNull);
  });

  test('nextDeparture rolls a past time to tomorrow', () {
    final now = DateTime.utc(2026, 10, 17, 14, 20);
    expect(
      TripSetupController.nextDeparture(now, 15, 0),
      DateTime.utc(2026, 10, 17, 15),
    );
    expect(
      TripSetupController.nextDeparture(now, 9, 30),
      DateTime.utc(2026, 10, 18, 9, 30),
    );
  });

  test('picking a destination clears results and notifies', () {
    final c = TripSetupController(gps: _Gps(const GpsFix(GpsStatus.ok)));
    addTearDown(c.dispose);
    var notified = 0;
    c.addListener(() => notified++);
    c.pickDestination(_dest, trip);
    expect(c.to, _dest);
    expect(c.results, isEmpty);
    expect(c.canStart(trip), isFalse, reason: 'with route, no plan yet');
    c.clearDestination(trip);
    expect(c.to, isNull);
    expect(notified, 2);
  });

  test('plan from GPS reports a denied fix without routing', () async {
    final gps = _Gps(const GpsFix(GpsStatus.denied));
    final c = TripSetupController(gps: gps)..pickDestination(_dest, trip);
    addTearDown(c.dispose);
    await c.plan(trip);
    expect(gps.calls, 1);
    expect(c.gpsIssue, GpsStatus.denied);
    expect(c.message, contains('Không lấy được vị trí hiện tại'));
    expect(trip.plan, isNull);
    expect(trip.planning, isFalse);
  });

  test('start without permission surfaces the provider error', () async {
    location.status = GpsStatus.serviceDisabled;
    final c = TripSetupController(
      gps: _Gps(const GpsFix(GpsStatus.ok)),
      withRoute: false,
    );
    addTearDown(c.dispose);
    expect(c.canStart(trip), isTrue);
    await c.start(
      trip,
      backgroundSupported: false,
      confirmBackground: () async => true,
    );
    expect(c.gpsIssue, GpsStatus.serviceDisabled);
    expect(c.message, trip.error);
    expect(trip.isRunning, isFalse);
  });

  test('declining the background explanation does not start', () async {
    final c = TripSetupController(
      gps: _Gps(const GpsFix(GpsStatus.ok)),
      withRoute: false,
    )..setBackground(true);
    addTearDown(c.dispose);
    var asked = 0;
    await c.start(
      trip,
      backgroundSupported: true,
      confirmBackground: () async {
        asked++;
        return false;
      },
    );
    expect(asked, 1);
    expect(trip.isRunning, isFalse);
  });

  test('a fix arriving after dispose does not notify', () async {
    final done = Completer<GpsFix>();
    final gps = _Gps(const GpsFix(GpsStatus.ok));
    final c = TripSetupController(gps: _DelayedGps(gps, done.future));
    c.pickDestination(_dest, trip);
    final f = c.plan(trip);
    c.dispose();
    done.complete(const GpsFix(GpsStatus.denied));
    await f;
    expect(c.message, isNull);
  });
}

class _DelayedGps implements GpsService {
  _DelayedGps(this.inner, this.fix);
  final GpsService inner;
  final Future<GpsFix> fix;

  @override
  Future<GpsFix> locate() => fix;

  @override
  Future<bool> openAppSettings() => inner.openAppSettings();

  @override
  Future<bool> openLocationSettings() => inner.openLocationSettings();
}
