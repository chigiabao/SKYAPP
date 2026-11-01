import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/activities_screen.dart';
import 'package:sky_weather_app/screens/alerts_screen.dart';
import 'package:sky_weather_app/screens/compare_screen.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/widgets/daily_forecast_list.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/planner_cards.dart';

final _now = DateTime.utc(2026, 10, 21, 6);
final _replay = DateTime.utc(2026, 10, 7, 6);

WeatherData _data(DateTime at, {bool empty = false, double temperature = 27}) =>
    WeatherData(
      current: CurrentWeather(
        temperature: temperature,
        condition: WeatherCondition.cloudy,
        lastUpdated: at,
      ),
      hourlyForecast: [
        if (!empty)
          for (var i = 0; i < 24; i++)
            HourlyForecast(
              time: at.add(Duration(hours: i)),
              temperature: 27,
              condition: WeatherCondition.cloudy,
              rainProbability: 0,
            ),
      ],
      dailyForecast: const [],
    );

class _Api extends ApiService {
  _Api({this.empty = false, this.hoursAt});
  final bool empty;
  final DateTime? hoursAt;

  @override
  Future<WeatherData> fetchWeatherDataFor(
    String locationId, {
    DateTime? at,
  }) async => _data(hoursAt ?? at ?? _now, empty: empty);
}

/// AI 1/3/6h tra 503 (bundle: ai_forecast null, ai_error co chi tiet).
class _NoAiApi extends ApiService {
  @override
  Future<WeatherData> fetchWeatherDataFor(
    String locationId, {
    DateTime? at,
  }) async {
    final d = _data(at ?? _now);
    return WeatherData(
      current: d.current,
      hourlyForecast: d.hourlyForecast,
      dailyForecast: d.dailyForecast,
      aiError: 'Dự báo AI riêng chưa sẵn sàng: KeyError(temp)',
    );
  }
}

class _CompareProvider extends WeatherProvider {
  _CompareProvider()
    : super(
        initialSettings: AppSettings(replayEnabled: true, replayAt: _replay),
        clock: () => HcmTime.toInstant(_now),
      );

  final calls = <DateTime?>[];
  final pending = <Completer<WeatherResult>>[];

  @override
  Future<WeatherResult> fetchWeatherFor(String id) {
    calls.add(isReplay ? replayAt : null);
    final request = Completer<WeatherResult>();
    pending.add(request);
    return request.future;
  }

  @override
  Future<void> fetchWeatherData() async => notifyListeners();
}

Future<void> _pump(
  WidgetTester tester,
  WeatherProvider wp,
  Widget child, {
  PlannerProvider? planner,
  Size size = const Size(375, 812),
  double textScale = 2,
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>.value(value: wp),
        if (planner != null)
          ChangeNotifierProvider<PlannerProvider>.value(value: planner),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            highContrast: highContrast,
            textScaler: TextScaler.linear(textScale),
          ),
          child: AppSceneScope(child: child!),
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('pinned Home title masks scrolling text on a small phone', (
    tester,
  ) async {
    final wp = WeatherProvider(
      apiService: _Api(),
      clock: () => HcmTime.toInstant(_now),
    );
    final planner = PlannerProvider();
    final locations = LocationProvider(apiService: _Api());
    addTearDown(wp.dispose);
    addTearDown(planner.dispose);
    addTearDown(locations.dispose);
    await wp.fetchWeatherData();
    await _pump(
      tester,
      wp,
      HomeScreen(locations: locations),
      planner: planner,
      size: const Size(320, 667),
      textScale: 1,
    );
    await tester.pumpAndSettle();
    // Nen dac nam tren chinh AppBar (khong phu thuoc flexibleSpace co kich
    // thuoc hay khong) -> noi dung cuon khong ve de len tieu de.
    final header = tester.widget<SliverAppBar>(find.byType(SliverAppBar).first);
    expect(header.backgroundColor!.a, greaterThanOrEqualTo(0.95));
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SliverAppBar).first,
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color!.a, greaterThanOrEqualTo(0.95));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned Home header is fully opaque in high contrast', (
    tester,
  ) async {
    final wp = WeatherProvider(
      apiService: _Api(),
      clock: () => HcmTime.toInstant(_now),
    );
    final locations = LocationProvider(apiService: _Api());
    addTearDown(wp.dispose);
    addTearDown(locations.dispose);
    await wp.fetchWeatherData();
    await _pump(
      tester,
      wp,
      HomeScreen(locations: locations),
      size: const Size(390, 844),
      textScale: 1,
      highContrast: true,
    );
    await tester.pumpAndSettle();
    final header = tester.widget<SliverAppBar>(find.byType(SliverAppBar).first);
    expect(header.backgroundColor!.a, 1.0);
    expect(header.flexibleSpace, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home keeps a visible AI 1–6h state when ai_error is set', (
    tester,
  ) async {
    final wp = WeatherProvider(
      apiService: _NoAiApi(),
      clock: () => HcmTime.toInstant(_now),
    );
    final planner = PlannerProvider();
    final locations = LocationProvider(apiService: _Api());
    addTearDown(wp.dispose);
    addTearDown(planner.dispose);
    addTearDown(locations.dispose);
    await wp.fetchWeatherData();
    await _pump(
      tester,
      wp,
      HomeScreen(locations: locations),
      planner: planner,
      size: const Size(390, 2400),
      textScale: 1,
    );
    await tester.pumpAndSettle();
    expect(find.text('AI 1–6 GIỜ CHƯA SẴN SÀNG'), findsOneWidget);
    expect(find.textContaining('KeyError'), findsNothing);
    expect(find.text('Kiểm chứng AI'), findsNothing);
    await tester.ensureVisible(find.text('Chi tiết dữ liệu'));
    await tester.tap(find.text('Chi tiết dữ liệu'));
    await tester.pumpAndSettle();
    expect(find.text('Kiểm chứng AI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'partial activity rating is honest at 200% text ($brightness)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final wp = WeatherProvider(clock: () => HcmTime.toInstant(_now));
        addTearDown(wp.dispose);
        final window = bestWindows(
          Activity.running,
          _data(_now).hourlyForecast,
          nowHcm: _now,
        ).first;
        await _pump(
          tester,
          wp,
          Scaffold(
            body: ActivityWindowRow(
              activity: Activity.running,
              window: window,
              nowHcm: _now,
            ),
          ),
          brightness: brightness,
        );
        expect(
          find.textContaining('Thiếu dữ liệu: UV, gió giật, AQI'),
          findsOneWidget,
        );
        expect(find.text('Tốt'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('Thiếu dữ liệu')), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  for (final empty in [true, false]) {
    testWidgets(
      'alerts do not reassure with ${empty ? 'empty' : 'expired'} hours',
      (tester) async {
        final wp = WeatherProvider(
          apiService: _Api(
            empty: empty,
            hoursAt: _now.subtract(const Duration(days: 2)),
          ),
          clock: () => HcmTime.toInstant(_now),
        );
        final planner = PlannerProvider();
        final locations = LocationProvider();
        addTearDown(wp.dispose);
        addTearDown(planner.dispose);
        addTearDown(locations.dispose);
        await wp.fetchWeatherData();
        await _pump(
          tester,
          wp,
          AlertsScreen(locations: locations),
          planner: planner,
        );
        await tester.pumpAndSettle();
        expect(find.text('Chưa có dữ liệu.'), findsOneWidget);
        expect(find.textContaining('Không có cảnh báo'), findsNothing);
        expect(find.textContaining('Chưa phát hiện cảnh báo'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('routine status discloses missing metrics', (tester) async {
    final wp = WeatherProvider(
      apiService: _Api(),
      clock: () => HcmTime.toInstant(_now),
    );
    final planner = PlannerProvider();
    final locations = LocationProvider();
    addTearDown(wp.dispose);
    addTearDown(planner.dispose);
    addTearDown(locations.dispose);
    await wp.fetchWeatherData();
    await planner.load();
    planner.addRoutine(
      const ActivityRoutine(
        id: 'review',
        activity: Activity.running,
        placeId: 'tsn',
        hour: 7,
      ),
    );
    await _pump(
      tester,
      wp,
      const ActivitiesScreen(),
      planner: planner,
      size: const Size(375, 3000),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('LỊCH HOẠT ĐỘNG'), 300);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Lần tới: Thiếu dữ liệu (UV, gió giật, AQI)'),
      findsOneWidget,
    );
    expect(find.textContaining('Lần tới: Tốt'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('daily row semantic tap matches touch at $size', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final wp = WeatherProvider(clock: () => HcmTime.toInstant(_now));
      addTearDown(wp.dispose);
      final day = DailyForecast(
        date: _now,
        tempMin: 24,
        tempMax: 30,
        precipitationMm: 0,
        condition: WeatherCondition.cloudy,
      );
      var taps = 0;
      await _pump(
        tester,
        wp,
        Scaffold(
          body: DailyRow(
            day: day,
            isToday: true,
            scaleMin: 24,
            scaleMax: 30,
            onTap: () => taps++,
          ),
        ),
        size: size,
      );
      final finder = find.bySemanticsLabel(RegExp('Hôm nay.*thấp nhất'));
      final node = tester.getSemantics(finder);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(taps, 1);
      await tester.tap(find.byType(DailyRow));
      await tester.pump();
      expect(taps, 2);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('noninteractive daily row exposes no semantic tap', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final wp = WeatherProvider(clock: () => HcmTime.toInstant(_now));
    addTearDown(wp.dispose);
    await _pump(
      tester,
      wp,
      Scaffold(
        body: DailyRow(
          day: DailyForecast(
            date: _now,
            tempMin: 24,
            tempMax: 30,
            precipitationMm: 0,
            condition: WeatherCondition.cloudy,
          ),
          isToday: true,
          scaleMin: 24,
          scaleMax: 30,
        ),
      ),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Hôm nay.*thấp nhất')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    semantics.dispose();
  });

  testWidgets(
    'Compare reloads on replay exit and ignores late replay results',
    (tester) async {
      final wp = _CompareProvider();
      final locations = LocationProvider();
      addTearDown(wp.dispose);
      addTearDown(locations.dispose);
      await _pump(
        tester,
        wp,
        CompareScreen(locations: locations, locationIds: const ['tsn']),
        textScale: 1,
      );
      expect(wp.calls, [_replay]);
      await wp.exitReplay();
      await tester.pump();
      expect(wp.calls, [_replay, null]);
      wp.pending[1].complete(
        WeatherResult(_data(_now, temperature: 31), fromCache: false),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('31°'), findsOneWidget);
      wp.pending[0].complete(
        WeatherResult(_data(_replay, temperature: 19), fromCache: false),
      );
      await tester.pump();
      expect(find.text('31°'), findsOneWidget);
      expect(find.text('19°'), findsNothing);
      await wp.startReplay(_replay.add(const Duration(hours: 1)));
      await tester.pump();
      expect(wp.calls.last, _replay.add(const Duration(hours: 1)));
      expect(find.text('31°'), findsNothing);
      wp.pending.last.complete(
        WeatherResult(_data(_replay, temperature: 21), fromCache: false),
      );
      await tester.pump();
      expect(find.text('21°'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Compare stacks place cards at 200% text without overflow', (
    tester,
  ) async {
    final wp = _CompareProvider();
    final locations = LocationProvider();
    addTearDown(wp.dispose);
    addTearDown(locations.dispose);
    await _pump(
      tester,
      wp,
      CompareScreen(
        locations: locations,
        locationIds: const ['phuong-ben-thanh', 'phuong-thu-duc', 'tsn'],
      ),
    );
    for (final p in wp.pending) {
      p.complete(WeatherResult(_data(_replay), fromCache: false));
    }
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('compare-stacked')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-columns')), findsNothing);
    // Bieu do: nhan truc o 200 % nam tron trong cho trong (khong bi cat) va
    // VoiceOver doc khoang nhiet do that (27°), khong phai mien truc +-1°.
    final chart = find.byType(CompareChart);
    await tester.scrollUntilVisible(
      chart,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final titles = tester
        .widget<LineChart>(
          find.descendant(of: chart, matching: find.byType(LineChart)),
        )
        .data
        .titlesData;
    final left = titles.leftTitles.sideTitles.reservedSize;
    final bottom = titles.bottomTitles.sideTitles.reservedSize;
    expect(left, greaterThan(36));
    expect(bottom, greaterThan(26));
    final labels = find.descendant(
      of: chart,
      matching: find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\d+(°|h)$').hasMatch(w.data ?? ''),
      ),
    );
    expect(labels, findsWidgets);
    for (final e in labels.evaluate()) {
      final size = tester.getSize(find.byWidget(e.widget));
      final isTemp = (e.widget as Text).data!.endsWith('°');
      expect(size.height, lessThanOrEqualTo(bottom), reason: '${e.widget}');
      if (isTemp) expect(size.width, lessThanOrEqualTo(left));
    }
    expect(
      find.descendant(
        of: chart,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label ?? '').contains('từ 27° đến 27°'),
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compare keeps side-by-side columns at 100% text', (
    tester,
  ) async {
    final wp = _CompareProvider();
    final locations = LocationProvider();
    addTearDown(wp.dispose);
    addTearDown(locations.dispose);
    await _pump(
      tester,
      wp,
      CompareScreen(
        locations: locations,
        locationIds: const ['phuong-ben-thanh', 'phuong-thu-duc', 'tsn'],
      ),
      textScale: 1,
    );
    expect(find.byKey(const ValueKey('compare-columns')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
