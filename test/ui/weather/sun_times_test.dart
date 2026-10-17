import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/sun_times.dart';

const double _lat = 10.7909;
const double _lon = 106.6313;

void _near(DateTime actual, DateTime expected) {
  final int diff = actual.difference(expected).inSeconds.abs();
  expect(
    diff,
    lessThanOrEqualTo(180),
    reason: 'thuc te $actual, mong doi $expected (+-3 phut)',
  );
}

void main() {
  group('SunTimes TP.HCM', () {
    // Gia tri tham chieu NOAA / timeanddate.com cho TP.HCM (UTC+7).
    final cases = <(DateTime, String, String)>[
      (DateTime.utc(2026, 10, 15), '05:42', '17:36'),
      (DateTime.utc(2026, 6, 21), '05:32', '18:18'),
      (DateTime.utc(2026, 12, 21), '06:07', '17:36'),
      (DateTime.utc(2026, 3, 20), '05:58', '18:04'),
    ];
    for (final (date, rise, set) in cases) {
      test('${date.month}/${date.day}: moc $rise, lan $set', () {
        final SunTimes s = SunTimes.forDate(date, lat: _lat, lon: _lon);
        DateTime at(String hm) {
          final parts = hm.split(':').map(int.parse).toList();
          return DateTime.utc(
            date.year,
            date.month,
            date.day,
            parts[0],
            parts[1],
          );
        }

        _near(s.sunrise, at(rise));
        _near(s.sunset, at(set));
        expect(s.sunrise.isUtc, isTrue);
        expect(s.isPolarDay || s.isPolarNight, isFalse);
        expect(
          s.solarNoon.isAfter(s.sunrise) && s.solarNoon.isBefore(s.sunset),
          isTrue,
        );
      });
    }

    test('chi dung ngay cua tham so, khong phu thuoc gio', () {
      final a = SunTimes.forDate(
        DateTime.utc(2026, 10, 15, 0, 1),
        lat: _lat,
        lon: _lon,
      );
      final b = SunTimes.forDate(
        DateTime.utc(2026, 10, 15, 23, 59),
        lat: _lat,
        lon: _lon,
      );
      expect(a.sunrise, b.sunrise);
      expect(a.sunset, b.sunset);
    });

    test('mui gio khac doi gio dong ho tuong ung', () {
      final s7 = SunTimes.forDate(
        DateTime.utc(2026, 10, 15),
        lat: _lat,
        lon: _lon,
      );
      final s0 = SunTimes.forDate(
        DateTime.utc(2026, 10, 15),
        lat: _lat,
        lon: _lon,
        utcOffsetHours: 0,
      );
      expect(s7.sunset.difference(s0.sunset).inMinutes, 7 * 60);
    });
  });

  group('isDaytime ranh gioi', () {
    final DateTime day = DateTime.utc(2026, 10, 15);
    final SunTimes s = SunTimes.forDate(day, lat: _lat, lon: _lon);
    const Duration minute = Duration(minutes: 1);

    test('1 phut truoc / sau khi moc', () {
      expect(
        isDaytime(s.sunrise.subtract(minute), lat: _lat, lon: _lon),
        isFalse,
      );
      expect(isDaytime(s.sunrise.add(minute), lat: _lat, lon: _lon), isTrue);
    });
    test('1 phut truoc / sau khi lan', () {
      expect(
        isDaytime(s.sunset.subtract(minute), lat: _lat, lon: _lon),
        isTrue,
      );
      expect(isDaytime(s.sunset.add(minute), lat: _lat, lon: _lon), isFalse);
    });
    test('trua va nua dem', () {
      expect(
        isDaytime(DateTime.utc(2026, 10, 15, 12), lat: _lat, lon: _lon),
        isTrue,
      );
      expect(
        isDaytime(DateTime.utc(2026, 10, 15, 0, 30), lat: _lat, lon: _lon),
        isFalse,
      );
      expect(
        SunTimes.isDaytime(
          DateTime.utc(2026, 10, 15, 23),
          lat: _lat,
          lon: _lon,
        ),
        isFalse,
      );
    });
  });

  test('vung cuc', () {
    final summer = SunTimes.forDate(
      DateTime.utc(2026, 6, 21),
      lat: 80,
      lon: 0,
      utcOffsetHours: 0,
    );
    expect(summer.isPolarDay, isTrue);
    expect(
      isDaytime(
        DateTime.utc(2026, 6, 21, 2),
        lat: 80,
        lon: 0,
        utcOffsetHours: 0,
      ),
      isTrue,
    );
    final winter = SunTimes.forDate(
      DateTime.utc(2026, 12, 21),
      lat: 80,
      lon: 0,
      utcOffsetHours: 0,
    );
    expect(winter.isPolarNight, isTrue);
    expect(
      isDaytime(
        DateTime.utc(2026, 12, 21, 12),
        lat: 80,
        lon: 0,
        utcOffsetHours: 0,
      ),
      isFalse,
    );
  });
}
