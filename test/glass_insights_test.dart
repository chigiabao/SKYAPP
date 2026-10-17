import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/ui/weather/weather_insights.dart';

final DateTime _now = DateTime.utc(2026, 10, 16, 12, 20);

List<HourlyForecast> _hours({
  double prob = 0.1,
  Map<int, double> probAt = const {},
  Map<int, int> codeAt = const {},
  double? gust,
  WeatherCondition condition = WeatherCondition.cloudy,
  DataSource source = DataSource.forecast,
  Map<int, double> uvAt = const {},
}) => [
  for (var i = 0; i < 24; i++)
    HourlyForecast(
      time: DateTime.utc(2026, 10, 16, 12).add(Duration(hours: i)),
      temperature: 30,
      condition: condition,
      rainProbability: probAt[i] ?? prob,
      weatherCode: codeAt[i] ?? 3,
      windGusts: gust,
      source: source,
      uvIndex: uvAt.isEmpty ? null : (uvAt[i] ?? 0),
    ),
];

void main() {
  group('hourlySummary', () {
    test('mua tu mot gio sau', () {
      expect(
        hourlySummary(_hours(probAt: {3: 0.6, 4: 0.8}), nowHcm: _now),
        'Có khả năng mưa từ khoảng 15:00 (60%).',
      );
    });

    test('mua ngay bay gio', () {
      expect(
        hourlySummary(_hours(probAt: {0: 0.55}), nowHcm: _now),
        'Có khả năng mưa ngay bây giờ (55%).',
      );
    });

    test('khong mua, cung dieu kien den het ngay + gio giat', () {
      expect(
        hourlySummary(
          _hours(gust: 19.4),
          nowHcm: _now,
          currentCondition: WeatherCondition.cloudy,
        ),
        'Trời nhiều mây đến hết ngày. Gió giật tới 19\u00A0km\u2060/\u2060h.',
      );
    });

    test('gio thuc te dang mua (mm)', () {
      final hours = [
        for (var i = 0; i < 4; i++)
          HourlyForecast(
            time: DateTime.utc(2026, 10, 7, 12 + i),
            temperature: 28,
            condition: WeatherCondition.drizzle,
            rainProbability: 1,
            precipitationMm: i < 3 ? 0.4 : 0,
            source: DataSource.observed,
          ),
      ];
      expect(
        hourlySummary(hours, nowHcm: DateTime.utc(2026, 10, 7, 12)),
        'Đang có mưa, kéo dài đến khoảng 15:00.',
      );
    });

    test('rong -> null', () {
      expect(hourlySummary(const [], nowHcm: _now), isNull);
    });
  });

  group('weatherAlert', () {
    test('xac suat >= 70 % trong 6 gio toi', () {
      final a = weatherAlert(
        _hours(probAt: {3: 0.75, 4: 0.9, 5: 0.7}),
        nowHcm: _now,
      )!;
      expect(a.title, 'Khả năng mưa cao · 15:00\u2060–\u206018:00');
      expect(a.thunder, isFalse);
      expect(a.maxPercent, 90);
      expect(
        a.detail,
        'Tới 90% · dự báo mô hình, không phải cảnh báo chính thức',
      );
    });

    test('ma dong -> mua dong', () {
      final a = weatherAlert(_hours(codeAt: {3: 95, 5: 95}), nowHcm: _now)!;
      expect(a.title, 'Cảnh báo mưa dông · 15:00\u2060–\u206018:00');
      expect(a.thunder, isTrue);
    });

    test('ngoai 6 gio hoac duoi nguong -> khong canh bao', () {
      expect(weatherAlert(_hours(probAt: {6: 0.95}), nowHcm: _now), isNull);
      expect(weatherAlert(_hours(probAt: {2: 0.69}), nowHcm: _now), isNull);
    });
  });

  test('feelsLikeSentence', () {
    expect(
      feelsLikeSentence(temperature: 30, feelsLike: 38, humidity: 70),
      'Độ ẩm làm cảm giác nóng hơn.',
    );
    expect(
      feelsLikeSentence(temperature: 20, feelsLike: 16, windKmh: 20),
      'Gió làm cảm giác mát hơn.',
    );
    expect(
      feelsLikeSentence(temperature: 25, feelsLike: 26),
      'Tương tự nhiệt độ thực.',
    );
  });

  test('uvSentence: gio cuoi >= 3 hom nay', () {
    expect(
      uvSentence(_hours(uvAt: {0: 8, 1: 7, 2: 5, 3: 3.2, 4: 1}), nowHcm: _now),
      'Dùng kem chống nắng đến 16:00.',
    );
    expect(
      uvSentence(_hours(uvAt: {0: 2, 1: 1}), nowHcm: _now),
      'UV thấp phần còn lại của ngày.',
    );
    expect(uvSentence(_hours(), nowHcm: _now), isNull);
  });

  test('aqiSentence: khong co gio hom qua -> cau PM2.5', () {
    expect(
      aqiSentence(aqi: 79, pm25: 30, hours: _hours(), nowHcm: _now),
      'Bụi mịn PM2.5 30,0\u00A0µg/m³, gấp 2,0 lần mức khuyến nghị 24 giờ '
      'của WHO.',
    );
    expect(
      aqiSentence(aqi: null, pm25: null, hours: const [], nowHcm: _now),
      isNull,
    );
    final yesterday = HourlyForecast(
      time: DateTime.utc(2026, 10, 15, 12),
      temperature: 30,
      condition: WeatherCondition.cloudy,
      usAqi: 75,
    );
    expect(
      aqiSentence(aqi: 79, pm25: 30, hours: [yesterday], nowHcm: _now),
      'Chỉ số tương tự hôm qua vào giờ này.',
    );
  });

  test('rainTotals: khong du 24 gio qua -> null; tong 24 gio toi', () {
    final hours = [
      for (var i = 0; i < 24; i++)
        HourlyForecast(
          time: DateTime.utc(2026, 10, 16, 12).add(Duration(hours: i)),
          temperature: 30,
          condition: WeatherCondition.rainy,
          precipitationMm: i < 2 ? 1.5 : 0,
          source: DataSource.forecast,
        ),
    ];
    final r = rainTotals(hours, nowHcm: _now);
    expect(r.past24, isNull);
    expect(r.next24, closeTo(3.0, 1e-9));
  });
}
