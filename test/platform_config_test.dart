import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/services/background_check.dart';
import 'package:sky_weather_app/services/gps_service.dart';

/// Cau hinh iOS / web khong build duoc tren Windows: doc file de bat loi
/// lech id / thieu khoa.
void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  test('Info.plist: ten, quyen vi tri, che do nen', () {
    expect(plist, contains('<string>Sky Weather</string>'));
    expect(plist, contains('NSLocationWhenInUseUsageDescription'));
    expect(plist, contains('NSLocationAlwaysAndWhenInUseUsageDescription'));
    expect(plist, contains('<string>fetch</string>'));
    expect(plist, contains('<string>location</string>'));
    expect(plist, isNot(contains('<string>processing</string>')));
    expect(plist, contains('NSAllowsLocalNetworking'));
    expect(plist, isNot(contains('NSAllowsArbitraryLoads')));
  });

  test('id tac vu nen trung Dart / Info.plist / AppDelegate', () {
    expect(plist, contains('<string>$kBackgroundTask</string>'));
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(delegate, contains('"$kBackgroundTask"'));
  });

  test('bundle id iOS = applicationId Android', () {
    final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = com.skyweather.app;'));
    expect(pbx, isNot(contains('com.example')));
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('applicationId = "com.skyweather.app"'));
  });

  test(
    'iOS registers background plugins before an implicit UI engine is needed',
    () {
      final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final engine = delegate.indexOf(
        'func didInitializeImplicitFlutterEngine',
      );
      for (final plugin in [
        'FlutterLocalNotificationsPlugin',
        'WorkmanagerPlugin',
      ]) {
        final callback = delegate.indexOf(
          '$plugin.setPluginRegistrantCallback',
        );
        expect(callback, greaterThanOrEqualTo(0));
        expect(callback, lessThan(engine));
      }
    },
  );

  test('web: GPS chi o https / localhost', () {
    bool ok(String u) => GeolocatorGps.isWebContextAllowed(Uri.parse(u));
    expect(ok('http://localhost:5000/'), isTrue);
    expect(ok('http://127.0.0.1:8080/'), isTrue);
    expect(ok('https://abc.trycloudflare.com/'), isTrue);
    expect(ok('http://192.168.1.10:8080/'), isFalse);
  });
}
