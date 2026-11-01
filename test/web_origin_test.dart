@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/services/account_service.dart';
import 'package:sky_weather_app/services/api_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ApiConfig.setBaseUrl(null));

  test('malformed saved URL does not block the new default', () async {
    SharedPreferences.setMockInitialValues({
      ApiConfig.baseUrlKey: 'http://localhost:99999',
    });
    await ApiConfig.loadBaseUrl();
    expect(ApiConfig.baseUrl, Uri.base.origin);
  });

  test('migration preserves an existing intentional custom backend', () async {
    SharedPreferences.setMockInitialValues({
      ApiConfig.baseUrlKey: 'https://custom.example/api',
    });
    await ApiConfig.loadBaseUrl();
    expect(ApiConfig.baseUrl, 'https://custom.example/api');
  });

  test(
    'fresh web install uses the page origin for weather and accounts',
    () async {
      await ApiConfig.loadBaseUrl();
      expect(ApiConfig.defaultBaseUrl, Uri.base.origin);
      expect(ApiService().baseUrl, Uri.base.origin);
      expect(AccountService().baseUrl, Uri.base.origin);
    },
  );

  test(
    'legacy preview override migrates once without losing other settings',
    () async {
      SharedPreferences.setMockInitialValues({
        ApiConfig.baseUrlKey: 'http://localhost:8036',
        'themeMode': 'dark',
      });
      await ApiConfig.loadBaseUrl();
      expect(ApiConfig.baseUrlOverride, isNull);
      expect(ApiConfig.baseUrl, Uri.base.origin);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('themeMode'), 'dark');
      expect(prefs.containsKey(ApiConfig.baseUrlKey), isFalse);
      await ApiConfig.setBaseUrl('https://custom.example');
      await ApiConfig.loadBaseUrl();
      expect(ApiConfig.baseUrl, 'https://custom.example');
    },
  );
}
