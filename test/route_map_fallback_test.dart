import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:sky_weather_app/config/map_tiles.dart';
import 'package:sky_weather_app/screens/trip/route_map.dart';
import 'package:sky_weather_app/services/route_service.dart';

TripRoute _route() => TripRoute(
  profile: TripProfile.driving,
  departAt: DateTime(2026, 11, 2, 3),
  arriveAt: DateTime(2026, 11, 2, 3, 20),
  distanceKm: 8,
  durationMin: 20,
  geometry: const [LatLng(10.77, 106.69), LatLng(10.81, 106.71)],
  samples: const [],
);

Future<void> _flushTiles(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('primary DNS failure uses fallback without losing geometry', (
    tester,
  ) async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      if (request.url.host == 'tile.openstreetmap.org') {
        throw http.ClientException('DNS failure');
      }
      return http.Response.bytes(
        Uint8List.fromList(TileProvider.transparentImage),
        200,
        headers: {'content-type': 'image/png'},
      );
    });
    addTearDown(client.close);
    final tiles = NetworkTileProvider(
      httpClient: client,
      cachingProvider: const DisabledMapCachingProvider(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteMap(route: _route(), showTiles: true, tileProvider: tiles),
        ),
      ),
    );
    await _flushTiles(tester);
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(layer.urlTemplate, kMapTileUrl);
    expect(layer.fallbackUrl, kMapTileFallbackUrl);
    expect(urls.any((u) => u.host == 'tile.openstreetmap.org'), isTrue);
    expect(urls.any((u) => u.host == 'a.tile.openstreetmap.fr'), isTrue);
    expect(find.textContaining('Không tải được nền'), findsNothing);
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.textContaining('OpenStreetMap France'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('both sources fail: notice, retry and recovery at 320px/200%', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var offline = true;
    final expectedErrors = <Object>[];
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) {
      final error = details.exception;
      if (error is http.ClientException &&
          error.message == 'network unavailable') {
        expectedErrors.add(error);
      } else {
        reportError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = reportError);
    final client = MockClient((request) async {
      if (offline) throw http.ClientException('network unavailable');
      return http.Response.bytes(
        Uint8List.fromList(TileProvider.transparentImage),
        200,
        headers: {'content-type': 'image/png'},
      );
    });
    addTearDown(client.close);
    final tiles = NetworkTileProvider(
      httpClient: client,
      cachingProvider: const DisabledMapCachingProvider(),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: RouteMap(route: _route(), showTiles: true, tileProvider: tiles),
        ),
      ),
    );
    await _flushTiles(tester);
    expect(find.textContaining('Không tải được nền'), findsOneWidget);
    expect(
      tester.getRect(find.textContaining('Không tải được nền')).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.textContaining('OpenStreetMap France')).top,
      ),
    );
    expect(expectedErrors, isNotEmpty);
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(tester.takeException(), isNull);
    offline = false;
    await tester.tap(find.byTooltip('Thử tải lại bản đồ nền'));
    await _flushTiles(tester);
    expect(find.textContaining('Không tải được nền'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
