// Phase C: da dia diem (LocationProvider, Home PageView), danh gia AI theo
// o luoi. Du lieu gia CHI dung trong test (MockClient, khong goi mang that).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/widgets/ai_forecast_card.dart';

class _FakeGps implements GpsService {
  _FakeGps(this.fix);

  final GpsFix fix;

  @override
  Future<GpsFix> locate() async => fix;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

const _wards = [
  {
    'id': 'p_ben_thanh',
    'name': 'Phường Bến Thành',
    'kind': 'ward',
    'lat': 10.772,
    'lon': 106.698,
    'cell_id': 'c_10_77_106_70',
  },
  {
    'id': 'x_can_gio',
    'name': 'Xã Cần Giờ',
    'kind': 'commune',
    'lat': 10.41,
    'lon': 106.95,
    'cell_id': 'c_10_41_106_95',
  },
];

http.Response _json(Object body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), code);

/// Backend gia: ghi lai cac request de kiem tra `location_id`.
MockClient _backend(List<Uri> log) => MockClient((req) async {
  log.add(req.url);
  switch (req.url.path) {
    case '/locations':
      return _json((_wards), 200);
    case '/locations/nearest':
      final lat = double.parse(req.url.queryParameters['lat']!);
      if (lat > 12) {
        return _json(({'detail': 'Ngoài vùng hỗ trợ (TP.HCM)'}), 404);
      }
      return _json((_wards.first), 200);
    case '/weather/map':
      return _json(([
        {
          'cell_id': 'c_10_77_106_70',
          'lat': 10.77,
          'lon': 106.70,
          'location_ids': ['p_ben_thanh'],
          'temperature': 31.2,
          'weather_code': 95,
          'rain_probability_next_3h': 0.8,
          'precipitation_next_3h': 6.5,
          'alert': true,
        },
      ]), 200);
  }
  return _json(({'detail': 'Not Found'}), 404);
});

ApiService _api(List<Uri> log) =>
    ApiService(client: _backend(log), baseUrl: 'http://test');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AIEvaluation', () {
    test('parse evaluation + cau hien thi', () {
      final p = WeatherProvider(initialSettings: const AppSettings());
      final e = AIEvaluation.tryParse({
        'cell_id': 'c1',
        'temperature_mae_1h': 0.42,
        'rain_f1_1h': 0.61,
        'beats_baselines': true,
        'test_period': '2025-01-01..2026-10-10',
      })!;
      expect(e.cellId, 'c1');
      expect(e.rainF1['1h'], 0.61);
      expect(e.testPeriodText, '01/2025 – 10/2026');
      expect(
        AIEvaluationLine.text(e, p),
        'Sai số kiểm chứng tại ô lưới này: ±0,4°C (1h)',
      );
      expect(AIEvaluation.tryParse(null), isNull);
      expect(AIEvaluationLine.text(null, p), 'Chưa có đánh giá tại ô lưới này');
      final bad = AIEvaluation.tryParse({
        'temperature_mae_1h': 0.9,
        'beats_baselines': false,
      });
      expect(
        AIEvaluationLine.text(bad, p),
        contains('chưa vượt mô hình cơ sở'),
      );
    });
  });

  group('MapCell', () {
    test('parse /weather/map', () async {
      final cells = await _api([]).fetchMapCells();
      expect(cells, hasLength(1));
      final c = cells.single;
      expect(c.locationIds, ['p_ben_thanh']);
      expect(c.rainPercent, 80);
      expect(c.alert, isTrue);
    });
  });

  group('ApiService location_id', () {
    test('gui location_id, bo qua voi tsn', () async {
      final log = <Uri>[];
      final api = _api(log);
      await expectLater(
        api.fetchWeatherDataFor('p_ben_thanh'),
        throwsA(isA<ApiException>()),
      );
      expect(
        log.where((u) => u.path.startsWith('/weather/')),
        everyElement(
          predicate<Uri>(
            (u) => u.queryParameters['location_id'] == 'p_ben_thanh',
          ),
        ),
      );
      log.clear();
      await expectLater(
        api.fetchWeatherDataFor(Place.defaultId),
        throwsA(isA<ApiException>()),
      );
      expect(
        log.any((u) => u.queryParameters.containsKey('location_id')),
        isFalse,
      );
    });
  });

  group('LocationProvider', () {
    test('GPS: chi luu id dia diem, khong luu toa do', () async {
      final lp = LocationProvider(
        apiService: _api([]),
        gps: _FakeGps(const GpsFix.at(10.7721, 106.6983)),
      );
      await lp.loadLocal();
      final r = await lp.useCurrentLocation();
      expect(r.ok, isTrue);
      expect(lp.currentLocationId, 'p_ben_thanh');
      expect(lp.pages.first.isCurrentLocation, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getString(LocationProvider.gpsKey), 'p_ben_thanh');
      for (final k in prefs.getKeys()) {
        final v = prefs.get(k).toString();
        expect(v.contains('10.7721'), isFalse, reason: k);
        expect(v.contains('106.6983'), isFalse, reason: k);
      }
    });

    test('Nha la trang dau, ke ca khi co GPS / gan nhan sau', () async {
      final lp = LocationProvider(
        apiService: _api([]),
        gps: _FakeGps(const GpsFix.at(10.7721, 106.6983)),
      );
      await lp.loadLocal();
      await lp.useCurrentLocation();
      lp.addSaved('x_can_gio');
      expect(lp.pages.first.isCurrentLocation, isTrue);
      lp.setLabel(
        lp.saved.indexWhere((s) => s.locationId == 'x_can_gio'),
        PlaceLabel.home,
      );
      expect(lp.pages.first.locationId, 'x_can_gio');
      expect(lp.labelFor(lp.pages.first), 'Nhà');
      expect(lp.pages[1].isCurrentLocation, isTrue);
    });

    test('GPS ngoai TP.HCM', () async {
      final lp = LocationProvider(
        apiService: _api([]),
        gps: _FakeGps(const GpsFix.at(21.03, 105.85)),
      );
      final r = await lp.useCurrentLocation();
      expect(r.kind, GpsOutcomeKind.outsideArea);
      expect(r.message, startsWith('Ngoài vùng hỗ trợ'));
      expect(lp.currentLocationId, isNull);
    });

    test('GPS bi tu choi -> mo cai dat', () async {
      final lp = LocationProvider(
        apiService: _api([]),
        gps: _FakeGps(const GpsFix(GpsStatus.deniedForever)),
      );
      final r = await lp.useCurrentLocation();
      expect(r.kind, GpsOutcomeKind.deniedForever);
      expect(r.canOpenSettings, isTrue);
    });

    test('them / nhan / sap xep / xoa / hoan tac', () async {
      final lp = LocationProvider(
        apiService: _api([]),
        gps: _FakeGps(const GpsFix(GpsStatus.unavailable)),
      );
      await lp.refreshPlaces();
      expect(lp.hasPlaceList, isTrue);
      expect(lp.addSaved('p_ben_thanh', label: PlaceLabel.home), isTrue);
      expect(lp.addSaved('p_ben_thanh'), isFalse);
      lp.addSaved('x_can_gio', label: PlaceLabel.work);
      expect(lp.saved.map((s) => s.locationId), [
        Place.defaultId,
        'p_ben_thanh',
        'x_can_gio',
      ]);
      // "Nhà" la trang dau tien o Home.
      expect(lp.labelFor(lp.pages[0]), 'Nhà');
      lp.moveSaved(2, 0);
      expect(lp.saved.first.locationId, 'x_can_gio');
      final removed = lp.removeSavedAt(0);
      expect(lp.isSaved('x_can_gio'), isFalse);
      lp.insertSaved(0, removed);
      expect(lp.saved.first.label, PlaceLabel.work);
      expect(lp.search('ben thanh').first.id, 'p_ben_thanh');
      expect(lp.placeById('x_can_gio').name, 'Xã Cần Giờ');
    });

    test('o ban do cua dia diem', () async {
      final lp = LocationProvider(apiService: _api([]));
      await lp.refreshPlaces();
      await lp.refreshMap();
      expect(lp.cellFor('p_ben_thanh')?.temperature, 31.2);
      expect(lp.cellFor('x_can_gio'), isNull);
      expect(lp.mapError, isNull);
    });
  });

  group('Home PageView', () {
    testWidgets('moi dia diem da luu la mot trang; vuot doi location_id', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        LocationProvider.savedKey: jsonEncode([
          {'id': 'p_ben_thanh', 'label': 'home'},
          {'id': 'x_can_gio', 'label': 'none'},
        ]),
        LocationProvider.placesKey: jsonEncode(_wards),
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final log = <Uri>[];
      final wp = WeatherProvider(
        apiService: _api(log),
        initialSettings: const AppSettings(),
      );
      final lp = LocationProvider(apiService: _api(log));
      await tester.pumpWidget(
        ChangeNotifierProvider<WeatherProvider>.value(
          value: wp,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: AppSceneScope(child: child!),
            ),
            home: HomeScreen(locations: lp),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(lp.pages, hasLength(2));
      expect(wp.locationId, 'p_ben_thanh');
      expect(find.text('Phường Bến Thành'), findsWidgets);
      expect(find.textContaining('Nhà'), findsWidgets);

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(lp.selectedLocationId, 'x_can_gio');
      expect(wp.locationId, 'x_can_gio');
      expect(
        log.any((u) => u.queryParameters['location_id'] == 'x_can_gio'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
