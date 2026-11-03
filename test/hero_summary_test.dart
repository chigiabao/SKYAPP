import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/home/home_header_info.dart';
import 'package:sky_weather_app/ui/weather/weather_insights.dart';

/// Cau tom tat hanh dong o dau trang + dong thoi gian mua.
void main() {
  final day = DateTime.utc(2026, 10, 18);

  List<HourlyForecast> hours(
    DateTime from,
    int n, {
    Map<int, double> prob = const {},
    Set<int> thunder = const {},
    Map<int, double> observedMm = const {},
  }) => [
    for (var i = 0; i < n; i++)
      () {
        final t = from.add(Duration(hours: i));
        final obs = observedMm.containsKey(t.hour) && i == 0;
        return HourlyForecast(
          time: t,
          temperature: 28,
          condition: WeatherCondition.cloudy,
          rainProbability: obs ? null : (prob[t.hour] ?? 0.05),
          weatherCode: thunder.contains(t.hour) ? 95 : 3,
          precipitationMm: obs ? observedMm[t.hour] : (prob[t.hour] ?? 0),
          source: obs ? DataSource.observed : DataSource.forecast,
        );
      }(),
  ];

  String? sum(List<HourlyForecast> h, DateTime now) =>
      heroRainSummary(h, nowHcm: now);

  test('khong mua ban ngay -> "Không mưa đến tối"', () {
    final now = day.add(const Duration(hours: 9, minutes: 20));
    expect(
      sum(hours(day.add(const Duration(hours: 9)), 30), now),
      'Không mưa đến tối',
    );
  });

  test('buoi toi khong mua -> "Đêm nay không mưa"', () {
    final now = day.add(const Duration(hours: 20));
    expect(sum(hours(now, 24), now), 'Đêm nay không mưa');
  });

  test('dong roi mua keo dai qua gio ve', () {
    final now = day.add(const Duration(hours: 9));
    final h = hours(
      now,
      24,
      prob: {for (var x = 12; x < 20; x++) x: 0.9},
      thunder: {12},
    );
    expect(
      sum(h, now),
      'Dự báo dông 12:00–13:00, mưa đến 20:00 · mang áo mưa khi về',
    );
  });

  test('mua chac chan buoi sang khong trung gio ve', () {
    final now = day.add(const Duration(hours: 9));
    final h = hours(now, 24, prob: {10: 0.8, 11: 0.75});
    expect(sum(h, now), 'Dự báo mưa 10:00–12:00 · nhớ mang ô');
  });

  test('kha nang thap -> "Có thể mưa" kem %', () {
    final now = day.add(const Duration(hours: 9));
    final h = hours(now, 24, prob: {13: 0.55, 14: 0.6});
    expect(sum(h, now), 'Có thể mưa 13:00–15:00 (60%) · nên mang ô');
  });

  test(
    'model estimate cannot assert current rain or extend forecast certainty',
    () {
      final now = day.add(const Duration(hours: 10, minutes: 5));
      final h = hours(
        day.add(const Duration(hours: 10)),
        24,
        observedMm: {10: 2.0},
        prob: {11: 0.9},
      );
      expect(sum(h, now), 'Dự báo mưa 11:00–12:00 · nhớ mang ô');
    },
  );

  test('do not join rain across an hour below the probability threshold', () {
    final now = day.add(const Duration(hours: 13));
    final h = hours(now, 24, prob: {14: 0.8, 16: 0.9, 17: 0.9}, thunder: {16});
    expect(sum(h, now), 'Dự báo mưa 14:00–15:00 · nhớ mang ô');
  });

  test('khong co gio nao -> null', () {
    expect(sum(const [], day), isNull);
  });

  test('rainTimeline excludes model analysis instead of showing binary probability', () {
    final now = day.add(const Duration(hours: 10));
    final h = hours(
      now,
      30,
      observedMm: {10: 1.2},
      prob: {12: 0.4},
      thunder: {12},
    );
    final t = rainTimeline(h, nowHcm: now);
    expect(t, hasLength(23));
    expect(t.first.time, now.add(const Duration(hours: 1)));
    expect(t.first.p, 0.05);
    expect(t[1].p, closeTo(0.4, 1e-9));
    expect(t[1].thunder, isTrue);
    for (final source in [DataSource.observed, DataSource.forecast]) {
      final missing = rainTimeline([
        HourlyForecast(
          time: now,
          temperature: 28,
          condition: WeatherCondition.cloudy,
          rainProbability: null,
          precipitationMm: null,
          source: source,
        ),
      ], nowHcm: now);
      if (source == DataSource.observed) {
        expect(missing, isEmpty);
      } else {
        expect(missing.single.p, isNull);
        expect(missing.single.mm, isNull);
      }
    }
  });

  test('maxRainPercent 2 gio toi', () {
    final now = day.add(const Duration(hours: 10));
    final h = hours(now, 6, prob: {11: 0.7, 13: 0.95});
    expect(maxRainPercent(h, nowHcm: now), 70);
    expect(maxRainPercent(const [], nowHcm: now), isNull);
  });

  test('Tan Khanh regression: 0.3 mm estimate does not mean 100% or rain until 18h', () {
    final now = day.add(const Duration(hours: 10, minutes: 40));
    final h = hours(
      day.add(const Duration(hours: 10)),
      24,
      observedMm: {10: 0.3},
      prob: {
        11: 0.5626,
        12: 0.223,
        13: 0.3504,
        14: 0.3468,
        15: 0.4836,
        16: 0.3275,
        17: 0.3703,
        18: 0.1902,
      },
    );
    expect(sum(h, now), 'Có thể mưa 11:00–12:00 (56%) · nên mang ô');
    expect(maxRainPercent(h, nowHcm: now), 56);
    expect(rainTimeline(h, nowHcm: now).map((s) => s.p), isNot(contains(1.0)));
  });

  test('analysis alone stays an estimate, not a current rain confirmation', () {
    final now = day.add(const Duration(hours: 10));
    final h = hours(now, 1, observedMm: {10: 0.3});
    expect(sum(h, now), 'Ước tính có mưa lúc 10:00 · chưa xác nhận tại chỗ');
    expect(sum(h, now), isNot(contains('Đang mưa')));
    expect(maxRainPercent(h, nowHcm: now), isNull);
    expect(rainTimeline(h, nowHcm: now), isEmpty);
  });

  test(
    'current model analysis is clearly labelled as an estimate in the header',
    () {
      final now = day.add(const Duration(hours: 10));
      final provider = WeatherProvider(clock: () => HcmTime.toInstant(now));
      addTearDown(provider.dispose);
      final current = CurrentWeather(
        temperature: 29.4,
        condition: WeatherCondition.drizzle,
        lastUpdated: now,
        source: DataSource.observed,
        precipitationMm: 0.3,
      );
      final info = homeHeaderInfo(
        provider,
        current,
        location: provider.place,
        units: const UnitPrefs(),
      );
      expect(info.condition, 'Ước tính: Mưa phùn');
      expect(info.sourceLabel, 'ước tính mô hình theo giờ');
    },
  );

  test('current AI prediction is labelled as a forecast, not a reading', () {
    final now = day.add(const Duration(hours: 10));
    final provider = WeatherProvider(clock: () => HcmTime.toInstant(now));
    addTearDown(provider.dispose);
    final info = homeHeaderInfo(
      provider,
      CurrentWeather(
        temperature: 30,
        condition: WeatherCondition.partlyCloudy,
        lastUpdated: now,
        source: DataSource.ai,
      ),
      location: provider.place,
      units: const UnitPrefs(),
    );
    expect(info.condition, 'AI dự báo: Có mây');
    expect(info.sourceLabel, 'AI của nhóm · theo giờ');
    expect(info.updated, 'Dự báo cho 10:00');
  });
}
