import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/config/map_tiles.dart';
import 'package:sky_weather_app/widgets/map_attribution_link.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  for (final result in ['success', 'unavailable', 'error']) {
    testWidgets('map license link: $result', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (result == 'error') throw PlatformException(code: 'no_browser');
        return result == 'success';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MapAttributionLink(text: kMapTileAttribution)),
        ),
      );
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.text(kMapTileAttribution));
      await tester.pumpAndSettle();
      expect(calls.single.arguments['url'], kMapTileLicenseUrl);
      if (result == 'success') {
        expect(find.byType(AlertDialog), findsNothing);
      } else {
        expect(find.text('Giấy phép bản đồ'), findsOneWidget);
        expect(find.textContaining(kMapTileLicenseUrl), findsOneWidget);
        await tester.tap(find.text('Đóng'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
