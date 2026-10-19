import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Doc AndroidManifest.xml (ban main = release): quyen can thiet va khong mo
/// http cho moi dia chi.
void main() {
  final main = File('android/app/src/main/AndroidManifest.xml');

  test('main manifest: quyen vi tri + thong bao, khong cleartext', () {
    final s = main.readAsStringSync();
    expect(
      s,
      anyOf(
        contains('android.permission.ACCESS_COARSE_LOCATION'),
        contains('android.permission.ACCESS_FINE_LOCATION'),
      ),
    );
    expect(s, contains('android.permission.POST_NOTIFICATIONS'));
    expect(s, isNot(contains('usesCleartextTraffic')));
  });

  test('release chi cho http toi may host / localhost', () {
    final cfg = File('android/app/src/main/res/xml/network_security_config.xml')
        .readAsStringSync();
    expect(cfg, contains('<base-config cleartextTrafficPermitted="false"'));
    expect(cfg, contains('10.0.2.2'));
  });

  test('secure storage is excluded from backup and device transfer', () {
    final manifest = main.readAsStringSync();
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    for (final file in ['backup_rules', 'data_extraction_rules']) {
      final rules = File('android/app/src/main/res/xml/$file.xml')
          .readAsStringSync();
      for (final storage in [
        'FlutterSecureStorage',
        'FlutterSecureKeyStorage',
      ]) {
        expect(rules, contains('path="$storage.xml"'));
      }
    }
  });

  test(
    'notification drawable is retained for dynamically named plugin resources',
    () {
      expect(
        File('android/app/src/main/res/drawable/ic_stat_weather.xml')
            .existsSync(),
        isTrue,
      );
      expect(
        File('android/app/src/main/res/raw/keep.xml').readAsStringSync(),
        contains('@drawable/ic_stat_weather'),
      );
      expect(
        File('lib/services/notification_service.dart').readAsStringSync(),
        contains('@drawable/ic_stat_weather'),
      );
      expect(
        File('lib/services/trip_location.dart').readAsStringSync(),
        contains("AndroidResource(name: 'ic_stat_weather')"),
      );
    },
  );

  test('release signing never falls back to debug keys', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('rootProject.file("key.properties")'));
    expect(
      gradle,
      contains('signingConfig = signingConfigs.getByName("release")'),
    );
    expect(
      gradle,
      isNot(contains('signingConfig = signingConfigs.getByName("debug")')),
    );
  });
}
