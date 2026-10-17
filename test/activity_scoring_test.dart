import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/weather.dart';

final DateTime _day = DateTime.utc(2026, 10, 16);

HourScoreInput _in(
  int hour, {
  double? temp = 27,
  double? feels,
  double? prob = 0,
  double? mm,
  double? uv = 2,
  double? gust = 10,
  int? aqi = 30,
  int? code = 1,
}) => HourScoreInput(
  time: _day.add(Duration(hours: hour)),
  temperature: temp,
  feelsLike: feels,
  rainProbability: prob,
  precipitationMm: mm,
  uvIndex: uv,
  windGusts: gust,
  usAqi: aqi,
  weatherCode: code,
);

HourlyForecast _hf(
  DateTime t, {
  double temp = 27,
  double? prob = 0,
  double? uv = 2,
  int code = 1,
}) => HourlyForecast(
  time: t,
  temperature: temp,
  condition: conditionFromWmo(code),
  rainProbability: prob,
  uvIndex: uv,
  windGusts: 10,
  usAqi: 30,
  weatherCode: code,
  source: DataSource.forecast,
);

void main() {
  group('scoreHour', () {
    test('dieu kien ly tuong -> 100', () {
      expect(scoreHour(Activity.running, _in(6)).score, 100);
    });

    test('ngoai khung gio cua hoat dong -> 0', () {
      expect(scoreHour(Activity.running, _in(13)).score, 0);
      // anyHour: lich nguoi dung tu dat
      expect(scoreHour(Activity.running, _in(13), anyHour: true).score, 100);
    });

    test('moi yeu to deu tru diem, dung ten ly do', () {
      final s = scoreHour(
        Activity.running,
        _in(6, temp: 34, prob: 0.8, uv: 8, gust: 50, aqi: 160, code: 95),
      );
      expect(
        s.penalties.keys,
        containsAll(['nóng', 'mưa', 'dông', 'UV', 'gió', 'AQI']),
      );
      expect(s.score, 0); // kep ve 0
    });

    test('tat ca null -> khong tru diem (khong bia du lieu)', () {
      final s = scoreHour(
        Activity.cycling,
        _in(
          7,
          temp: null,
          prob: null,
          uv: null,
          gust: null,
          aqi: null,
          code: null,
        ),
      );
      expect(s.score, 100);
      expect(s.penalties, isEmpty);
    });

    test('bien nhiet do: dung tempHi khong tru, vuot thi tru', () {
      expect(scoreHour(Activity.running, _in(6, temp: 30)).score, 100);
      expect(scoreHour(Activity.running, _in(6, temp: 31)).score, 94);
      // Uu tien nhiet do cam giac.
      expect(
        scoreHour(Activity.running, _in(6, temp: 28, feels: 33)).score,
        82,
      );
    });

    test('mua da do (mm) du xac suat null', () {
      final s = scoreHour(Activity.laundry, _in(9, prob: null, mm: 2, uv: 5));
      expect(s.penalties['mưa'], closeTo(90, 1e-9));
    });

    test('phoi do can nang; chup anh duoc cong gio vang', () {
      expect(scoreHour(Activity.laundry, _in(9, uv: 1)).penalties, {
        'ít nắng': 15,
      });
      final golden = scoreHour(
        Activity.photography,
        _in(6, temp: 31, feels: 36),
      );
      final normal = scoreHour(
        Activity.photography,
        _in(7, temp: 31, feels: 36),
      );
      expect(golden.score, greaterThan(normal.score));
    });

    test('muc nhay cam nhan he so phat', () {
      final hi = scoreHour(
        Activity.running,
        _in(6, prob: 0.5),
        sensitivity: Sensitivity.high,
      );
      final lo = scoreHour(
        Activity.running,
        _in(6, prob: 0.5),
        sensitivity: Sensitivity.low,
      );
      expect(hi.score, lessThan(lo.score));
    });
  });

  group('bestWindows', () {
    final now = DateTime.utc(2026, 10, 16, 4, 30);

    test('chon gio kho rao, co ly do; tinh tu nowHcm', () {
      final hours = [
        for (var i = 0; i < 48; i++)
          _hf(
            DateTime.utc(2026, 10, 16, 4).add(Duration(hours: i)),
            // Sang nay mua, chieu nay kho
            prob: i < 6 ? 0.9 : 0.05,
          ),
      ];
      final w = bestWindows(Activity.running, hours, nowHcm: now);
      expect(w, isNotEmpty);
      expect(w.length, lessThanOrEqualTo(3));
      expect(w.first.start.hour, isNot(anyOf(5, 6, 7, 8, 9)));
      expect(w.first.rating, WindowRating.good);
      expect(w.first.reason, contains('Mưa 5%'));
      // Khung khong chong nhau
      for (var i = 0; i < w.length; i++) {
        for (var j = i + 1; j < w.length; j++) {
          expect(
            w[i].start.isBefore(w[j].end) && w[j].start.isBefore(w[i].end),
            isFalse,
          );
        }
      }
    });

    test('khung nhieu gio phai lien tiep va trong gio cho phep', () {
      final hours = [
        for (final h in [7, 8, 10, 11, 12])
          _hf(DateTime.utc(2026, 10, 16, h), uv: 6),
      ];
      final w = bestWindows(
        Activity.laundry,
        hours,
        nowHcm: DateTime.utc(2026, 10, 16, 6),
      );
      expect(w, hasLength(1));
      expect(w.single.start.hour, 10);
      expect(w.single.end.hour, 13);
    });

    test('khong du lieu / ngoai horizon -> rong', () {
      expect(bestWindows(Activity.outing, const [], nowHcm: now), isEmpty);
      final far = [_hf(DateTime.utc(2026, 10, 20, 7))];
      expect(bestWindows(Activity.running, far, nowHcm: now), isEmpty);
      final past = [_hf(DateTime.utc(2026, 10, 16, 3))];
      expect(bestWindows(Activity.running, past, nowHcm: now), isEmpty);
    });

    test('dong lam diem thap -> danh gia Kem', () {
      final hours = [
        for (var h = 5; h < 10; h++)
          _hf(DateTime.utc(2026, 10, 16, h), prob: 0.9, code: 95),
      ];
      final w = bestWindows(Activity.running, hours, nowHcm: now);
      expect(w.first.rating, WindowRating.poor);
      expect(w.first.reason, contains('Lưu ý dông'));
    });
  });

  group('ActivityRoutine', () {
    test('lan tiep theo theo thu trong tuan', () {
      // 16/10/2026 la thu Sau.
      const r = ActivityRoutine(
        id: 'r',
        activity: Activity.commute,
        placeId: 'p',
        hour: 7,
        weekdays: {DateTime.monday},
      );
      expect(
        r.nextAfter(DateTime.utc(2026, 10, 16, 8)),
        DateTime.utc(2026, 10, 19, 7),
      );
      const daily = ActivityRoutine(
        id: 'd',
        activity: Activity.running,
        placeId: 'p',
        hour: 17,
      );
      expect(
        daily.nextAfter(DateTime.utc(2026, 10, 16, 8)),
        DateTime.utc(2026, 10, 16, 17),
      );
      const none = ActivityRoutine(
        id: 'n',
        activity: Activity.running,
        placeId: 'p',
        hour: 17,
        weekdays: {},
      );
      expect(none.nextAfter(DateTime.utc(2026, 10, 16, 8)), isNull);
    });

    test('JSON di/ve; hong -> null', () {
      const r = ActivityRoutine(
        id: 'r',
        activity: Activity.watering,
        placeId: 'p',
        hour: 6,
        minute: 30,
        weekdays: {6, 7},
        sensitivity: Sensitivity.high,
      );
      final b = ActivityRoutine.tryFromJson(r.toJson())!;
      expect(b.activity, Activity.watering);
      expect(b.weekdays, {6, 7});
      expect(b.sensitivity, Sensitivity.high);
      expect(ActivityRoutine.tryFromJson({'id': 'x', 'hour': 30}), isNull);
    });

    test('scoreRoutineAt: thieu gio -> null', () {
      const r = ActivityRoutine(
        id: 'r',
        activity: Activity.running,
        placeId: 'p',
        hour: 13,
      );
      final at = DateTime.utc(2026, 10, 16, 13, 30);
      expect(scoreRoutineAt(r, const [], at), isNull);
      final s = scoreRoutineAt(r, [_hf(DateTime.utc(2026, 10, 16, 13))], at);
      expect(s!.score, 100);
    });
  });
}
