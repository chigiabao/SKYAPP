import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/weather.dart';
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
    expect(sum(h, now), 'Dông 12–13h, mưa đến 20h · mang áo mưa khi về');
  });

  test('mua chac chan buoi sang khong trung gio ve', () {
    final now = day.add(const Duration(hours: 9));
    final h = hours(now, 24, prob: {10: 0.8, 11: 0.75});
    expect(sum(h, now), 'Mưa 10–12h · nhớ mang ô');
  });

  test('kha nang thap -> "Có thể mưa" kem %', () {
    final now = day.add(const Duration(hours: 9));
    final h = hours(now, 24, prob: {13: 0.55, 14: 0.6});
    expect(sum(h, now), 'Có thể mưa 13–15h (60%) · nên mang ô');
  });

  test('dang mua (gio thuc te) -> "Đang mưa"', () {
    final now = day.add(const Duration(hours: 10, minutes: 5));
    final h = hours(
      day.add(const Duration(hours: 10)),
      24,
      observedMm: {10: 2.0},
      prob: {11: 0.9},
    );
    expect(sum(h, now), 'Đang mưa, đến khoảng 12h · nhớ mang ô');
  });

  test('gop khoang ngat 1 gio; dong chi o giua', () {
    final now = day.add(const Duration(hours: 13));
    final h = hours(now, 24, prob: {14: 0.8, 16: 0.9, 17: 0.9}, thunder: {16});
    expect(sum(h, now), 'Dông 16–17h, mưa đến 18h · mang áo mưa khi về');
  });

  test('khong co gio nao -> null', () {
    expect(sum(const [], day), isNull);
  });

  test('rainTimeline 24 o, gio thuc te -> 0/1, dong', () {
    final now = day.add(const Duration(hours: 10));
    final h = hours(
      now,
      30,
      observedMm: {10: 1.2},
      prob: {12: 0.4},
      thunder: {12},
    );
    final t = rainTimeline(h, nowHcm: now);
    expect(t, hasLength(24));
    expect(t.first.p, 1.0);
    expect(t.first.mm, 1.2);
    expect(t[2].p, closeTo(0.4, 1e-9));
    expect(t[2].thunder, isTrue);
  });

  test('maxRainPercent 2 gio toi', () {
    final now = day.add(const Duration(hours: 10));
    final h = hours(now, 6, prob: {11: 0.7, 13: 0.95});
    expect(maxRainPercent(h, nowHcm: now), 70);
    expect(maxRainPercent(const [], nowHcm: now), isNull);
  });
}
