import 'dart:io';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home/home_page_parts.dart';
import 'package:sky_weather_app/screens/locations/locations_rows.dart';
import 'package:sky_weather_app/screens/locations_screen.dart';
import 'package:sky_weather_app/screens/map/map_legend.dart';
import 'package:sky_weather_app/screens/settings/settings_choice_group.dart';
import 'package:sky_weather_app/screens/settings/settings_common.dart';
import 'package:sky_weather_app/screens/settings/settings_preferences.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  WeatherProvider? weather,
  PreferencesProvider? preferences,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>(
          create: (_) =>
              weather ?? WeatherProvider(initialSettings: const AppSettings()),
        ),
        ChangeNotifierProvider<PreferencesProvider>(
          create: (_) => preferences ?? PreferencesProvider(),
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: AppSceneScope(child: child!),
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void _activate(WidgetTester tester, Finder finder) {
  final node = tester.getSemantics(finder);
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  tester
      .element(finder)
      .findRenderObject()!
      .owner!
      .semanticsOwner!
      .performAction(node.id, SemanticsAction.tap);
}

void _testWithSemantics(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
    }
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('shared widget layers do not import screens', () {
    final offenders = <String>[];
    for (final dir in ['lib/widgets', 'lib/ui']) {
      for (final f in Directory(dir).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.startsWith('import ') && l.contains('screens/')) {
            offenders.add('${f.path}:${i + 1}');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: 'Pass a callback from the screen');
  });

  _testWithSemantics('extracted city title keeps its label and semantic tap', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      SizedBox(
        width: 200,
        child: HomeCityTitle(city: 'Test city', onTap: () => taps++),
      ),
    );
    _activate(tester, find.bySemanticsLabel('Chọn địa điểm: Test city'));
    expect(taps, 1);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  _testWithSemantics('map pin semantic tap uses the same callback as touch', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      SizedBox.square(
        dimension: 48,
        child: MapPlacePin(
          name: 'Test place',
          current: true,
          focused: true,
          onTap: () => taps++,
        ),
      ),
    );
    _activate(
      tester,
      find.bySemanticsLabel('Vị trí hiện tại: Test place, đang xem'),
    );
    expect(taps, 1);
    await tester.tap(find.byType(MapPlacePin));
    expect(taps, 2);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  _testWithSemantics(
    'location compare checkbox keeps an actionable semantic label',
    (tester) async {
      var taps = 0;
      await _pump(
        tester,
        LocationsSavedRow(
          index: 0,
          count: 1,
          place: Place.fallback,
          saved: const SavedPlace(locationId: Place.defaultId),
          cell: null,
          viewing: false,
          compareMode: true,
          picked: false,
          onTap: () => taps++,
          onLabel: () {},
          onMove: (_) {},
          onRemove: () {},
        ),
      );
      _activate(
        tester,
        find.bySemanticsLabel('Chọn ${Place.fallback.name} để so sánh'),
      );
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _testWithSemantics('disabled settings actions expose their enabled state', (
    tester,
  ) async {
    await _pump(
      tester,
      const SettingsAction(
        icon: Icons.restore,
        label: 'Khôi phục mặc định',
        onPressed: null,
      ),
    );
    final flags = tester
        .getSemantics(find.bySemanticsLabel('Khôi phục mặc định'))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isButton, isTrue);
    expect(flags.isEnabled, Tristate.isFalse);
  });

  _testWithSemantics(
    'selected settings and location summary react to unit changes',
    (tester) async {
      final preferences = PreferencesProvider();
      await _pump(
        tester,
        // Co PreferencesProvider -> hien du cac don vi: cuon de khong tran.
        const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlaceWeatherSummary(
                cell: MapCell(
                  cellId: 'test',
                  lat: 10.77,
                  lon: 106.7,
                  locationIds: [],
                  temperature: 30,
                  weatherCode: 3,
                ),
              ),
              SettingsUnitsSection(),
            ],
          ),
        ),
        preferences: preferences,
      );
      expect(find.text('30°'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('30°C')), findsOneWidget);
      preferences.setTemperatureUnit(false);
      await tester.pump();
      expect(
        tester
            .widget<SettingsChoiceGroup<bool>>(
              find.byType(SettingsChoiceGroup<bool>),
            )
            .selected,
        false,
      );
      expect(find.text('86°'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('86°F')), findsOneWidget);
      _activate(tester, find.bySemanticsLabel('Nhiệt độ: °C'));
      await tester.pump();
      expect(preferences.units.isCelsius, isTrue);
      expect(find.text('30°'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('30°C')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
