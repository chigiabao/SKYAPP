import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/main.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';

void main() {
  testWidgets('App khởi động và hiển thị màn hình chính', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SkyWeatherApp());
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('Giao dien app theo he thong (khong con lua chon luu)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'themeMode': 'dark'});
    final prefs = PreferencesProvider();
    await tester.pumpWidget(SkyWeatherApp(preferences: prefs));
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
  });
}
