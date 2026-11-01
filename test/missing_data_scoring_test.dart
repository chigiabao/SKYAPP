import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/models/reminders.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';

final _now = DateTime.utc(2026, 10, 21, 6);

HourlyForecast _hour(int hour, {bool complete = false, bool storm = false}) =>
    HourlyForecast(
      time: DateTime.utc(2026, 10, 21, hour),
      temperature: 27,
      condition: WeatherCondition.cloudy,
      weatherCode: storm ? 95 : 3,
      rainProbability: storm ? 0.9 : 0,
      uvIndex: complete ? 2 : null,
      windGusts: complete ? 10 : null,
      usAqi: complete ? 30 : null,
    );

void main() {
  for (final metric in ['UV', 'gió giật', 'AQI']) {
    test('missing $metric makes an otherwise ideal hour unknown', () {
      final score = scoreHour(
        Activity.running,
        HourScoreInput(
          time: _now,
          temperature: 27,
          rainProbability: 0,
          uvIndex: metric == 'UV' ? null : 2,
          windGusts: metric == 'gió giật' ? null : 10,
          usAqi: metric == 'AQI' ? null : 30,
        ),
      );
      expect(score.missing, {metric});
      expect(score.rating, WindowRating.unknown);
      expect(score.penalties, isEmpty);
    });
  }

  test('entirely missing inputs cannot receive a good rating', () {
    final score = scoreHour(Activity.running, HourScoreInput(time: _now));
    expect(score.rating, WindowRating.unknown);
    expect(
      score.missing,
      containsAll(['nhiệt độ', 'mưa', 'UV', 'gió giật', 'AQI']),
    );
  });

  test('AQI is not required by a profile that does not use it', () {
    final score = scoreHour(
      Activity.laundry,
      HourScoreInput(
        time: DateTime.utc(2026, 10, 21, 9),
        temperature: 27,
        rainProbability: 0,
        uvIndex: 3,
        windGusts: 10,
      ),
    );
    expect(score.missing, isEmpty);
    expect(score.rating, WindowRating.good);
  });

  test('multi-hour windows retain missing metrics from every hour', () {
    final window = bestWindows(
      Activity.cycling,
      [_hour(6, complete: true), _hour(7)],
      nowHcm: _now,
      hourBonus: const {6: 10},
    ).single;
    expect(window.rating, WindowRating.unknown);
    expect(window.missing, {'UV', 'gió giật', 'AQI'});
    expect(window.reason, contains('Thiếu dữ liệu: UV, gió giật, AQI'));
  });

  test('complete windows keep the existing good rating', () {
    final window = bestWindows(Activity.running, [
      _hour(6, complete: true),
    ], nowHcm: _now).single;
    expect(window.rating, WindowRating.good);
    expect(window.score, 100);
  });

  test('reminders disclose missing metrics and known hazards without /100', () {
    const routine = ActivityRoutine(
      id: 'review',
      activity: Activity.running,
      placeId: 'tsn',
      hour: 7,
    );
    final plan = planReminders(
      [routine],
      nowHcm: _now,
      minutesBefore: 15,
      quiet: const AlertSettings(),
      hoursFor: (_) => [_hour(7, storm: true)],
      horizon: const Duration(hours: 2),
    );
    final reminder = plan.reminders.single;
    expect(reminder.body, contains('Thiếu dữ liệu: UV, gió giật, AQI'));
    expect(reminder.body, contains('dông'));
    expect(reminder.body, isNot(contains('/100')));
    expect(reminder.body, isNot(contains('Thời tiết tốt')));
    expect(reminder.alternative, isNull);
  });

  test('an incomplete hour is not suggested as a better alternative', () {
    const routine = ActivityRoutine(
      id: 'review',
      activity: Activity.running,
      placeId: 'tsn',
      hour: 7,
    );
    expect(
      alternativeSlot(
        routine,
        [_hour(7, complete: true, storm: true), _hour(8)],
        _hour(7).time,
        notBefore: _now,
      ),
      isNull,
    );
  });

  test('alert evidence excludes empty, expired and out-of-window hours', () {
    expect(hasAlertHours([], _now, 3), isFalse);
    expect(hasAlertHours([_hour(5), _hour(9)], _now, 3), isFalse);
    expect(hasAlertHours([_hour(6)], _now, 3), isTrue);
    expect(hasAlertHours([_hour(8)], _now, 3), isTrue);
  });

  test('climatology alone cannot establish that alerts were checked', () {
    final statistical = HourlyForecast(
      time: _now,
      temperature: 27,
      condition: WeatherCondition.cloudy,
      source: DataSource.climatology,
    );
    expect(hasAlertHours([statistical], _now, 3), isFalse);
    expect(hasAlertHours([statistical, _hour(7)], _now, 3), isTrue);
    expect(
      evaluateAlerts([statistical], nowHcm: _now, placeId: 'tsn'),
      isEmpty,
    );
  });
}
