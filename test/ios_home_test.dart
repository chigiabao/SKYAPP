import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_card.dart';
import 'package:sky_weather_app/utils/theme.dart';

class _Locations extends LocationProvider {
  @override
  Future<void> loadLocal() async {}

  @override
  Future<void> refreshRemote({DateTime? at}) async {}
}

class _OfflineWeather extends WeatherProvider {
  _OfflineWeather() : super(initialSettings: const AppSettings());

  int retries = 0;

  @override
  String get error => 'Máy chủ không phản hồi. Vui lòng thử lại.';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> fetchWeatherData() async {
    retries++;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'shared themes use Cupertino transitions and neutral grouped surfaces',
    () {
      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        expect(theme.cupertinoOverrideTheme?.brightness, theme.brightness);
        expect(theme.cardTheme.elevation, 0);
        expect(theme.splashFactory, NoSplash.splashFactory);
        expect(
          theme.pageTransitionsTheme.builders[TargetPlatform.iOS],
          isA<CupertinoPageTransitionsBuilder>(),
        );
      }
    },
  );

  for (final size in [const Size(320, 667), const Size(390, 844)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('offline iOS layout and retry $size x$scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final weather = _OfflineWeather();
        final locations = _Locations();
        addTearDown(weather.dispose);
        addTearDown(locations.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<WeatherProvider>.value(
            value: weather,
            child: MaterialApp(
              theme: AppTheme.darkTheme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  padding: const EdgeInsets.only(top: 44, bottom: 34),
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: HomeScreen(locations: locations),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final title = find.text('Chưa thể tải thời tiết');
        expect(title, findsOneWidget);
        expect(
          find.ancestor(of: title, matching: find.byType(GlassCard)),
          findsNothing,
        );
        expect(find.text(weather.error), findsOneWidget);
        final retry = find.widgetWithText(CupertinoButton, 'Thử lại');
        await tester.ensureVisible(retry);
        await tester.pump();
        expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
        await tester.tap(retry);
        await tester.pump();
        expect(weather.retries, 1);
        expect(find.text('Máy chủ dữ liệu'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
