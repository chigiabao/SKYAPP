import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/design_tokens.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_page.dart';

const _appearance = 'Ch\u1ebf \u0111\u1ed9 giao di\u1ec7n';
const _contrast = 'T\u01b0\u01a1ng ph\u1ea3n cao';
const _back = 'Quay l\u1ea1i';

Future<(WeatherProvider, PreferencesProvider)> _pumpSettings(
  WidgetTester tester, {
  Size size = const Size(430, 932),
  double textScale = 1,
  bool fromHome = false,
  bool systemContrast = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  final weather = WeatherProvider(initialSettings: const AppSettings());
  final preferences = PreferencesProvider();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>(create: (_) => weather),
        ChangeNotifierProvider<PreferencesProvider>(create: (_) => preferences),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
            highContrast: systemContrast,
          ),
          child: AppSceneScope(child: child!),
        ),
        home: fromHome
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                    child: const Text('Settings'),
                  ),
                ),
              )
            : const SettingsScreen(),
      ),
    ),
  );
  await tester.pump();
  return (weather, preferences);
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    250,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 80,
  );
  await tester.ensureVisible(target);
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Future<void> _openCategory(WidgetTester tester, String id) async {
  final tile = find.byKey(ValueKey('settings-category-$id'));
  await _reveal(tester, tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Finder _switchFor(String label) => find.descendant(
  of: find.widgetWithText(ListTile, label),
  matching: find.byType(CupertinoSwitch),
);

/// Ban ghi PreferencesProvider da luu.
Map<String, dynamic> _stored(SharedPreferences p) =>
    jsonDecode(p.getString(PreferencesProvider.prefsKey)!)
        as Map<String, dynamic>;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('display page has no dead light/dark switch', (tester) async {
    // Moi man (ke ca Cai dat, sheet, hop thoai) deu la kinh toi theo canh:
    // nut Sang/Toi khong co tac dung nhin thay -> da bo.
    await _pumpSettings(tester);
    expect(find.byType(CupertinoNavigationBar), findsOneWidget);
    await _openCategory(tester, 'display');
    expect(find.text(_appearance), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CupertinoSlidingSegmentedControl<ThemeMode>,
      ),
      findsNothing,
    );
    expect(
      GlassThemeMarker.isGlass(tester.element(find.text('Nhiệt độ'))),
      isTrue,
    );
  });

  testWidgets('Cupertino switches and unit segments update real preferences', (
    tester,
  ) async {
    final (_, preferences) = await _pumpSettings(tester);
    await _openCategory(tester, 'display');
    final metric = find.byKey(const ValueKey('pref-metric-wind'));
    await _reveal(tester, metric);
    final metricSwitch = find.descendant(
      of: metric,
      matching: find.byType(CupertinoSwitch),
    );
    expect(tester.widget<CupertinoSwitch>(metricSwitch).value, isTrue);
    expect(tester.getSize(metricSwitch).height, greaterThanOrEqualTo(44));
    await tester.tap(metricSwitch);
    await tester.pump();
    expect(preferences.isVisible(HomeMetric.wind), isFalse);

    await tester.tap(find.byTooltip(_back));
    await tester.pumpAndSettle();
    await _openCategory(tester, 'accessibility');
    await _reveal(tester, _switchFor(_contrast));
    await tester.tap(_switchFor(_contrast));
    await tester.pump();
    expect(preferences.highContrast, isTrue);
    expect(tester.widget<CupertinoSwitch>(_switchFor(_contrast)).value, isTrue);

    await tester.tap(find.byTooltip(_back));
    await tester.pumpAndSettle();
    await _openCategory(tester, 'display');
    await _reveal(tester, find.text('\u00b0F'));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CupertinoSlidingSegmentedControl<bool>,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('\u00b0F'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(preferences.units.isCelsius, isFalse);
    expect(
      _stored(await SharedPreferences.getInstance())['units']['temp'],
      'fahrenheit',
    );
  });

  testWidgets('system contrast stays enabled without changing app preference', (
    tester,
  ) async {
    final (_, preferences) = await _pumpSettings(tester, systemContrast: true);
    await _openCategory(tester, 'accessibility');
    await _reveal(tester, _switchFor(_contrast));
    final control = tester.widget<CupertinoSwitch>(_switchFor(_contrast));
    expect(control.value, isTrue);
    expect(control.onChanged, isNull);
    expect(preferences.highContrast, isFalse);
  });

  testWidgets('inset groups stay centered within 640 on wide screens', (
    tester,
  ) async {
    await _pumpSettings(tester, size: const Size(1280, 900));
    final firstGroup = find.byType(Card).first;
    final rect = tester.getRect(firstGroup);
    expect(rect.width, lessThanOrEqualTo(640));
    expect(rect.center.dx, closeTo(640, 1));
    final theme = Theme.of(tester.element(firstGroup));
    expect(theme.cardTheme.elevation, 0);
    expect(theme.cardTheme.margin, EdgeInsets.zero);
    expect(
      (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(Radii.group),
    );
  });

  testWidgets('375 wide at 2x text supports native choices', (tester) async {
    final (_, preferences) = await _pumpSettings(
      tester,
      size: const Size(375, 812),
      textScale: 2,
    );
    const label = 'Cấp Beaufort';
    await _openCategory(tester, 'display');
    await _reveal(tester, find.text(label));
    final choice = find.ancestor(
      of: find.text(label),
      matching: find.byType(CupertinoButton),
    );
    expect(choice, findsOneWidget);
    expect(tester.getSize(choice).height, greaterThanOrEqualTo(48));
    await tester.tap(choice);
    await tester.pump(const Duration(milliseconds: 400));
    expect(preferences.units.wind, WindUnit.beaufort);
    for (var i = 0; i < 35; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(find.textContaining('Sky Weather \u00b7'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('Cupertino back button pops the existing route', (tester) async {
    await _pumpSettings(tester, fromHome: true);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoNavigationBar), findsOneWidget);
    expect(find.byTooltip(_back), findsOneWidget);
    await tester.tap(find.byTooltip(_back));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  });
}
