import 'dart:math' as math;

// Kiem tra truy cap (a11y) cho 4 man hinh chinh: vung cham Android / iOS,
// nhan cho moi vung cham, tuong phan chu (chi noi nen la mau phang) va co
// chu 2.0 khong tran o Home.
//
// textContrastGuideline doc mau tu anh chup thuc te. Home va Ban do ve chu
// tren nen canh thoi tiet (gradient + hieu ung) va o mau / ban do nen, nen
// do tuong phan o do khong do duoc on dinh bang guideline nay; hai man do
// da co test tuong phan rieng (glass_contrast_test, labelInkFor). Dia diem
// cung dung nen kinh, nen chi ap dung textContrastGuideline o Cai dat.
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home_screen.dart';
import 'package:sky_weather_app/screens/locations_screen.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/screens/settings_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

import 'support/fake_weather_repository.dart';

import 'package:sky_weather_app/ui/weather/widgets/ios_list.dart';

final _now = DateTime.utc(2026, 10, 22, 12);

/// Du lieu gia CHI dung trong test (khong goi mang).
WeatherData _fakeWeather(DateTime now, DateTime? at) {
  final base = HcmTime.startOfHour(at ?? now);
  return WeatherData(
    current: CurrentWeather(
      temperature: 29,
      feelsLike: 33,
      condition: WeatherCondition.cloudy,
      lastUpdated: base,
      humidity: 80,
      windSpeed: 12,
      windDirection: 135,
      cloudCover: 70,
      precipitationMm: 0.2,
      pressure: 1010,
      visibilityKm: 12,
    ),
    hourlyForecast: [
      for (var i = 0; i < 12; i++)
        HourlyForecast(
          time: base.add(Duration(hours: i)),
          temperature: 28,
          condition: WeatherCondition.rainy,
          rainProbability: 0.6,
        ),
    ],
    dailyForecast: [
      for (var i = 0; i < 7; i++)
        DailyForecast(
          date: base.add(Duration(days: i)),
          tempMin: 25,
          tempMax: 32,
          condition: WeatherCondition.showers,
          precipitationMm: 4,
        ),
    ],
  );
}

/// API gia cho danh sach dia diem / ban do: mot dia diem, mot o du lieu.
ApiService _mapApi() => ApiService(
  baseUrl: 'http://test',
  client: MockClient((req) async {
    if (req.url.path == '/locations') {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode([
            {
              'id': 'tsn',
              'name': 'Tân Sơn Nhất',
              'kind': 'special',
              'lat': 10.77,
              'lon': 106.70,
            },
          ]),
        ),
        200,
      );
    }
    if (req.url.path == '/weather/map') {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode([
            {
              'cell_id': 'c1',
              'lat': 10.77,
              'lon': 106.70,
              'location_ids': ['tsn'],
              'temperature': 30.0,
              'weather_code': 3,
              'rain_probability_next_3h': 0.4,
              'alert': false,
              'wind_speed': 21.1,
              'wind_direction': 90.0,
              'source': 'observed',
              'valid_time': HcmTime.toIso(_now),
              'max_offset_hours': 72,
            },
          ]),
        ),
        200,
      );
    }
    return http.Response('{"detail":"Not Found"}', 404);
  }),
);

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  double textScale = 1,
  ThemeData? theme,
  WeatherProvider? weather,
  LocationProvider? locations,
  PreferencesProvider? preferences,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  final wp =
      weather ??
      WeatherProvider(
        apiService: FakeWeatherRepository.fixed((at) => _fakeWeather(_now, at)),
        initialSettings: const AppSettings(),
        clock: () => HcmTime.toInstant(_now),
      );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<WeatherProvider>(create: (_) => wp),
        if (locations != null)
          ChangeNotifierProvider<LocationProvider>(create: (_) => locations),
        ChangeNotifierProvider<PreferencesProvider>(
          create: (_) => preferences ?? PreferencesProvider(),
        ),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: AppSceneScope(child: child!),
        ),
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _expectTapTargets(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  expect(tester.takeException(), isNull);
}

Finder get _verticalScroll => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _revealHomeMode(WidgetTester tester) async {
  tester.state<ScrollableState>(_verticalScroll).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(
    find.text('Điều kiện'),
    200,
    scrollable: _verticalScroll,
  );
  await Scrollable.ensureVisible(
    tester.element(find.text('Điều kiện')),
    alignment: 0.2,
  );
  await tester.pump();
  expect(find.text('Điều kiện').hitTestable(), findsOneWidget);
}

/// Chu bi mep tren khung cuon cat do (nua tren nam duoi thanh tieu de) lam
/// phep do tuong phan lay nham mau thanh: cuon them cho dong do khuat han.
Future<void> _avoidClippedText(
  WidgetTester tester,
  ScrollPosition position,
) async {
  final scrollable = find.byType(Scrollable).first;
  for (var k = 0; k < 6; k++) {
    final top = tester.getTopLeft(scrollable).dy;
    double? push;
    for (final e
        in find
            .descendant(of: scrollable, matching: find.byType(RichText))
            .evaluate()) {
      final r = e.renderObject;
      if (r is! RenderBox || !r.attached || !r.hasSize) continue;
      final y = r.localToGlobal(Offset.zero).dy;
      if (y < top && y + r.size.height > top) {
        push = math.max(push ?? 0, y + r.size.height - top + 1);
      }
    }
    if (push == null || position.pixels >= position.maxScrollExtent) return;
    position.jumpTo(
      (position.pixels + push).clamp(0.0, position.maxScrollExtent).toDouble(),
    );
    await tester.pump();
  }
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

  _testWithSemantics('Home: vung cham >= 48/44 dp va co nhan', (tester) async {
    final lp = LocationProvider(apiService: _mapApi());
    await _pump(tester, HomeScreen(locations: lp), locations: lp);
    expect(find.text('Dự báo'), findsOneWidget);
    await _expectTapTargets(tester);
    await _revealHomeMode(tester);
    await _expectTapTargets(tester);
    await tester.tap(find.text('Điều kiện'));
    await tester.pump();
    await _expectTapTargets(tester);
  });

  for (final dark in [false, true]) {
    _testWithSemantics(
      'Home: co chu 2.0 khong tran (${dark ? 'toi' : 'sang'})',
      (tester) async {
        final lp = LocationProvider(apiService: _mapApi());
        await _pump(
          tester,
          HomeScreen(locations: lp),
          locations: lp,
          textScale: 2,
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        );
        for (final details in [false, true]) {
          await _revealHomeMode(tester);
          await tester.tap(find.text(details ? 'Điều kiện' : 'Dự báo'));
          await tester.pump();
          expect(
            tester
                .widget<CupertinoSlidingSegmentedControl<bool>>(
                  find.byType(CupertinoSlidingSegmentedControl<bool>),
                )
                .groupValue,
            details,
          );
          final position = tester
              .state<ScrollableState>(_verticalScroll)
              .position;
          for (var i = 0; i < 40; i++) {
            expect(tester.takeException(), isNull);
            if (position.pixels >= position.maxScrollExtent) break;
            position.jumpTo(
              (position.pixels + 400)
                  .clamp(0.0, position.maxScrollExtent)
                  .toDouble(),
            );
            await tester.pump();
          }
          expect(position.pixels, position.maxScrollExtent);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final dark in [false, true]) {
    _testWithSemantics('Cai dat (${dark ? 'toi' : 'sang'}): vung cham, nhan, '
        'tuong phan chu', (tester) async {
      await _pump(
        tester,
        const SettingsScreen(),
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      );
      expect(find.text('Cài đặt'), findsOneWidget);
      for (final category in [
        'overview',
        'display',
        'notifications',
        'places',
        'accessibility',
        'advanced',
        'help',
      ]) {
        if (category != 'overview') {
          final tile = find.byKey(ValueKey('settings-category-$category'));
          await tester.scrollUntilVisible(
            tile,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          await tester.tap(tile);
          await tester.pumpAndSettle();
        }
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        for (var i = 0; i < 50; i++) {
          await _expectTapTargets(tester);
          // Nen nhom iOS la mau phang -> do duoc tuong phan chu.
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          if (position.pixels >= position.maxScrollExtent) break;
          position.jumpTo(
            (position.pixels + 500)
                .clamp(0.0, position.maxScrollExtent)
                .toDouble(),
          );
          // Tieu de nho iOS hien dan (~150 ms) khi tieu de lon thu lai: do
          // tuong phan sau khi hien xong.
          await tester.pump(const Duration(milliseconds: 300));
          await _avoidClippedText(tester, position);
        }
        // Lazy slivers can revise the estimated extent after the last jump.
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        await _expectTapTargets(tester);
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        expect(position.pixels, position.maxScrollExtent);
        if (category != 'overview') {
          await tester.tap(find.byTooltip('Quay lại'));
          await tester.pumpAndSettle();
        }
      }
    });
  }

  _testWithSemantics('Ban do: vung cham va nhan', (tester) async {
    final lp = LocationProvider(apiService: _mapApi());
    await _pump(
      tester,
      MapScreen(locations: lp, showTiles: false),
      locations: lp,
    );
    expect(find.text('Bản đồ'), findsOneWidget);
    await _expectTapTargets(tester);
    await tester.tap(find.byTooltip('Xem dạng danh sách'));
    await tester.pumpAndSettle();
    expect(find.byType(IosListRow), findsOneWidget);
    await _expectTapTargets(tester);
    await tester.tap(find.byType(IosListRow));
    await tester.pumpAndSettle();
    expect(find.text('CÁC PHƯỜNG, XÃ TRONG Ô'), findsOneWidget);
    await _expectTapTargets(tester);
  });

  _testWithSemantics('Dia diem: vung cham va nhan', (tester) async {
    final lp = LocationProvider(apiService: _mapApi());
    await _pump(tester, LocationsScreen(locations: lp), locations: lp);
    expect(find.text('Địa điểm'), findsOneWidget);
    await _expectTapTargets(tester);
    await tester.enterText(find.byType(TextField), 'tan son');
    await tester.pump(const Duration(milliseconds: 400));
    await _expectTapTargets(tester);
    await tester.tap(find.byTooltip('Xóa tìm kiếm'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(tester.takeException(), isNull);
  });
}
