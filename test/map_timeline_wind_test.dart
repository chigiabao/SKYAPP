// Ban do: lop gio, thanh thoi gian, nguon khung. Du lieu gia CHI dung trong
// test (MockClient, khong goi mang that).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/data_source.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';

Map<String, dynamic> _cell(int offset) => {
  'cell_id': 'c1',
  'lat': 10.77,
  'lon': 106.70,
  'location_ids': ['p1'],
  'temperature': 30.0,
  'weather_code': 3,
  'rain_probability_next_3h': 0.4,
  'precipitation_next_3h': 1.0,
  'alert': false,
  'wind_speed': 21.1,
  'wind_direction': 90.0,
  'wind_gusts': 55.0,
  'precipitation': 0.3,
  'source': offset == 0 ? 'observed' : 'forecast',
  'valid_time':
      '2026-10-17T${(15 + offset).toString().padLeft(2, '0')}:00:00+07:00',
  'outlook_source': 'forecast',
  'max_offset_hours': 72,
};

ApiService _api(List<Uri> log) => ApiService(
  baseUrl: 'http://test',
  client: MockClient((req) async {
    log.add(req.url);
    if (req.url.path == '/weather/map') {
      final off = int.parse(req.url.queryParameters['offset_hours'] ?? '0');
      return http.Response.bytes(utf8.encode(jsonEncode([_cell(off)])), 200);
    }
    return http.Response('{"detail":"Not Found"}', 404);
  }),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('MapCell truong moi', () {
    test('parse day du', () {
      final c = MapCell.fromJson(_cell(3))!;
      expect(c.windSpeed, 21.1);
      expect(c.windDirection, 90);
      expect(c.windGusts, 55);
      expect(c.precipitation, 0.3);
      expect(c.source, DataSource.forecast);
      expect(c.validTime, DateTime.utc(2026, 10, 17, 18));
      expect(c.outlookSource, 'forecast');
      expect(c.maxOffsetHours, 72);
      final back = MapCell.fromJson(c.toJson())!;
      expect(back.validTime, c.validTime);
      expect(back.source, c.source);
    });

    test('parse null / thieu', () {
      final c = MapCell.fromJson({
        ..._cell(0),
        'wind_speed': null,
        'wind_direction': null,
        'wind_gusts': null,
        'precipitation': null,
        'source': null,
        'valid_time': null,
        'outlook_source': null,
        'max_offset_hours': null,
      })!;
      expect(c.windSpeed, isNull);
      expect(c.windDirection, isNull);
      expect(c.source, isNull);
      expect(c.validTime, isNull);
      expect(c.outlookSource, isNull);
      expect(windText(c), 'gió không có dữ liệu');
      expect(mapFrameLabel(c.source, c.validTime), isNull);
      expect(outlookSourceLabel('ai'), 'Dự báo AI (xem lại)');
      expect(outlookSourceLabel('forecast'), 'Dự báo Open-Meteo');
    });

    test('nhan khung quan trac / du bao', () {
      final t = DateTime.utc(2026, 10, 17, 18);
      expect(
        mapFrameLabel(DataSource.observed, DateTime.utc(2026, 10, 17, 15)),
        'Thực tế (dữ liệu phân tích) lúc 15:00',
      );
      expect(mapFrameLabel(DataSource.forecast, t), 'Dự báo lúc 18:00 thứ Bảy');
      expect(offsetLabel(0), 'Bây giờ');
      expect(offsetLabel(3), '+3 giờ');
    });
  });

  group('LocationProvider offset', () {
    test('doi offset goi dung URL va dung cache', () async {
      final log = <Uri>[];
      final lp = LocationProvider(apiService: _api(log));
      await lp.refreshMap();
      expect(log.last.queryParameters.containsKey('offset_hours'), isFalse);
      await lp.setMapOffset(3);
      expect(log.last.queryParameters['offset_hours'], '3');
      expect(lp.mapOffset, 3);
      expect(lp.cells.first.source, DataSource.forecast);
      final n = log.length;
      await lp.setMapOffset(0);
      await lp.setMapOffset(3);
      expect(log.length, n, reason: 'khung 0 va 3 lay tu cache');
      expect(lp.cachedFrameCount, 2);
      expect(lp.mapMaxOffset, 72);
    });

    test('xem lai luon offset 0', () async {
      final log = <Uri>[];
      final lp = LocationProvider(apiService: _api(log));
      await lp.setMapOffset(5);
      await lp.refreshMap(at: DateTime.utc(2026, 10, 10, 12));
      expect(lp.mapOffset, 0);
      expect(log.last.queryParameters.containsKey('offset_hours'), isFalse);
      expect(log.last.queryParameters['at'], '2026-10-10T12:00:00+07:00');
    });
  });

  group('O luoi', () {
    const a = MapCell(cellId: 'a', lat: 10.80, lon: 106.70, locationIds: []);
    const b = MapCell(cellId: 'b', lat: 10.80, lon: 106.78, locationIds: []);

    test('cellAt: diem trong / bien / ngoai o', () {
      expect(cellAt([a, b], const LatLng(10.80, 106.70))?.cellId, 'a');
      expect(cellAt([a, b], const LatLng(10.83, 106.73))?.cellId, 'a');
      expect(cellAt([a, b], const LatLng(10.77, 106.80))?.cellId, 'b');
      expect(cellAt([a, b], const LatLng(10.90, 106.70)), isNull);
      expect(cellAt([a, b], const LatLng(10.80, 106.60)), isNull);
      expect(cellAt(const <MapCell>[], const LatLng(10.8, 106.7)), isNull);
    });

    test('cellAt: vung chong lay o co tam gan nhat', () {
      expect(cellAt([a, b], const LatLng(10.80, 106.739))?.cellId, 'a');
      expect(cellAt([a, b], const LatLng(10.80, 106.741))?.cellId, 'b');
    });

    test('cellRect bao tam o, cung kich thuoc luoi', () {
      final r = cellRect(a);
      expect(r, hasLength(4));
      expect(r[1].longitude - r[0].longitude, closeTo(kCellDLon, 1e-9));
      expect(r[0].latitude - r[3].latitude, closeTo(kCellDLat, 1e-9));
      expect(cellAt([a], r[2]), isNotNull);
    });

    test('nguong nhan theo kich thuoc pixel', () {
      const t = MapLayerKind.temperature, w = MapLayerKind.wind;
      expect(labelModeFor(35.9, t), CellLabelMode.none);
      expect(labelModeFor(36, t), CellLabelMode.value);
      expect(labelModeFor(80, t), CellLabelMode.value);
      expect(labelModeFor(35.9, w), CellLabelMode.none);
      expect(labelModeFor(40, w), CellLabelMode.value);
      expect(labelModeFor(44, w), CellLabelMode.valueArrow);
      expect(labelModeFor(44, MapLayerKind.rain), CellLabelMode.value);
    });

    test('kich thuoc o tang gap doi moi muc zoom', () {
      expect(cellPixelWidth(10) / cellPixelWidth(9), closeTo(2, 1e-9));
      expect(cellPixelWidth(9), lessThan(kLabelMinPx)); // ~ zoom mac dinh
      expect(cellPixelWidth(11), greaterThan(kArrowMinPx));
    });

    test('mau chu tren o tuong phan >= 4.5:1', () {
      double contrast(Color x, Color y) {
        final lx = x.computeLuminance(), ly = y.computeLuminance();
        return (math.max(lx, ly) + 0.05) / (math.min(lx, ly) + 0.05);
      }

      for (final c in [
        ...MapScale.tempColors,
        ...MapScale.rainColors,
        ...MapScale.windColors,
        MapScale.noData,
      ]) {
        final bg = cellFillOnBase(c);
        expect(contrast(labelInkFor(bg), bg), greaterThanOrEqualTo(4.5));
      }
    });

    testWidgets('CellLabel: so + mui ten gio xoay dung', (tester) async {
      final d = buildCellMarkers(
        [MapCell.fromJson(_cell(0))!],
        MapLayerKind.wind,
        temp: (c) => c.round().toString(),
      ).single;
      await tester.pumpWidget(
        MaterialApp(home: CellLabel(data: d, arrow: true)),
      );
      expect(find.text('21'), findsOneWidget);
      final arrow = tester.widget<Transform>(
        find.byKey(const ValueKey('wind-arrow')),
      );
      final expected = Matrix4.rotationZ(3 * math.pi / 2);
      for (var i = 0; i < 16; i++) {
        expect(arrow.transform.storage[i], closeTo(expected.storage[i], 1e-6));
      }
      await tester.pumpWidget(
        MaterialApp(home: CellLabel(data: d, arrow: false)),
      );
      expect(find.byKey(const ValueKey('wind-arrow')), findsNothing);
    });
  });

  group('Mui ten gio', () {
    test('chi huong thoi TOI', () {
      expect(windArrowAngle(0), closeTo(math.pi, 1e-9)); // tu Bac -> Nam
      expect(windArrowAngle(90), closeTo(3 * math.pi / 2, 1e-9)); // -> Tay
      expect(windArrowAngle(270), closeTo(math.pi / 2, 1e-9)); // -> Dong
      expect(windArrowAngle(180), closeTo(0, 1e-9));
    });
  });

  group('MapTimeBar', () {
    Widget host(Widget child, {bool reduce = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(body: child),
      ),
    );

    MapTimeBar bar({bool locked = false, bool reduce = false}) => MapTimeBar(
      value: 3,
      max: 72,
      base: DateTime.utc(2026, 10, 17, 15),
      locked: locked,
      loading: false,
      playing: false,
      reduceMotion: reduce,
      onChanged: (_) {},
      onChangeEnd: (_) {},
      onTogglePlay: () {},
    );

    testWidgets('xem lai: khoa slider', (tester) async {
      await tester.pumpWidget(host(bar(locked: true)));
      expect(find.byType(Slider), findsNothing);
      expect(find.text(MapTimeBar.lockedText), findsOneWidget);
    });

    testWidgets('slider co gia tri dang chu', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(bar()));
      expect(find.text('+3 giờ · 18:00 thứ Bảy 17/10'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(
        slider.semanticFormatterCallback!(3),
        '+3 giờ, 18:00 thứ Bảy 17/10',
      );
      expect(
        slider.semanticFormatterCallback!(0),
        'Bây giờ, 15:00 thứ Bảy 17/10',
      );
      handle.dispose();
    });

    testWidgets('giam chuyen dong: tat nut tu chay', (tester) async {
      await tester.pumpWidget(host(bar(reduce: true)));
      final btn = tester.widget<GlassIconButton>(find.byType(GlassIconButton));
      expect(btn.onPressed, isNull);
    });
  });

  testWidgets('bo chon lop Gio ve mui ten + chu giai', (tester) async {
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
          home: MapScreen(locations: lp, showTiles: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('wind-arrow')), findsNothing);
    expect(find.textContaining('Thực tế (dữ liệu phân tích)'), findsOneWidget);

    await tester.tap(find.text('Gió'));
    await tester.pump();
    // Zoom mac dinh: o nho -> chi to mau, khong ve so/mui ten tren o.
    expect(find.byType(CellLabel), findsNothing);
    expect(find.byKey(const ValueKey('wind-arrow')), findsNothing);
    expect(find.text('Ô có cảnh báo mưa/dông'), findsOneWidget);

    // Danh sach thay the van doc duoc huong gio.
    await tester.tap(find.byTooltip('Xem dạng danh sách'));
    await tester.pumpAndSettle();
    final arrow = tester.widget<Transform>(
      find.byKey(const ValueKey('list-wind-arrow')).first,
    );
    // Gio tu Dong (90 do) -> mui ten chi Tay (270 do).
    final expected = Matrix4.rotationZ(3 * math.pi / 2);
    for (var i = 0; i < 16; i++) {
      expect(arrow.transform.storage[i], closeTo(expected.storage[i], 1e-6));
    }
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('CÁC PHƯỜNG, XÃ TRONG Ô'), findsOneWidget);
    Navigator.of(tester.element(find.byType(CellSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('GIÓ (KM/H)'), findsOneWidget);
    expect(find.textContaining('Giật ≥ 50 km/h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
