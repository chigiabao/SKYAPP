import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/services/account_service.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ApiConfig.setBaseUrl(null));

  group('ApiConfig.normalizeBaseUrl', () {
    test('nhan http/https, bo / cuoi va khoang trang', () {
      expect(
        ApiConfig.normalizeBaseUrl(' http://192.168.1.10:8000/ '),
        'http://192.168.1.10:8000',
      );
      expect(
        ApiConfig.normalizeBaseUrl('https://abc.trycloudflare.com'),
        'https://abc.trycloudflare.com',
      );
      expect(
        ApiConfig.normalizeBaseUrl('https://host/api'),
        'https://host/api',
      );
    });
    test('tu choi URL sai', () {
      for (final bad in [
        '',
        '192.168.1.10:8000',
        'ftp://host',
        'http://',
        'http://host?x=1',
        'javascript:alert(1)',
      ]) {
        expect(ApiConfig.normalizeBaseUrl(bad), isNull, reason: bad);
      }
    });
  });

  group('URL luc chay', () {
    test('doi URL co hieu luc ngay cho service da tao', () async {
      final api = ApiService();
      final account = AccountService();
      expect(api.baseUrl, ApiConfig.defaultBaseUrl);
      expect(await ApiConfig.setBaseUrl('http://10.1.2.3:8000/'), isTrue);
      expect(ApiConfig.baseUrl, 'http://10.1.2.3:8000');
      expect(api.baseUrl, 'http://10.1.2.3:8000');
      expect(account.baseUrl, 'http://10.1.2.3:8000');
      // URL truyen vao constructor (test) van uu tien.
      expect(ApiService(baseUrl: 'http://test').baseUrl, 'http://test');
    });

    test('luu, doc lai va khoi phuc mac dinh', () async {
      await ApiConfig.setBaseUrl('https://x.trycloudflare.com');
      final p = await SharedPreferences.getInstance();
      expect(p.getString(ApiConfig.baseUrlKey), 'https://x.trycloudflare.com');

      await ApiConfig.setBaseUrl(null);
      expect(ApiConfig.baseUrl, ApiConfig.defaultBaseUrl);
      expect(p.getString(ApiConfig.baseUrlKey), isNull);

      SharedPreferences.setMockInitialValues({
        ApiConfig.baseUrlKey: 'http://192.168.0.5:8000',
      });
      await ApiConfig.loadBaseUrl();
      expect(ApiConfig.baseUrl, 'http://192.168.0.5:8000');
    });

    test(
      'URL sai khong duoc luu; gia tri hong trong bo nho bi bo qua',
      () async {
        expect(await ApiConfig.setBaseUrl('abc'), isFalse);
        expect(ApiConfig.baseUrlOverride, isNull);
        SharedPreferences.setMockInitialValues({ApiConfig.baseUrlKey: 'abc'});
        await ApiConfig.loadBaseUrl();
        expect(ApiConfig.baseUrl, ApiConfig.defaultBaseUrl);
      },
    );
  });

  group('checkServerHealth', () {
    test('may chu tra ve ok', () async {
      Uri? called;
      final h = await checkServerHealth(
        'http://h:8000',
        client: MockClient((r) async {
          called = r.url;
          return http.Response(
            jsonEncode({
              'status': 'healthy',
              'database': 'ok',
              'data_age_hours': 1.25,
            }),
            200,
          );
        }),
      );
      expect(called.toString(), 'http://h:8000/health');
      expect(h.ok, isTrue);
      expect(h.message, contains('healthy'));
      expect(h.message, contains('1.3 giờ'));
    });

    test('loi HTTP / khong phai backend / mat ket noi', () async {
      final e500 = await checkServerHealth(
        'http://h',
        client: MockClient((_) async => http.Response('x', 500)),
      );
      expect(e500.ok, isFalse);
      expect(e500.message, contains('500'));
      final html = await checkServerHealth(
        'http://h',
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(html.ok, isFalse);
      final down = await checkServerHealth(
        'http://h',
        client: MockClient((_) async => throw http.ClientException('x')),
      );
      expect(down.ok, isFalse);
      expect(down.message, contains('Không kết nối được'));
    });
  });

  testWidgets('Cai dat: muc May chu du lieu bao loi URL sai', (tester) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => WeatherProvider(
              apiService: ApiService(baseUrl: 'http://test'),
              initialSettings: const AppSettings(),
            ),
          ),
          ChangeNotifierProvider(create: (_) => PreferencesProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: AppSceneScope(child: child!),
          ),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('NÂNG CAO'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('NÂNG CAO'), findsOneWidget);
    expect(find.text(ApiConfig.defaultBaseUrl), findsOneWidget);

    await tester.enterText(find.byType(TextField), '192.168.1.10');
    await tester.ensureVisible(find.text('Lưu và tải lại'));
    await tester.tap(find.text('Lưu và tải lại'));
    await tester.pump();
    expect(find.textContaining('không hợp lệ'), findsOneWidget);
    expect(ApiConfig.baseUrlOverride, isNull);

    await tester.enterText(find.byType(TextField), 'http://192.168.1.10:8000');
    await tester.tap(find.text('Lưu và tải lại'));
    await tester.pump();
    expect(ApiConfig.baseUrl, 'http://192.168.1.10:8000');
    expect(find.textContaining('Đang dùng địa chỉ tự đặt'), findsOneWidget);

    await tester.tap(find.text('Khôi phục mặc định').last);
    await tester.pump();
    expect(ApiConfig.baseUrlOverride, isNull);
    expect(find.text(ApiConfig.defaultBaseUrl), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
