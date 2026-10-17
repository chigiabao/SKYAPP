import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/main.dart';

void main() {
  testWidgets('App khởi động và hiển thị màn hình chính', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SkyWeatherApp());
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
