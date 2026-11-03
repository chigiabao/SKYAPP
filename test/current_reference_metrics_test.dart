import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home/home_details_grid.dart';
import 'package:sky_weather_app/screens/home/home_current_snapshot.dart';
import 'package:sky_weather_app/screens/home/home_header_info.dart';
import 'package:sky_weather_app/ui/weather/widgets/metric_tile.dart';

Map<String, dynamic> payload() => {
  'timestamp': '2026-11-03T14:00:00+07:00',
  'source': 'ai',
  'temperature': 31.2,
  'weather_code': 61,
  'humidity': 67,
  'wind_speed': 11,
  'apparent_temperature': 37.6,
  'visibility': 25000,
  'pressure_msl': 1009.6,
  'uv_index': 0,
  'us_aqi': 0,
  'pm2_5': 0,
  'field_sources': {
    for (final field in [
      'apparent_temperature',
      'visibility',
      'pressure_msl',
      'uv_index',
    ])
      field: {'source': 'open_meteo', 'timestamp': '2026-11-03T13:00:00+07:00'},
    'us_aqi': {
      'source': 'open_meteo_cams',
      'timestamp': '2026-11-03T14:00:00+07:00',
    },
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'current retains AI and parses reference time, zeros and legacy responses',
    () {
      final c = CurrentWeather.fromJson(payload());
      expect(c.source, DataSource.ai);
      expect(c.temperature, 31.2);
      expect(c.usAqi, 0);
      expect(c.uvIndex, 0);
      expect(c.fieldSources['uv_index']!.timestamp.hour, 13);
      expect(c.fieldSources['us_aqi']!.source, 'open_meteo_cams');
      final legacy = payload()..remove('field_sources');
      expect(CurrentWeather.fromJson(legacy).fieldSources, isEmpty);
      final malformed = payload()
        ..['field_sources'] = {
          'uv_index': {'source': 'open_meteo', 'timestamp': 'bad'},
          'pressure_msl': null,
        };
      expect(CurrentWeather.fromJson(malformed).fieldSources, isEmpty);
      final provider = WeatherProvider();
      addTearDown(provider.dispose);
      final header = homeHeaderInfo(
        provider,
        c,
        location: provider.place,
        units: const UnitPrefs(),
      );
      expect(header.sourceLabel, 'AI của nhóm · theo giờ');
      expect(header.highLow ?? '', isNot(contains('Cảm giác')));
    },
  );

  for (final width in [360.0, 1024.0]) {
    testWidgets(
      'reference metrics keep visible and accessible sources at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final provider = WeatherProvider();
        final c = CurrentWeather.fromJson(payload());
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: provider,
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 850),
                  textScaler: const TextScaler.linear(2),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        HomeDetailsGrid(current: c),
                        HomeCurrentSnapshot(current: c, onShowAll: () {}),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        const weather = 'Tham khảo: Open-Meteo · 03/11 13:00';
        const air = 'Tham khảo: Open-Meteo / CAMS · 03/11 14:00';
        expect(find.text(weather), findsNWidgets(5));
        expect(find.textContaining(air), findsOneWidget);
        final tiles = tester.widgetList<MetricTile>(find.byType(MetricTile));
        expect(tiles.singleWhere((t) => t.title == 'Gió').footer, isNull);
        expect(tiles.singleWhere((t) => t.title == 'Chỉ số UV').value, '0');
        final semantics = tester.widgetList<Semantics>(find.byType(Semantics));
        expect(
          semantics.any((s) => (s.properties.label ?? '').contains(air)),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        provider.dispose();
      },
    );
  }
}
