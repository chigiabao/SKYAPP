import 'dart:ui' show Tristate;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home/home_page_parts.dart';
import 'package:sky_weather_app/screens/settings/settings_common.dart';
import 'package:sky_weather_app/screens/settings/settings_page.dart';
import 'package:sky_weather_app/screens/settings/settings_preferences.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/glass_ink.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/glass_page.dart';
import 'package:sky_weather_app/ui/weather/widgets/rain_timeline_card.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/ai_unavailable_card.dart';

final _now = DateTime.utc(2026, 11, 2, 12);

class _Weather extends WeatherProvider {
  _Weather({
    this.hours = 24,
    this.withInput = true,
    this.stale = false,
    this.busy = false,
    this.replay = false,
  }) : super(initialSettings: const AppSettings());

  final int hours;
  final bool withInput;
  final bool stale;
  final bool busy;
  final bool replay;
  int refreshes = 0;

  @override
  DateTime get nowHcm => _now;

  @override
  bool get isStale => stale;

  @override
  bool get isLoading => busy;

  @override
  bool get isReplay => replay;

  @override
  CurrentWeather? get currentWeather => withInput
      ? CurrentWeather(
          temperature: 28,
          condition: WeatherCondition.cloudy,
          lastUpdated: stale ? _now.subtract(const Duration(hours: 4)) : _now,
          source: DataSource.observed,
        )
      : null;

  @override
  List<HourlyForecast> get hourlyForecast => [
    for (var i = 0; i < hours; i++)
      HourlyForecast(
        time: _now.add(Duration(hours: i)),
        temperature: 28,
        condition: WeatherCondition.cloudy,
        rainProbability: 0.6,
        precipitationMm: 0.5,
        source: DataSource.ai,
      ),
  ];

  @override
  Future<void> refreshWeatherData() async {
    refreshes++;
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Brightness brightness,
  bool grouped = false,
}) async {
  tester.view.physicalSize = const Size(320, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sceneWeather = _Weather();
  addTearDown(sceneWeather.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.light
          ? AppTheme.lightTheme
          : AppTheme.darkTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
          disableAnimations: true,
          highContrast: true,
        ),
        child: AppScene(
          data: AppSceneData.compute(provider: sceneWeather),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final content = SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            );
            if (grouped) {
              return Theme(
                data: glassThemeFor(
                  AppScene.of(context).theme,
                  Theme.of(context),
                ),
                child: Builder(
                  builder: (context) => Theme(
                    data: SettingsPage.groupedTheme(context),
                    child: content,
                  ),
                ),
              );
            }
            return content;
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

Color _textColor(WidgetTester tester, Finder text) => tester
    .widget<RichText>(
      find.descendant(of: text, matching: find.byType(RichText)),
    )
    .text
    .style!
    .color!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final grouped in [false, true]) {
      testWidgets(
        'system-locked rows remain readable and disabled: $brightness grouped=$grouped',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final prefs = PreferencesProvider();
          addTearDown(prefs.dispose);
          await _pump(
            tester,
            ChangeNotifierProvider<PreferencesProvider>.value(
              value: prefs,
              child: const SettingsAccessibilitySection(),
            ),
            brightness: brightness,
            grouped: grouped,
          );

          for (final label in ['Tương phản cao', 'Giảm chuyển động']) {
            final row = find.widgetWithText(SettingsSwitchTile, label);
            await tester.ensureVisible(row);
            await tester.pump();
            final tileFinder = find.descendant(
              of: row,
              matching: find.byType(ListTile),
            );
            final tile = tester.widget<ListTile>(tileFinder);
            final control = find.descendant(
              of: row,
              matching: find.byType(CupertinoSwitch),
            );
            expect(tile.enabled, isFalse);
            expect(tile.onTap, isNull);
            expect(tester.widget<CupertinoSwitch>(control).onChanged, isNull);
            expect(tester.widget<CupertinoSwitch>(control).value, isTrue);
            final data = tester.getSemantics(control).getSemanticsData();
            expect(data.flagsCollection.isEnabled, Tristate.isFalse);
            expect(data.flagsCollection.isToggled, Tristate.isTrue);
            expect(data.hasAction(SemanticsAction.tap), isFalse);
            expect(tester.getSize(control).height, greaterThanOrEqualTo(44));

            final title = find.descendant(of: row, matching: find.text(label));
            final note = find.descendant(
              of: row,
              matching: find.text('Đang bật theo hệ thống'),
            );
            final theme = Theme.of(tester.element(tileFinder));
            for (final text in [title, note]) {
              final color = _textColor(tester, text);
              final contrast = grouped
                  ? GlassInk.worstContrast(
                      color,
                      GlassInk.cardBackdrops(
                        AppScene.of(tester.element(row)).theme,
                      ),
                    )
                  : SceneTheme.contrastRatio(
                      color,
                      theme.cardTheme.color ?? theme.colorScheme.surface,
                    );
              expect(contrast, greaterThanOrEqualTo(4.5));
            }
            await tester.tap(title);
            await tester.pump();
            expect(prefs.highContrast, isFalse);
            expect(prefs.reduceMotion, isFalse);
            expect(tester.takeException(), isNull);
          }
          semantics.dispose();
        },
      );
    }

    testWidgets(
      'AI details preserve truth and actions at 320px/200%: $brightness',
      (tester) async {
        final weather = _Weather(stale: true);
        addTearDown(weather.dispose);
        var verifies = 0;
        await _pump(
          tester,
          ChangeNotifierProvider<WeatherProvider>.value(
            value: weather,
            child: AIUnavailableCard(
              detail: 'Chưa có dữ liệu đầu vào mới',
              onVerify: () => verifies++,
            ),
          ),
          brightness: brightness,
        );
        expect(
          find.text('Chờ dữ liệu đầu vào mới để chạy AI.'),
          findsOneWidget,
        );
        expect(find.text('Kiểm chứng AI'), findsNothing);
        expect(find.text('Xem mốc mẫu đã lưu'), findsNothing);
        expect(
          find.byWidgetPredicate((widget) => widget is TextButton),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Thử lại'));
        await tester.tap(find.text('Thử lại'));
        expect(weather.refreshes, 1);
        await tester.ensureVisible(find.text('Chi tiết dữ liệu'));
        await tester.tap(find.text('Chi tiết dữ liệu'));
        await tester.pump();
        expect(
          tester
              .widget<ExpansionTile>(find.byType(ExpansionTile))
              .expansionAnimationStyle,
          AnimationStyle.noAnimation,
        );
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
        for (final text in [
          'Dữ liệu đầu vào mới nhất:',
          'Nguồn đầu vào:',
          'Dữ liệu đầu vào đã cũ.',
          'không thay bằng số',
        ]) {
          expect(find.textContaining(text), findsOneWidget);
        }
        await tester.ensureVisible(find.text('Kiểm chứng AI'));
        await tester.tap(find.text('Kiểm chứng AI'));
        expect(verifies, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Home UV summary uses the alert metric, not rain: $brightness',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final weather = _Weather();
        addTearDown(weather.dispose);
        final uv = AlertEvent(
          type: AlertType.uv,
          level: AlertLevel.warning,
          placeId: 'tsn',
          start: _now,
          end: _now.add(const Duration(hours: 2)),
          peak: 9.5,
          observed: false,
          asOf: _now,
        );
        var opens = 0;
        String? dismissed;
        await _pump(
          tester,
          Builder(
            builder: (context) => homeRainCard(
              context,
              weather,
              [uv],
              null,
              dismissedAlertKey: null,
              dismissedAlert: null,
              onOpenAlerts: () => opens++,
              onDismissAlertKey: (key) => dismissed = key,
              onDismissAlert: (_) {},
            )!,
          ),
          brightness: brightness,
        );
        final card = tester.widget<RainTimelineCard>(
          find.byType(RainTimelineCard),
        );
        expect(card.alertDetail, uv.detail);
        expect(find.text(uv.detail), findsOneWidget);
        expect(find.text('Dữ liệu mưa theo giờ'), findsOneWidget);
        expect(find.textContaining('Xác suất mưa tới 60%'), findsOneWidget);
        expect(find.textContaining('tổng 12,0 mm'), findsOneWidget);
        expect(card.alertDetail, isNot(contains('%')));
        expect(card.alertDetail, isNot(contains('mm')));
        expect(
          tester.getTopLeft(find.text(uv.detail)).dy,
          lessThan(tester.getTopLeft(find.text('Dữ liệu mưa theo giờ')).dy),
        );
        expect(
          find.bySemanticsLabel(RegExp('Chỉ số UV tới.*Xác suất mưa tới 60%')),
          findsOneWidget,
        );
        await tester.tap(find.text(card.title));
        expect(opens, 1);
        await tester.ensureVisible(find.byTooltip('Đóng cảnh báo'));
        await tester.tap(find.byTooltip('Đóng cảnh báo'));
        expect(dismissed, uv.key);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  testWidgets(
    'AI missing input and replay remain explicit while retry is busy',
    (tester) async {
      final weather = _Weather(withInput: false, busy: true, replay: true);
      addTearDown(weather.dispose);
      await _pump(
        tester,
        ChangeNotifierProvider<WeatherProvider>.value(
          value: weather,
          child: AIUnavailableCard(detail: null, onVerify: () {}),
        ),
        brightness: Brightness.dark,
      );
      final retry = find.ancestor(
        of: find.text('Đang thử lại'),
        matching: find.byWidgetPredicate((widget) => widget is TextButton),
      );
      expect(tester.widget<TextButton>(retry).onPressed, isNull);
      await tester.ensureVisible(find.text('Chi tiết dữ liệu'));
      await tester.tap(find.text('Chi tiết dữ liệu'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Chưa có mốc dữ liệu đầu vào.'),
        findsOneWidget,
      );
      expect(find.textContaining('không phải dự báo live'), findsOneWidget);
      expect(find.text('Xem mốc mẫu đã lưu'), findsNothing);
      expect(find.textContaining('Nguồn đầu vào:'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UV alert survives missing hourly rain without fake percentages',
    (tester) async {
      final weather = _Weather(hours: 0);
      addTearDown(weather.dispose);
      final uv = AlertEvent(
        type: AlertType.uv,
        level: AlertLevel.warning,
        placeId: 'tsn',
        start: _now,
        end: _now.add(const Duration(hours: 2)),
        peak: 9,
        observed: false,
      );
      await _pump(
        tester,
        Builder(
          builder: (context) => homeRainCard(
            context,
            weather,
            [uv],
            null,
            dismissedAlertKey: null,
            dismissedAlert: null,
            onOpenAlerts: () {},
            onDismissAlertKey: (_) {},
            onDismissAlert: (_) {},
          )!,
        ),
        brightness: Brightness.dark,
      );
      expect(find.text(uv.detail), findsOneWidget);
      expect(find.text('Chưa có dữ liệu mưa theo giờ.'), findsOneWidget);
      expect(find.textContaining('0%'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
