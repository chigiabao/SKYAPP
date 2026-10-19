import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/forecast/forecast_format.dart';
import 'package:sky_weather_app/screens/forecast_screen.dart';
import 'package:sky_weather_app/utils/theme.dart';

// Gio co dinh: 10:00 15/10/2026 tai TP.HCM (= 03:00 UTC).
final _realNow = DateTime.utc(2026, 10, 15, 3);
final _nowHcm = HcmTime.now(() => _realNow);

/// Du lieu gia CHI dung trong test.
List<HourlyForecast> _hours() {
  final base = HcmTime.startOfHour(_nowHcm);
  return [
    for (var i = 0; i < 24; i++)
      HourlyForecast(
        time: base.add(Duration(hours: i)),
        temperature: 26 + (i % 8),
        condition: WeatherCondition.showers,
        rainProbability: i == 5 ? null : (i * 4) / 100,
        precipitationMedian: i.isEven ? 0.4 : 0,
      ),
  ];
}

/// 48 gio tu 00:00 hom nay (giong backend moi).
List<HourlyForecast> _hours48() {
  final base = HcmTime.startOfDay(_nowHcm);
  return [
    for (var i = 0; i < 48; i++)
      HourlyForecast(
        time: base.add(Duration(hours: i)),
        temperature: 26,
        condition: WeatherCondition.cloudy,
        rainProbability: 0.2,
        precipitationMm: i == 30 ? 2.5 : 0,
      ),
  ];
}

List<DailyForecast> _days() {
  final base = HcmTime.startOfDay(_nowHcm);
  return [
    for (var i = 0; i < 7; i++)
      DailyForecast(
        date: base.add(Duration(days: i)),
        tempMin: 24 + i * 0.3,
        tempMax: 31 - i * 0.2,
        condition: WeatherCondition.showers,
        precipitationMm: 113.5,
        precipitationMedian: i == 0 ? 0.4 : 12.6,
        rainDayProbability: i == 3 ? null : 0.6,
        windSpeed: i == 4 ? null : 15.0 + i,
      ),
  ];
}

Future<void> _pump(
  WidgetTester tester, {
  required int dayIndex,
  double scale = 1.0,
  bool dark = false,
  List<HourlyForecast>? hours,
}) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final provider = WeatherProvider(
    initialSettings: const AppSettings(),
    clock: () => _realNow,
  );
  final days = _days();
  await tester.pumpWidget(
    ChangeNotifierProvider<WeatherProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 740),
            textScaler: TextScaler.linear(scale),
            // Nen canh dong -> tat chuyen dong de pumpAndSettle dung duoc.
            disableAnimations: true,
          ),
          child: ForecastScreen(
            selectedDay: days[dayIndex],
            allDays: days,
            hourlyData: hours ?? _hours(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _scrollAll(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
    expect(tester.takeException(), isNull);
  }
}

String _appBarTitle(WidgetTester tester) {
  final appBar = tester.widget<AppBar>(find.byType(AppBar));
  return (appBar.title as Text).data!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Tieu de theo ngay', () {
    expect(ForecastFormat.title(DateTime.utc(2026, 10, 16)), 'Thứ 6, 16/10');
    expect(ForecastFormat.title(DateTime.utc(2026, 10, 15)), 'Thứ 5, 15/10');
  });

  testWidgets('(a) Hom nay: tieu de, bieu do 24 gio, vach "Bây giờ"', (
    tester,
  ) async {
    await _pump(tester, dayIndex: 0);
    expect(_appBarTitle(tester), 'Thứ 5, 15/10');
    expect(find.text('Nguồn: Trung bình nhiều năm'), findsOneWidget);
    expect(find.text('Nhiệt độ theo giờ'), findsOneWidget);
    expect(find.text('0,4 mm'), findsOneWidget); // luong mua trung vi
    await _scrollAll(tester);
    expect(find.text('Gió mạnh nhất (km/h)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(b) Ngay ngoai pham vi theo gio: thong bao ro rang', (
    tester,
  ) async {
    await _pump(tester, dayIndex: 4);
    expect(_appBarTitle(tester), 'Thứ 2, 19/10');
    expect(find.text('Nhiệt độ theo giờ'), findsNothing);
    expect(find.text('13 mm'), findsOneWidget); // trung vi (nhieu nam)
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pump();
    expect(
      find.textContaining('Chưa có số liệu theo giờ cho Thứ 2, 19/10'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ngay mai: chi cac gio cua ngay mai', (tester) async {
    await _pump(tester, dayIndex: 1);
    expect(_appBarTitle(tester), 'Thứ 6, 16/10');
    expect(find.textContaining('Có số liệu 00:00–09:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cham chip ngay khac doi tieu de', (tester) async {
    await _pump(tester, dayIndex: 0);
    final chip = find.bySemanticsLabel('Thứ 7, 17/10');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_appBarTitle(tester), 'Thứ 7, 17/10');
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final dayIndex in [0, 4]) {
      testWidgets(
        '(c) textScale 1.6, ngay $dayIndex, ${dark ? 'toi' : 'sang'}: '
        'khong tran',
        (tester) async {
          await _pump(tester, dayIndex: dayIndex, scale: 1.6, dark: dark);
          expect(tester.takeException(), isNull);
          if (dayIndex == 0) {
            final table = find.textContaining('Bảng chi tiết');
            await tester.scrollUntilVisible(
              table,
              300,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.ensureVisible(table);
            await tester.pumpAndSettle();
            await tester.tap(table);
            await tester.pumpAndSettle();
            expect(
              find.textContaining('Bây giờ'),
              findsWidgets,
            ); // hang gio hien tai
          }
          await _scrollAll(tester);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Khong co du lieu: trang thai trong', (tester) async {
    final day = _days().first;
    await tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: WeatherProvider(initialSettings: const AppSettings()),
        child: MaterialApp(
          home: ForecastScreen(
            selectedDay: day,
            allDays: const [],
            hourlyData: const [],
          ),
        ),
      ),
    );
    expect(find.text('Chưa có dữ liệu dự báo.'), findsOneWidget);
    expect(find.text('Dự báo chi tiết'), findsOneWidget);
  });

  group('48 gio theo gio', () {
    testWidgets('missing rainfall is not described as a complete dry day', (
      tester,
    ) async {
      final base = HcmTime.startOfDay(_nowHcm);
      await _pump(
        tester,
        dayIndex: 0,
        hours: [
          for (var i = 0; i < 24; i++)
            HourlyForecast(
              time: base.add(Duration(hours: i)),
              temperature: 26,
              condition: WeatherCondition.cloudy,
              precipitationMm: i == 0 ? 0 : null,
            ),
        ],
      );
      final summary = find.textContaining('Chỉ có lượng mưa cho 1/24 giờ.');
      await tester.scrollUntilVisible(
        summary,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(summary, findsOneWidget);
      expect(find.textContaining('trong các giờ có số liệu.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('hoursOfDay chi lay gio cua dung ngay', () {
      final today = HcmTime.startOfDay(_nowHcm);
      final h = _hours48();
      final t = ForecastScreen.hoursOfDay(h, today);
      final m = ForecastScreen.hoursOfDay(
        h,
        today.add(const Duration(days: 1)),
      );
      expect(t.length, 24);
      expect(m.length, 24);
      expect(t.every((x) => x.time.day == today.day), isTrue);
      expect(m.first.time.hour, 0);
      expect(m.last.time.hour, 23);
    });

    testWidgets('Hom nay: chi 24 gio cua hom nay, khong 48', (tester) async {
      await _pump(tester, dayIndex: 0, hours: _hours48());
      expect(find.textContaining('Có số liệu 00:00–23:00'), findsOneWidget);
      expect(find.textContaining('các giờ còn lại'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ngay mai: du 24 gio + tong mua', (tester) async {
      await _pump(tester, dayIndex: 1, hours: _hours48());
      expect(find.textContaining('Có số liệu 00:00–23:00'), findsOneWidget);
      expect(find.textContaining('Chưa có số liệu theo giờ'), findsNothing);
      expect(find.text('1/24 giờ'), findsOneWidget); // gio co mua
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pump();
      expect(find.textContaining('1 giờ có mưa · tổng 3 mm'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('textScale 2.0 voi 48 gio: khong tran', (tester) async {
      await _pump(tester, dayIndex: 1, scale: 2.0, hours: _hours48());
      await _scrollAll(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
