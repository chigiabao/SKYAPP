// Kiem tra cac sua loi cua dot audit giao dien r3 (muc 2, 4, 7, 11).
import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/screens/alert_settings_screen.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/utils/forecast_format.dart';
import 'package:sky_weather_app/utils/formatters.dart';
import 'package:sky_weather_app/widgets/planner_cards.dart';

void main() {
  group('map list subtitle (muc 2)', () {
    test('built from data fields, never from a name containing ", "', () {
      const cell = MapCell(
        cellId: 'c1',
        lat: 10.8,
        lon: 106.7,
        locationIds: ['a', 'b'],
        temperature: 30,
        rainProbability3h: 0.18,
        windSpeed: 14,
      );
      final m = buildCellMarkers(
        [cell],
        MapLayerKind.rain,
        temp: (c) => '${c.round()}',
        names: (_) => 'Phường Bến Thành, Phường Sài Gòn',
      ).single;
      expect(m.summary, '30° · Mưa 18% · Gió 14 km/h');
      expect(m.summary, isNot(contains('Phường')));
      expect(m.value, '18%');
      expect(m.details, startsWith('nhiệt độ 30 độ'));
      expect(m.semantics, startsWith('Phường Bến Thành, Phường Sài Gòn, '));
    });

    test('missing values show "--" and alerts are marked', () {
      const cell = MapCell(
        cellId: 'c2',
        lat: 10.8,
        lon: 106.7,
        locationIds: [],
        alert: true,
      );
      final m = buildCellMarkers(
        [cell],
        MapLayerKind.temperature,
        temp: (c) => '${c.round()}',
      ).single;
      expect(m.summary, '--° · Mưa -- · Gió -- · Cảnh báo');
    });
  });

  group('Vietnamese decimals (muc 4)', () {
    test('shared formatter', () {
      expect(WeatherFormat.decimal(0.4), '0,4');
      expect(WeatherFormat.decimal(1.25, 2), '1,25');
      expect(WeatherFormat.compact(8), '8');
      expect(WeatherFormat.compact(8.44), '8,4');
      expect(WeatherFormat.compact(42.0), '42');
    });

    test('UV alert peak uses a comma', () {
      AlertEvent uv(double peak) => AlertEvent(
        type: AlertType.uv,
        level: AlertLevel.warning,
        placeId: 'tsn',
        start: DateTime.utc(2026, 10, 20, 11),
        end: DateTime.utc(2026, 10, 20, 13),
        peak: peak,
        observed: false,
      );
      expect(uv(8.4).peakText, 'Chỉ số UV tới 8,4');
      expect(uv(8).peakText, 'Chỉ số UV tới 8');
    });

    test('activity reason rain amount uses a comma', () {
      final day = DateTime.utc(2026, 10, 20);
      final hours = [
        for (var h = 5; h < 10; h++)
          HourlyForecast(
            time: day.add(Duration(hours: h)),
            temperature: 26,
            condition: conditionFromWmo(61),
            precipitationMm: 0.4,
            uvIndex: 1,
            windGusts: 10,
            usAqi: 30,
            weatherCode: 61,
            source: DataSource.observed,
          ),
      ];
      final ws = bestWindows(
        Activity.running,
        hours,
        nowHcm: day.add(const Duration(hours: 5)),
      );
      expect(ws, isNotEmpty);
      for (final w in ws) {
        expect(w.reason, isNot(contains('0.4')));
      }
      expect(ws.any((w) => w.reason.contains('Mưa 0,4 mm')), isTrue);
    });

    test('compare source note has no nested parentheses', () {
      expect(DataCopy.observedInParens, isNot(contains('(')));
      expect(DataCopy.observedInParens, contains('ước tính mô hình'));
    });
  });

  group('alert settings footer (muc 7)', () {
    test('Android background note only on Android', () {
      expect(systemNotifyFooter(android: true), startsWith('Android:'));
      final other = systemNotifyFooter(android: false);
      expect(other, isNot(contains('Android')));
      expect(other, contains('giờ yên lặng'));
    });
  });

  group('activity time labels (muc 11)', () {
    final now = DateTime.utc(2026, 10, 20, 10); // Thu 3
    String label(int dayOffset, int h) {
      final s = now.copyWith(hour: h, minute: 0).add(Duration(days: dayOffset));
      return windowLabel(
        s,
        s.add(const Duration(hours: 1)),
        now,
      ).replaceAll('⁠', '');
    }

    test('day prefix from the shared ForecastFormat', () {
      expect(label(0, 19), 'Hôm nay 19:00–20:00');
      expect(label(1, 7), 'Ngày mai 07:00–08:00');
      expect(label(2, 6), 'Thứ 5 06:00–07:00');
    });

    test('commute chips use 07:30, not 7h30', () {
      expect(clockHm(7, 30), '07:30');
      expect(clockHm(17, 0), '17:00');
      expect(ForecastFormat.clock(6, 5), '06:05');
      expect(ForecastFormat.hourMinute(DateTime(2026, 10, 1, 7, 30)), '07:30');
    });
  });
}
