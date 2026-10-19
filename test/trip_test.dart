import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/hcm_time.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/trip_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/trip_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/services/route_service.dart';
import 'package:sky_weather_app/services/trip_location.dart';
import 'package:sky_weather_app/services/trip_notifier.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

// Du lieu gia CHI dung trong test.

/// Gio that (UTC) = 07:20 -> 14:20 gio TP.HCM.
DateTime _real = DateTime.utc(2026, 10, 17, 7, 20);
DateTime _clock() => _real;

String _iso(DateTime hcm) => '${hcm.toIso8601String().substring(0, 19)}+07:00';

Map<String, dynamic> _sample(
  double lat,
  double lon,
  DateTime eta, {
  int code = 3,
  double rain = 0,
}) => {
  'lat': lat,
  'lon': lon,
  'eta': _iso(eta),
  'cell_id': 'c1',
  'temperature': 30.0,
  'precipitation': rain,
  'rain_probability': rain > 0 ? 0.9 : 0.1,
  'weather_code': code,
  'wind_gusts': 20.0,
  'source': 'forecast',
  'alert': code >= 95 || rain >= 5,
  'alert_reason': code >= 95 ? 'Dông' : (rain >= 5 ? 'Mưa to' : null),
};

/// Tuyen thang theo vi do 10.70 -> 10.80 (moi dinh ~1,1 km), dong tai 10.74.
Map<String, dynamic> _routeJson(
  List<List<double>> geo,
  DateTime depart, {
  double stormLat = 10.74,
}) {
  final samples = <Map<String, dynamic>>[];
  for (var i = 0; i < geo.length; i += 2) {
    final p = geo[i];
    final storm = (p[0] - stormLat).abs() < 1e-6;
    samples.add(
      _sample(
        p[0],
        p[1],
        depart.add(Duration(minutes: 2 * i)),
        code: storm ? 95 : 3,
      ),
    );
  }
  final worst = samples.firstWhere(
    (s) => s['alert'] == true,
    orElse: () => samples.first,
  );
  return {
    'profile': 'driving',
    'depart_at': _iso(depart),
    'arrive_at': _iso(depart.add(Duration(minutes: 2 * geo.length))),
    'distance_km': 11.1,
    'duration_min': 22.0,
    'geometry': geo,
    'samples': samples,
    'worst': worst,
    'alert': samples.any((s) => s['alert'] == true),
    'attribution': '© OpenStreetMap contributors, OSRM',
  };
}

final List<List<double>> _line = [
  for (var i = 0; i <= 10; i++) [10.70 + i * 0.01, 106.7],
];

Map<String, dynamic> _limitedRouteJson(
  List<List<double>> geo,
  DateTime depart, {
  bool ownAi = false,
}) {
  final body = _routeJson(geo, depart, stormLat: -1);
  for (final s in body['samples'] as List<Map<String, dynamic>>) {
    s.addAll({
      'temperature': ownAi ? 30.0 : null,
      'precipitation': ownAi ? 0.0 : null,
      'rain_probability': ownAi ? 0.1 : null,
      'weather_code': null,
      'wind_gusts': null,
      'source': ownAi ? 'ai' : null,
      'forecast_available': ownAi,
      'hazard_assessment_complete': false,
    });
  }
  return body;
}

class _FakeLocation implements TripLocationSource {
  final controller = StreamController<LatLng>.broadcast();
  int watchCalls = 0;
  bool? lastBackground;
  GpsStatus status = GpsStatus.ok;

  @override
  Future<GpsStatus> ensurePermission() async => status;

  @override
  Stream<LatLng> watch({required bool background}) {
    watchCalls++;
    lastBackground = background;
    return controller.stream;
  }
}

class _FakeGps implements GpsService {
  @override
  Future<GpsFix> locate() async =>
      const GpsFix(GpsStatus.ok, lat: 10.71, lon: 106.7);

  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<bool> openLocationSettings() async => false;
}

class _FakeNotifier implements TripNotifier {
  final sent = <(String, String, bool)>[];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> notify(
    int id,
    String title,
    String body, {
    required bool sound,
  }) async => sent.add((title, body, sound));
}

/// Vi do < 10.75 -> phuong p1 (o A, kho rao); con lai p2 (o B, dong).
class _FakeApi extends ApiService {
  _FakeApi() : super(clock: _clock);

  int nearestCalls = 0;
  final hourlyFor = <String>[];

  @override
  Future<Place> nearestLocation(double lat, double lon) async {
    nearestCalls++;
    final a = lat < 10.75;
    return Place(
      id: a ? 'p1' : 'p2',
      name: a ? 'Phường Một' : 'Phường Hai',
      kind: PlaceKind.phuong,
      lat: lat,
      lon: lon,
      cellId: a ? 'A' : 'B',
    );
  }

  @override
  Future<List<dynamic>> fetchHourlyRaw({
    int hours = 24,
    DateTime? at,
    String? locationId,
  }) async {
    hourlyFor.add(locationId!);
    final base = HcmTime.startOfHour(HcmTime.now(_clock));
    return [
      for (var i = 0; i < hours; i++)
        {
          'timestamp': base
              .add(Duration(hours: i))
              .toIso8601String()
              .replaceAll('Z', ''),
          'temperature': 30,
          'weather_code': locationId == 'p2' && i == 1 ? 95 : 3,
          'precipitation': 0,
          'rain_probability': 0.1,
          'source': 'forecast',
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> fetchCurrentRaw({
    DateTime? at,
    String? locationId,
  }) async => {
    'timestamp': HcmTime.now(_clock).toIso8601String().replaceAll('Z', ''),
    'temperature': 31,
    'weather_code': 3,
  };
}

class _FakeRoutes extends RouteService {
  _FakeRoutes({this.build = _routeJson})
    : super(client: MockClient((_) async => http.Response('', 500)));

  final Map<String, dynamic> Function(List<List<double>>, DateTime) build;
  final calls = <(List<LatLng>, DateTime)>[];

  @override
  Future<TripRoute> fetchRoute({
    required LatLng from,
    required LatLng to,
    required DateTime departAt,
    TripProfile profile = TripProfile.driving,
  }) async => TripRoute.fromJson(build(_line, departAt));

  @override
  Future<TripRoute> alongWeather({
    required List<LatLng> geometry,
    required DateTime departAt,
    double? durationMin,
    TripProfile profile = TripProfile.driving,
  }) async {
    calls.add((geometry, departAt));
    return TripRoute.fromJson(
      build([
        for (final p in geometry) [p.latitude, p.longitude],
      ], departAt),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _real = DateTime.utc(2026, 10, 17, 7, 20);
  });

  group('RouteService (MockClient)', () {
    test('missing forecasts keep geometry and unknown hazard', () {
      final body = _limitedRouteJson(_line, HcmTime.now(_clock));
      final route = TripRoute.fromJson(body);
      expect(route.geometry, hasLength(_line.length));
      expect(route.availableSampleCount, 0);
      expect(route.hasCompleteForecastCoverage, isFalse);
      expect(route.hasCompleteHazardCoverage, isFalse);
      expect(route.samples.every((s) => s.hazard == RouteHazard.unknown), isTrue);
      expect(routeHazardScore(route), greaterThan(0));
      expect(routeWeatherSummary(route), contains('Chưa có dự báo'));
      expect(routeCoverageNote(route), contains('không đồng nghĩa tuyến an toàn'));
      expect(
        routeWeatherPolylines(route).every(
          (p) => p.color == hazardColor(RouteHazard.unknown),
        ),
        isTrue,
      );
    });

    test('own AI cannot exclude storms or gusts even with a derived code', () {
      final body = _limitedRouteJson(_line, HcmTime.now(_clock), ownAi: true);
      final samples = body['samples'] as List<Map<String, dynamic>>;
      for (final s in samples) {
        s['weather_code'] = 1;
        s['wind_gusts'] = 0.0;
        s['hazard_assessment_complete'] = true;
      }
      final route = TripRoute.fromJson(body);
      expect(route.hasCompleteForecastCoverage, isTrue);
      expect(route.hasCompleteHazardCoverage, isFalse);
      expect(route.hasOwnModelForecasts, isTrue);
      expect(route.samples.every((s) => s.hazard == RouteHazard.unknown), isTrue);
      expect(routeWeatherSummary(route), contains('Chưa đủ dữ liệu'));
      expect(routeCoverageNote(route), contains('không dự báo dông hay gió giật'));
      samples.first.addAll({'precipitation': 12.0, 'alert': true});
      expect(TripRoute.fromJson(body).samples.first.hazard, RouteHazard.heavy);
    });

    test('legacy fields distinguish complete, partial and unknown coverage', () {
      final body = _routeJson(_line, HcmTime.now(_clock), stormLat: -1);
      final complete = TripRoute.fromJson(body);
      expect(complete.hasCompleteHazardCoverage, isTrue);
      expect(complete.samples.first.hazard, RouteHazard.none);
      final samples = body['samples'] as List<Map<String, dynamic>>;
      samples.last.addAll({
        'temperature': null,
        'precipitation': null,
        'rain_probability': null,
        'weather_code': null,
        'wind_gusts': null,
        'source': null,
      });
      final partial = TripRoute.fromJson(body);
      expect(partial.availableSampleCount, samples.length - 1);
      expect(partial.hasCompleteForecastCoverage, isFalse);
      expect(partial.hasCompleteHazardCoverage, isFalse);
      expect(routeWeatherSummary(partial), contains('chưa đầy đủ'));
      expect(partial.samples.last.hazard, RouteHazard.unknown);
    });

    test('GET /route: tham so + parse', () async {
      late Uri seen;
      final svc = RouteService(
        baseUrl: 'http://x',
        client: MockClient((req) async {
          seen = req.url;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(_routeJson(_line, DateTime.utc(2026, 10, 17, 14))),
            ),
            200,
          );
        }),
      );
      final r = await svc.fetchRoute(
        from: const LatLng(10.7, 106.7),
        to: const LatLng(10.8, 106.7),
        departAt: DateTime.utc(2026, 10, 17, 14),
        profile: TripProfile.cycling,
      );
      expect(seen.path, '/route');
      expect(seen.queryParameters['profile'], 'cycling');
      expect(seen.queryParameters['depart_at'], '2026-10-17T14:00:00+07:00');
      expect(r.geometry, hasLength(11));
      expect(r.alert, isTrue);
      expect(r.worstAlert!.isStorm, isTrue);
      expect(r.departAt.hour, 14);
      expect(r.attribution, contains('OpenStreetMap'));
    });

    test('loi 503 / 400 / 404', () async {
      Future<RouteErrorKind> kindFor(int code) async {
        final svc = RouteService(
          baseUrl: 'http://x',
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(jsonEncode({'detail': 'Ngoài TP.HCM'})),
              code,
            ),
          ),
        );
        try {
          await svc.fetchRoute(
            from: const LatLng(1, 1),
            to: const LatLng(2, 2),
            departAt: DateTime.utc(2026),
          );
        } on RouteException catch (e) {
          if (code == 400) expect(e.message, 'Ngoài TP.HCM');
          return e.kind;
        }
        fail('khong nem loi');
      }

      expect(await kindFor(503), RouteErrorKind.unavailable);
      expect(await kindFor(400), RouteErrorKind.badRequest);
      expect(await kindFor(404), RouteErrorKind.noRoute);
    });

    test('POST /route/along-weather gui geometry + depart_at', () async {
      late Map<String, dynamic> body;
      final svc = RouteService(
        baseUrl: 'http://x',
        client: MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/route/along-weather');
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(_routeJson(_line, DateTime.utc(2026, 10, 17, 14))),
            ),
            200,
          );
        }),
      );
      await svc.alongWeather(
        geometry: const [LatLng(10.7, 106.7), LatLng(10.8, 106.7)],
        departAt: DateTime.utc(2026, 10, 17, 14, 30),
        durationMin: 20,
      );
      expect(body['geometry'], [
        [10.7, 106.7],
        [10.8, 106.7],
      ]);
      expect(body['depart_at'], '2026-10-17T14:30:00+07:00');
      expect(body['duration_min'], 20);
      expect(body['profile'], 'driving');
    });
  });

  group('TripProvider', () {
    late _FakeLocation loc;
    late _FakeNotifier notifier;
    late _FakeApi api;
    late _FakeRoutes routes;
    late TripProvider trip;

    setUp(() {
      loc = _FakeLocation();
      notifier = _FakeNotifier();
      api = _FakeApi();
      routes = _FakeRoutes();
      trip = TripProvider(
        routes: routes,
        api: api,
        location: loc,
        notifier: notifier,
        clock: _clock,
        tickEvery: null,
      );
    });

    tearDown(() => trip.dispose());

    test('khong co tuyen: doi o thi kiem tra, chong trung, 15 phut', () async {
      expect(await trip.start(), GpsStatus.ok);
      expect(trip.phase, TripPhase.active);

      loc.controller.add(const LatLng(10.70, 106.7));
      await pumpEventQueue();
      await trip.idle;
      expect(api.hourlyFor, ['p1']);
      expect(notifier.sent, isEmpty);

      // Cung o A -> khong kiem tra lai.
      loc.controller.add(const LatLng(10.705, 106.7));
      await pumpEventQueue();
      await trip.idle;
      expect(api.hourlyFor, ['p1']);

      // Sang o B (co dong) -> kiem tra + thong bao.
      loc.controller.add(const LatLng(10.76, 106.7));
      await pumpEventQueue();
      await trip.idle;
      expect(api.hourlyFor, ['p1', 'p2']);
      expect(notifier.sent, hasLength(1));
      expect(notifier.sent.single.$1, contains('Dông'));
      expect(notifier.sent.single.$3, isTrue);

      // Chua du 15 phut -> khong kiem tra.
      _real = _real.add(const Duration(minutes: 5));
      await trip.tick();
      expect(api.hourlyFor, hasLength(2));

      // Qua 15 phut -> kiem tra lai nhung khong bao trung.
      _real = _real.add(const Duration(minutes: 11));
      await trip.tick();
      expect(api.hourlyFor, ['p1', 'p2', 'p2']);
      expect(notifier.sent, hasLength(1));
    });

    test('tam dung: bo qua vi tri va kiem tra; tiep tuc nghe lai', () async {
      await trip.start();
      trip.pause();
      expect(trip.phase, TripPhase.paused);
      loc.controller.add(const LatLng(10.76, 106.7));
      _real = _real.add(const Duration(minutes: 30));
      await pumpEventQueue();
      await trip.tick();
      expect(api.nearestCalls, 0);
      expect(notifier.sent, isEmpty);

      trip.resume();
      expect(trip.phase, TripPhase.active);
      expect(loc.watchCalls, 2);
      loc.controller.add(const LatLng(10.76, 106.7));
      await pumpEventQueue();
      await trip.idle;
      expect(notifier.sent, hasLength(1));
    });

    test('tat am thanh -> thong bao khong kem am', () async {
      trip.setSound(false);
      await trip.start();
      loc.controller.add(const LatLng(10.76, 106.7));
      await pumpEventQueue();
      await trip.idle;
      expect(notifier.sent.single.$3, isFalse);
    });

    test('lich su: chi id phuong + thoi gian + canh bao, khong GPS', () async {
      await trip.start();
      loc.controller.add(const LatLng(10.70123, 106.70456));
      await pumpEventQueue();
      await trip.idle;
      loc.controller.add(const LatLng(10.76789, 106.70456));
      await pumpEventQueue();
      await trip.idle;
      _real = _real.add(const Duration(minutes: 20));
      await trip.end();
      expect(trip.phase, TripPhase.ended);

      final rec = trip.history.single;
      expect(rec.fromId, 'p1');
      expect(rec.toId, 'p2');
      expect(rec.alerts, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(TripProvider.historyKey)!;
      expect(raw, isNot(contains('lat')));
      expect(raw, isNot(contains('lon')));
      expect(raw, isNot(contains('10.7')));
      expect(raw, isNot(contains('106.7')));

      // Doc lai, xoa.
      final again = TripProvider(
        routes: routes,
        api: api,
        location: loc,
        notifier: notifier,
        clock: _clock,
        tickEvery: null,
      );
      await again.load();
      expect(again.history.single.toId, 'p2');
      await again.deleteRecord(again.history.single.id);
      expect(again.history, isEmpty);
      again.dispose();
    });

    test(
      'co tuyen: bao doan dong phia truoc, 10 phut lam moi, chong trung',
      () async {
        final plan = TripRoute.fromJson(_routeJson(_line, trip.nowHcm));
        await trip.start(route: plan, fromId: 'p1', toId: 'p2');
        await trip.idle;
        expect(routes.calls, hasLength(1));
        expect(routes.calls.single.$2, trip.nowHcm);
        expect(notifier.sent, hasLength(1));
        final body = notifier.sent.single.$2;
        expect(body, contains('km nữa'));
        expect(body, contains('lúc 14:'));
        expect(notifier.sent.single.$1, 'Phía trước: Dông');

        // Chua 10 phut -> khong goi lai.
        _real = _real.add(const Duration(minutes: 3));
        await trip.tick();
        expect(routes.calls, hasLength(1));

        // Di toi 10.72, qua 10 phut -> chi gui phan tuyen con lai.
        loc.controller.add(const LatLng(10.72, 106.7));
        await pumpEventQueue();
        await trip.idle;
        _real = _real.add(const Duration(minutes: 8));
        await trip.tick();
        expect(routes.calls, hasLength(2));
        expect(routes.calls.last.$1.first.latitude, closeTo(10.72, 1e-9));
        expect(routes.calls.last.$2, trip.nowHcm);
        expect(trip.remainingKm, closeTo(8.9, 0.2));
        // Cung doan dong -> khong bao lai.
        expect(notifier.sent, hasLength(1));

        await trip.end();
        expect(trip.history.single.withRoute, isTrue);
        expect(trip.history.single.fromId, 'p1');
      },
    );

    test('khong co quyen vi tri -> khong bat dau', () async {
      loc.status = GpsStatus.denied;
      expect(await trip.start(), GpsStatus.denied);
      expect(trip.phase, TripPhase.idle);
      expect(trip.error, isNotNull);
    });
  });

  group('cau hinh nen tang', () {
    test('geolocator: loc 500 m, nen iOS / Android', () {
      final ios = GeolocatorTripLocation.settingsFor(
        background: true,
        platform: TargetPlatform.iOS,
        web: false,
      ) as AppleSettings;
      expect(ios.distanceFilter, 500);
      expect(ios.allowBackgroundLocationUpdates, isTrue);
      expect(ios.showBackgroundLocationIndicator, isTrue);
      final android = GeolocatorTripLocation.settingsFor(
        background: true,
        platform: TargetPlatform.android,
        web: false,
      ) as AndroidSettings;
      expect(android.distanceFilter, 500);
      expect(android.foregroundNotificationConfig, isNotNull);
      final fg = GeolocatorTripLocation.settingsFor(
        background: false,
        platform: TargetPlatform.android,
        web: false,
      ) as AndroidSettings;
      expect(fg.foregroundNotificationConfig, isNull);
    });

    test(
      'Info.plist co che do nen location; manifest co foreground service',
      () {
        final plist = File('ios/Runner/Info.plist').readAsStringSync();
        expect(plist, contains('<string>location</string>'));
        final m = File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync();
        expect(m, contains('android.permission.FOREGROUND_SERVICE"'));
        expect(m, contains('android.permission.FOREGROUND_SERVICE_LOCATION'));
        expect(m, isNot(contains('ACCESS_BACKGROUND_LOCATION"/>')));
      },
    );
  });

  group('TripScreen', () {
    Future<TripProvider> pump(
      WidgetTester tester, {
      bool quickStart = false,
      Size size = const Size(390, 2600),
      double textScale = 1,
      _FakeRoutes? routes,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final trip = TripProvider(
        routes: routes ?? _FakeRoutes(),
        api: _FakeApi(),
        location: _FakeLocation(),
        notifier: _FakeNotifier(),
        clock: _clock,
        tickEvery: null,
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => WeatherProvider(
                apiService: _FakeApi(),
                initialSettings: const AppSettings(),
                clock: _clock,
              ),
            ),
            ChangeNotifierProvider<TripProvider>.value(value: trip),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(textScale),
              ),
              child: AppSceneScope(child: child!),
            ),
            home: TripScreen(
              locations: LocationProvider(apiService: _FakeApi()),
              showTiles: false,
              gps: _FakeGps(),
              quickStart: quickStart,
            ),
          ),
        ),
      );
      await tester.pump();
      return trip;
    }

    testWidgets('ke hoach, dang di (nut lon), ket thuc', (tester) async {
      final trip = await pump(tester);
      expect(find.text('Chuyến đi'), findsOneWidget);
      expect(find.text('Có tuyến đường'), findsOneWidget);
      expect(find.text('LỊCH SỬ CHUYẾN ĐI'), findsOneWidget);

      await tester.tap(find.text('Không có tuyến'));
      await tester.pump();
      final start = find.text('Bắt đầu theo dõi');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      await tester.pump();
      expect(trip.phase, TripPhase.active);
      expect(find.text('Không thao tác khi đang lái xe'), findsOneWidget);
      final pause = find.ancestor(
        of: find.text('Tạm dừng'),
        matching: find.byType(SizedBox),
      );
      expect(tester.getSize(pause.first).height, greaterThanOrEqualTo(64));

      await tester.tap(find.text('Tạm dừng'));
      await tester.pump();
      expect(find.text('Đã tạm dừng'), findsOneWidget);
      await tester.tap(find.text('Kết thúc'));
      await tester.pump();
      await tester.pump();
      expect(find.text('CHUYẾN ĐI ĐÃ KẾT THÚC'), findsOneWidget);
      trip.dispose();
    });

    testWidgets('quickStart: mua 2 gio toi tai cho + 2 nut', (tester) async {
      final trip = await pump(tester, quickStart: true);
      await tester.pump();
      await tester.pump();
      expect(find.text('MƯA TRONG 2 GIỜ TỚI TẠI CHỖ BẠN'), findsOneWidget);
      expect(trip.nowcastPlace?.name, 'Phường Một');
      expect(trip.nowcastHours, hasLength(3));
      expect(find.text('Bây giờ'), findsOneWidget);
      expect(find.textContaining('chưa cần áo mưa'), findsOneWidget);
      expect(find.text('Bắt đầu theo dõi'), findsOneWidget);
      // Nut lon >= 64 dp, nut phu >= 48 dp.
      final big = find.ancestor(
        of: find.text('Bắt đầu theo dõi'),
        matching: find.byType(FilledButton),
      );
      expect(tester.getSize(big).height, greaterThanOrEqualTo(64));
      final pick = find.ancestor(
        of: find.text('Chọn điểm đến'),
        matching: find.byType(OutlinedButton),
      );
      expect(tester.getSize(pick).height, greaterThanOrEqualTo(48));
      await tester.tap(pick);
      await tester.pump();
      expect(find.text('Xe máy'), findsOneWidget);
      expect(find.text('Chọn điểm đến để xem tuyến.'), findsWidgets);
      // Cau quyen rieng tu chi con mot lan.
      expect(find.textContaining('Không lưu đường đi GPS'), findsOneWidget);
      trip.dispose();
    });

    testWidgets('360x740, textScale 2: khong tran', (tester) async {
      final trip = await pump(
        tester,
        quickStart: true,
        size: const Size(360, 740),
        textScale: 2,
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Chọn điểm đến'), 200);
      await tester.tap(find.text('Chọn điểm đến'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      trip.dispose();
    });

    for (final ownAi in [false, true]) {
      testWidgets('limited route coverage (own AI: $ownAi)', (tester) async {
        final trip = await pump(
          tester,
          routes: _FakeRoutes(
            build: (geo, depart) => _limitedRouteJson(geo, depart, ownAi: ownAi),
          ),
        );
        await trip.planRoute(
          from: const LatLng(10.7, 106.7),
          to: const LatLng(10.8, 106.7),
          departAt: trip.nowHcm,
        );
        await trip.compareDepartures();
        await tester.pump();
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(find.text(routeWeatherSummary(trip.plan!)), findsOneWidget);
        expect(find.text(routeCoverageNote(trip.plan!)!), findsOneWidget);
        expect(
          find.text('Chưa đủ dữ liệu để kết luận giờ đi tốt nhất.'),
          findsOneWidget,
        );
        expect(
          find.text('Không có đoạn mưa lớn, dông hay gió giật trên tuyến.'),
          findsNothing,
        );
        await trip.start(route: trip.plan);
        await trip.idle;
        await tester.pump();
        expect(find.text(routeWeatherSummary(trip.ahead!)), findsOneWidget);
        expect(
          find.text('Không có mưa lớn hay dông trên phần đường còn lại.'),
          findsNothing,
        );
        trip.dispose();
      });
    }

    testWidgets('tuyen: ban do + tom tat + attribution', (tester) async {
      final trip = await pump(tester);
      await trip.planRoute(
        from: const LatLng(10.7, 106.7),
        to: const LatLng(10.8, 106.7),
        departAt: trip.nowHcm,
      );
      await trip.compareDepartures();
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('TÓM TẮT TUYẾN'), findsOneWidget);
      expect(find.textContaining('Đoạn xấu nhất: Dông'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors, OSRM'), findsOneWidget);
      expect(find.textContaining('tốt nhất'), findsOneWidget);
      expect(
        routeWeatherPolylines(trip.plan!)
            .any((p) => p.color == hazardColor(RouteHazard.storm)),
        isTrue,
      );
      trip.dispose();
    });
  });
}
