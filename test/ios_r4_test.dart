// Vong 4 iOS: nhan khung gio mua, an hang thieu o o ban do, vung de hieu,
// dinh dang ngay-gio thong nhat.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/forecast/forecast_widgets.dart';
import 'package:sky_weather_app/screens/map/cell_sheet.dart';
import 'package:sky_weather_app/utils/forecast_format.dart';

HourlyForecast _h(DateTime t) => HourlyForecast(
  time: t,
  temperature: 27,
  condition: conditionFromWmo(61),
  precipitationMm: 0.5,
);

void main() {
  group('Muc 2 - khung gio "Giờ có mưa"', () {
    test('thieu gio -> "21:00–23:00"; du 24 gio -> "cả ngày"', () {
      final day = DateTime(2026, 10, 21);
      final late = [
        for (var h = 21; h <= 23; h++) _h(day.add(Duration(hours: h))),
      ];
      expect(DaySummaryCard.hoursWindow(late), '21:00–23:00');
      final full = [
        for (var h = 0; h < 24; h++) _h(day.add(Duration(hours: h))),
      ];
      expect(DaySummaryCard.hoursWindow(full), 'cả ngày');
      expect(DaySummaryCard.hoursWindow(const []), isNull);
    });
  });

  group('Muc 3 - o ban do an hang thieu so lieu', () {
    testWidgets('khong co "3 giờ tới" khi thieu; co khi du', (tester) async {
      Future<void> pump(MapCell c) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CellSheet(
                cell: c,
                provider: WeatherProvider(initialSettings: const AppSettings()),
                placeNames: const ['Phường Bến Thành'],
                stale: false,
                onDetail: null,
              ),
            ),
          ),
        ),
      );
      await pump(
        const MapCell(
          cellId: 'a',
          lat: 10.77,
          lon: 106.7,
          locationIds: ['x'],
          temperature: 30,
          weatherCode: 1,
          windSpeed: 10,
        ),
      );
      expect(find.textContaining('3 giờ tới'), findsNothing);
      expect(find.textContaining('Lượng mưa trong giờ'), findsNothing);
      expect(find.textContaining('Không có dữ liệu'), findsNothing);
      expect(find.textContaining('Gió'), findsOneWidget);

      await pump(
        const MapCell(
          cellId: 'b',
          lat: 10.77,
          lon: 106.7,
          locationIds: ['x'],
          temperature: 30,
          weatherCode: 61,
          rainProbability3h: 0.7,
          precipitation3h: 3,
        ),
      );
      expect(
        find.textContaining('Khả năng mưa 3 giờ tới: 70%'),
        findsOneWidget,
      );
      expect(find.textContaining('Lượng mưa 3 giờ tới:'), findsOneWidget);
      expect(find.textContaining('gió không có dữ liệu'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Muc 5 - vung truoc sap nhap de hieu', () {
    test('Place.friendlyDetail doi "TP.HCM cũ"', () {
      const old = Place(
        id: 'p1',
        name: 'Phường Bến Thành',
        kind: PlaceKind.phuong,
        lat: 10.77,
        lon: 106.7,
        region: 'TP.HCM cũ',
      );
      expect(old.friendlyDetail, 'Khu vực TP.HCM');
      expect(friendlyRegion('Quận 1'), 'Quận 1');
    });
  });

  group('Muc 4 - mot kieu ngay-gio', () {
    test('ngan "20/10 10:00", day du "Thứ 3, 20/10 · 10:00"', () {
      final t = DateTime(2026, 10, 20, 10);
      expect(ForecastFormat.dateTime(t), '20/10 10:00');
      expect(ForecastFormat.moment(t), 'Thứ 3, 20/10 · 10:00');
      expect(ForecastFormat.dayMonth(DateTime(2026, 3, 7)), '07/03');
      expect(ForecastFormat.clock(7, 30), '07:30');
    });
  });
}
