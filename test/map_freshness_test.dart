import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/data_source.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/map/cell_sheet.dart';
import 'package:sky_weather_app/screens/map/map_overlays.dart';
import 'package:sky_weather_app/screens/map/map_scale.dart';
import 'package:sky_weather_app/screens/map/map_cells.dart';

final _now = DateTime.utc(2026, 11, 2);
Map<String, dynamic> _reading({
  String? observed = '2026-11-01T12:00:00+07:00',
}) => {
  'cell_id': 'a',
  'lat': 10.77,
  'lon': 106.7,
  'location_ids': ['tsn'],
  'temperature': 33,
  'weather_code': 1,
  'source': 'observed',
  'valid_time': '2026-11-02T00:00:00+07:00',
  'observed_at': ?observed,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'actual observation timestamp survives parsing and cache round-trip',
    () {
      final c = MapCell.fromJson(_reading())!;
      expect(c.validTime, _now);
      expect(c.observedAt, DateTime.utc(2026, 11, 1, 12));
      expect(MapCell.fromJson(c.toJson())!.observedAt, c.observedAt);
      expect(c.isStaleAt(_now), isTrue);
      expect(c.isStaleAt(DateTime.utc(2026, 11, 1, 15)), isFalse);
      expect(c.isStaleAt(DateTime.utc(2026, 11, 1, 11)), isTrue);
      final label = mapFrameLabel(
        c.source,
        c.validTime,
        observedAt: c.observedAt,
      );
      expect(label, contains('01/11 12:00'));
      expect(label, isNot(contains('00:00')));
      final marker = buildCellMarkers(
        [c],
        MapLayerKind.temperature,
        temp: (v) => v.round().toString(),
      ).single;
      expect(marker.semantics, contains('01/11 12:00'));
      expect(marker.summary, contains('01/11 12:00'));
    },
  );

  test(
    'legacy payload never substitutes frame time for an unknown reading',
    () {
      final c = MapCell.fromJson(_reading(observed: null))!;
      expect(c.observedAt, isNull);
      final label = mapFrameLabel(
        c.source,
        c.validTime,
        observedAt: c.observedAt,
      );
      expect(label, contains('chưa rõ giờ dữ liệu'));
      expect(label, isNot(contains('00:00')));
      expect(mapFrameLabel(DataSource.ai, _now), 'Dự báo AI: Thứ 2 · 00:00');
    },
  );

  test(
    'network response data age is distinct from cache age and replay clock',
    () {
      final lp = LocationProvider();
      addTearDown(lp.dispose);
      final c = MapCell.fromJson(_reading())!;
      List<String> parts(DateTime now, {bool replay = false}) => mapStatusParts(
        cells: [c],
        isReplay: replay,
        replayAt: replay ? now : null,
        lp: lp,
        nowHcm: now,
      );
      expect(lp.cellsStale, isFalse);
      expect(parts(_now), contains('Dữ liệu cũ'));
      expect(
        parts(DateTime.utc(2026, 11, 1, 13), replay: true),
        isNot(contains('Dữ liệu cũ')),
      );
    },
  );

  test('mixed cell timestamps show range and missing timestamp explicitly', () {
    final lp = LocationProvider();
    addTearDown(lp.dispose);
    final parts = mapStatusParts(
      cells: [
        MapCell.fromJson(_reading())!,
        MapCell.fromJson(_reading(observed: '2026-11-01T13:00:00+07:00'))!,
        MapCell.fromJson(_reading(observed: null))!,
      ],
      isReplay: false,
      replayAt: null,
      lp: lp,
      nowHcm: _now,
    );
    expect(parts.first, contains('từ 01/11 12:00 đến 01/11 13:00'));
    expect(parts, contains('Có ô chưa rõ giờ dữ liệu'));
    expect(parts, contains('Dữ liệu cũ'));
  });

  test('stored map preserves observation time without treating saved_at as reading', () async {
    SharedPreferences.setMockInitialValues({
      LocationProvider.mapKey: jsonEncode({
        'saved_at': '2026-11-02T00:00:00+07:00',
        'cells': [_reading()],
      }),
    });
    final lp = LocationProvider();
    addTearDown(lp.dispose);
    await lp.loadLocal();
    expect(lp.cells.single.observedAt, DateTime.utc(2026, 11, 1, 12));
    final parts = mapStatusParts(
      cells: lp.cells,
      isReplay: false,
      replayAt: null,
      lp: lp,
      nowHcm: _now,
    );
    expect(parts.first, contains('01/11 12:00'));
    expect(parts, contains('Đang dùng bản lưu trên máy'));
  });

  testWidgets('cell sheet at 320px and 200% shows true timestamp and stale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wp = WeatherProvider(
      initialSettings: const AppSettings(),
      clock: () => DateTime.utc(2026, 11, 1, 17),
    );
    addTearDown(wp.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CellSheet(
              cell: MapCell.fromJson(_reading())!,
              provider: wp,
              placeNames: const ['Tân Sơn Nhất'],
              stale: false,
              onDetail: null,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('01/11 12:00'), findsOneWidget);
    expect(find.text('Dữ liệu cũ'), findsOneWidget);
    expect(find.textContaining('02/11 00:00'), findsNothing);
  });
}
