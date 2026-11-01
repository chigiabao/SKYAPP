import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/settings/settings_notify.dart';
import 'package:sky_weather_app/screens/settings/settings_places.dart';
import 'package:sky_weather_app/screens/settings/settings_preferences.dart';
import 'package:sky_weather_app/screens/settings/settings_server.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_page.dart';

const _categories = [
  'display',
  'notifications',
  'places',
  'accessibility',
  'advanced',
  'help',
];

// Exercise real replay state and persistence without making network requests.
class _SettingsWeather extends WeatherProvider {
  _SettingsWeather() : super(initialSettings: const AppSettings());

  @override
  Future<void> fetchWeatherData() async {
    notifyListeners();
  }
}

Future<(_SettingsWeather, PreferencesProvider)> _pumpSettings(
  WidgetTester tester, {
  Size size = const Size(430, 932),
  double textScale = 1,
  bool fromHome = false,
  bool systemContrast = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final weather = _SettingsWeather();
  final preferences = PreferencesProvider();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    weather.dispose();
    preferences.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: weather),
        ChangeNotifierProvider<PreferencesProvider>.value(value: preferences),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: false,
            highContrast: systemContrast,
          ),
          child: child!,
        ),
        home: fromHome
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
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
  await tester.pumpAndSettle();
  return (weather, preferences);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    220,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 50,
  );
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(tester.takeException(), isNull);
}

Future<void> _open(WidgetTester tester, String category) async {
  final tile = find.byKey(ValueKey('settings-category-$category'));
  await _reveal(tester, tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
  expect(find.byTooltip('Quay lại'), findsOneWidget);
  expect(tester.takeException(), isNull);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Quay lại'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Finder _switchFor(String title) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byType(CupertinoSwitch),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'overview is compact and detail pages reuse every settings section',
    (tester) async {
      await _pumpSettings(tester);
      expect(find.byType(ListTile), findsNWidgets(7));
      // Tieu de lon iOS (thu lai khi cuon), khong co nut quay lai o goc.
      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
      expect(find.byType(SettingsServerSection), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Quay lại'), findsNothing);
      expect(find.text('Đồng bộ tùy chọn, không bắt buộc'), findsOneWidget);

      final sections = <String, List<Type>>{
        'display': [SettingsHomeMetricsSection, SettingsUnitsSection],
        'notifications': [SettingsNotifySection],
        'places': [SettingsPlacesSection, SettingsActivitySection],
        'accessibility': [SettingsAccessibilitySection],
        'advanced': [SettingsServerSection, SettingsReplaySection],
      };
      for (final entry in sections.entries) {
        await _open(tester, entry.key);
        for (final section in entry.value) {
          await _reveal(tester, find.byType(section));
          expect(find.byType(section), findsOneWidget);
        }
        await _back(tester);
        expect(
          find.byKey(ValueKey('settings-category-${entry.key}')),
          findsOneWidget,
        );
      }
      await _open(tester, 'help');
      expect(find.text('Phản hồi và báo lỗi'), findsOneWidget);
      expect(find.text('Xem lại hướng dẫn'), findsOneWidget);
      await _reveal(tester, find.text('Phiên bản'));
      await _reveal(tester, find.textContaining('10 năm số liệu theo giờ'));
      expect(
        find.textContaining('Mọi giá trị dự báo (theo giờ, 7 ngày'),
        findsOneWidget,
      );
      expect(find.textContaining('không phải trạm đo'), findsOneWidget);
    },
  );

  testWidgets('detail choices persist and themes remain live after back', (
    tester,
  ) async {
    final (_, preferences) = await _pumpSettings(tester);
    await _open(tester, 'display');
    expect(find.text('Chế độ giao diện'), findsNothing);
    await _reveal(tester, find.text('°F'));
    await tester.tap(find.text('°F'));
    await tester.pumpAndSettle();
    expect(preferences.units.isCelsius, isFalse);
    final stored = await SharedPreferences.getInstance();
    final saved = jsonDecode(stored.getString(PreferencesProvider.prefsKey)!);
    expect(saved['units']['temp'], 'fahrenheit');
    await _back(tester);
    expect(
      Theme.of(tester.element(find.byType(Card).first)).brightness,
      Brightness.dark,
    );
    await _open(tester, 'display');
    await _reveal(tester, find.text('°F'));
    expect(preferences.units.isCelsius, isFalse);
  });

  testWidgets('home metrics and accessibility still update their providers', (
    tester,
  ) async {
    final (_, preferences) = await _pumpSettings(tester);
    await _open(tester, 'display');
    final metric = find.byKey(const ValueKey('pref-metric-wind'));
    await _reveal(tester, metric);
    await tester.tap(
      find.descendant(of: metric, matching: find.byType(CupertinoSwitch)),
    );
    await tester.pumpAndSettle();
    expect(preferences.isVisible(HomeMetric.wind), isFalse);
    await _back(tester);
    await _open(tester, 'accessibility');
    await tester.tap(_switchFor('Tương phản cao'));
    await tester.pumpAndSettle();
    expect(preferences.highContrast, isTrue);
    await tester.tap(_switchFor('Giảm chuyển động'));
    await tester.pumpAndSettle();
    expect(preferences.reduceMotion, isTrue);
    await _back(tester);
    await _open(tester, 'accessibility');
    expect(
      tester.widget<CupertinoSwitch>(_switchFor('Tương phản cao')).value,
      isTrue,
    );
  });

  testWidgets('system contrast remains enabled in accessibility detail', (
    tester,
  ) async {
    final (_, preferences) = await _pumpSettings(tester, systemContrast: true);
    await _open(tester, 'accessibility');
    final control = tester.widget<CupertinoSwitch>(
      _switchFor('Tương phản cao'),
    );
    expect(control.value, isTrue);
    expect(control.onChanged, isNull);
    expect(preferences.highContrast, isFalse);
  });

  testWidgets(
    'replay state stays visible on overview and survives navigation',
    (tester) async {
      final (weather, _) = await _pumpSettings(tester);
      await _open(tester, 'advanced');
      final replaySwitch = _switchFor('Chế độ xem lại');
      await _reveal(tester, replaySwitch);
      await tester.tap(replaySwitch);
      await tester.pumpAndSettle();
      expect(weather.isReplay, isTrue);
      final at = weather.replayAt;
      await _back(tester);
      expect(find.textContaining('Đang xem lại:'), findsOneWidget);
      expect(weather.replayAt, at);
      await _open(tester, 'advanced');
      await _reveal(tester, replaySwitch);
      expect(tester.widget<CupertinoSwitch>(replaySwitch).value, isTrue);
      await tester.tap(replaySwitch);
      await tester.pumpAndSettle();
      expect(weather.isReplay, isFalse);
      await _back(tester);
      expect(find.textContaining('Đang xem lại:'), findsNothing);
      expect(find.text('Máy chủ dữ liệu, chế độ xem lại'), findsOneWidget);
    },
  );

  testWidgets('detail back returns to settings before popping the home route', (
    tester,
  ) async {
    await _pumpSettings(tester, fromHome: true);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _open(tester, 'accessibility');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-category-display')),
      findsOneWidget,
    );
    expect(find.byType(SettingsAccessibilitySection), findsNothing);
    await _back(tester);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('overview and details keep the centered 640 wide native groups', (
    tester,
  ) async {
    await _pumpSettings(tester, size: const Size(1280, 900));
    for (final category in [
      'overview',
      'display',
      'accessibility',
      'advanced',
    ]) {
      if (category != 'overview') await _open(tester, category);
      final card = find.byType(Card).first;
      final rect = tester.getRect(card);
      expect(rect.width, lessThanOrEqualTo(640));
      expect(rect.center.dx, closeTo(640, 1));
      final theme = Theme.of(tester.element(card));
      expect(theme.cardTheme.elevation, 0);
      expect(theme.cardTheme.margin, EdgeInsets.zero);
      expect(theme.extension<GlassThemeMarker>(), isNotNull);
      if (category != 'overview') await _back(tester);
    }
  });

  testWidgets('category actions stay labeled and preserve overview scroll', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    // Thap hon tong danh sach (van phai cuon) nhung khong de hang bi cat
    // sat duoi thanh tab (rect bi cat khong o mep man hinh -> guideline bao).
    await _pumpSettings(tester, size: const Size(375, 520));
    for (final category in _categories) {
      final tile = find.byKey(ValueKey('settings-category-$category'));
      await _reveal(tester, tile);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    }
    final scrollable = find.byType(Scrollable).first;
    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('settings-category-help')));
    await tester.pumpAndSettle();
    await _back(tester);
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      closeTo(offset, 1),
    );
    semantics.dispose();
  });

  testWidgets('320 wide at 2x text keeps every category accessible', (
    tester,
  ) async {
    await _pumpSettings(tester, size: const Size(320, 667), textScale: 2);
    for (final category in _categories) {
      final tile = find.byKey(ValueKey('settings-category-$category'));
      await _reveal(tester, tile);
      expect(tester.getSize(tile).height, greaterThanOrEqualTo(44));
      await _open(tester, category);
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -350));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await _back(tester);
    }
    final account = find.byKey(const ValueKey('settings-account'));
    await _reveal(tester, account);
    expect(tester.getSize(account).height, greaterThanOrEqualTo(44));
  });
}
