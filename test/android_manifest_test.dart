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
    final cfg = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();
    expect(cfg, contains('<base-config cleartextTrafficPermitted="false"'));
    expect(cfg, contains('10.0.2.2'));
  });
}
