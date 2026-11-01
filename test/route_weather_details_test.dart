import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/screens/trip/route_map.dart';
import 'package:sky_weather_app/screens/trip/route_weather_details.dart';
import 'package:sky_weather_app/services/route_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';

const _points = [LatLng(10.77, 106.69), LatLng(10.81, 106.71)];
final _depart = DateTime(2026, 11, 2, 4);

TripRoute _route(List<RouteSample> samples) => TripRoute(
  profile: TripProfile.driving,
  departAt: _depart,
  arriveAt: _depart.add(const Duration(minutes: 20)),
  distanceKm: 8,
  durationMin: 20,
  geometry: _points,
  samples: samples,
);

RouteSample _sample({bool destination = false, bool unavailable = false}) =>
    RouteSample(
      point: destination ? _points.last : _points.first,
      eta: _depart.add(Duration(minutes: destination ? 20 : 0)),
      temperature: destination ? 32 : 28,
      humidity: destination ? 70 : 85,
      windSpeed: destination ? 12 : 5,
      windGusts: destination ? 20 : 9,
      uvIndex: destination ? null : 0,
      precipitation: 0,
      rainProbability: destination ? 0.2 : 0.1,
      source: 'ai',
      forecastAvailable: !unavailable,
    );

Widget _details(TripRoute route, {UnitPrefs units = const UnitPrefs()}) =>
    RouteWeatherDetails(
      route: route,
      units: units,
      fromLabel: 'Vị trí hiện tại (GPS)',
      toLabel: 'Sân bay Tân Sơn Nhất',
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: AppScene(
        data: const AppSceneData(
          scene: WeatherScene.clearNight,
          isDay: false,
          windSpeedKmh: 5,
          intensity: 0,
          resolved: WeatherScene.clearNight,
        ),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
}

void main() {
  test('new route fields parse independently, including real zeros', () {
    final sample = RouteSample.fromJson({
      'lat': 10.77,
      'lon': 106.69,
      'eta': '2026-11-02T04:00:00+07:00',
      'humidity': 0,
      'wind_speed': 12.5,
      'uv_index': 0,
    });
    expect(sample.humidity, 0);
    expect(sample.windSpeed, 12.5);
    expect(sample.uvIndex, 0);
    expect(sample.temperature, isNull);
    expect(sample.forecastAvailable, isTrue);
    expect(sample.hazard, RouteHazard.unknown);
  });

  for (final width in [320.0, 390.0, 900.0]) {
    testWidgets('endpoints and actual non-rain weather at width $width', (
      tester,
    ) async {
      await _pump(
        tester,
        _details(_route([_sample(), _sample(destination: true)])),
        width: width,
        scale: width == 320 ? 2 : 1,
      );
      expect(find.text('Vị trí hiện tại (GPS)'), findsOneWidget);
      expect(find.text('Điểm đến · Sân bay Tân Sơn Nhất'), findsOneWidget);
      expect(find.text('Nhiệt độ: 28°C'), findsOneWidget);
      expect(find.text('Nhiệt độ: 32°C'), findsOneWidget);
      expect(find.text('Độ ẩm: 85%'), findsOneWidget);
      expect(find.text('Gió: 12 km/h'), findsOneWidget);
      expect(find.text('Gió giật: 20 km/h'), findsOneWidget);
      expect(find.text('UV: 0.0'), findsOneWidget);
      expect(find.text('UV: Chưa có dữ liệu'), findsOneWidget);
      expect(find.text('04:00 · AI của nhóm'), findsOneWidget);
      expect(find.text('04:20 · AI của nhóm'), findsOneWidget);
      expect(find.textContaining('Nhiệt độ: 28°C – 32°C'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing, invalid, explicitly unavailable do not become zeros', (
    tester,
  ) async {
    await _pump(
      tester,
      _details(
        _route([
          RouteSample(
            point: _points.first,
            eta: _depart,
            temperature: double.nan,
            humidity: 120,
            windSpeed: -5,
            windGusts: double.infinity,
            uvIndex: -1,
            rainProbability: 2,
            precipitation: -1,
            source: 'ai',
            forecastAvailable: true,
          ),
          _sample(destination: true, unavailable: true),
        ]),
      ),
    );
    expect(find.textContaining('Chưa có dữ liệu'), findsNWidgets(14));
    expect(find.textContaining('Dọc tuyến'), findsNothing);
    expect(find.textContaining('0 km/h'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('weather respects chosen temperature and wind units', (
    tester,
  ) async {
    await _pump(
      tester,
      _details(
        _route([_sample(), _sample(destination: true)]),
        units: const UnitPrefs(temp: TempUnit.fahrenheit, wind: WindUnit.mph),
      ),
    );
    expect(find.text('Nhiệt độ: 82°F'), findsOneWidget);
    expect(find.text('Gió: 7 mph'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map endpoint symbols have distinct accessible location names', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      RouteMap(
        route: _route([]),
        showTiles: false,
        fromLabel: 'Vị trí hiện tại (GPS)',
        toLabel: 'Điểm đến · Sân bay',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('A · Vị trí hiện tại (GPS)'), findsOneWidget);
    expect(find.byTooltip('B · Điểm đến · Sân bay'), findsOneWidget);
    expect(find.bySemanticsLabel('A · Vị trí hiện tại (GPS)'), findsOneWidget);
    expect(find.bySemanticsLabel('B · Điểm đến · Sân bay'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  for (final destination in [false, true]) {
    testWidgets(
      'alert at endpoint does not cover A/B (destination: $destination)',
      (tester) async {
        final warning = RouteSample(
          point: destination ? _points.last : _points.first,
          eta: _depart,
          precipitation: 8,
          source: 'ai',
          alert: true,
        );
        final route = TripRoute(
          profile: TripProfile.driving,
          departAt: _depart,
          arriveAt: _depart,
          distanceKm: 8,
          durationMin: 20,
          geometry: _points,
          samples: [warning],
          worst: warning,
        );
        await _pump(tester, RouteMap(route: route, showTiles: false));
        await tester.pumpAndSettle();
        final endpoint = tester.getRect(find.text(destination ? 'B' : 'A'));
        final alert = tester.getRect(find.byIcon(Icons.warning_rounded));
        expect(alert.bottom, lessThan(endpoint.top));
        expect(alert.top, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
