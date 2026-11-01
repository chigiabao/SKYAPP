import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/screens/trip/nowcast_card.dart';

// Du lieu gia CHI dung trong test.
final _now = DateTime.utc(2026, 10, 17, 15);

HourlyForecast _h(int i, double p, double mm, DataSource source) =>
    HourlyForecast(
      time: _now.add(Duration(hours: i)),
      temperature: 30,
      condition: WeatherCondition.cloudy,
      rainProbability: p,
      precipitationMm: mm,
      source: source,
    );

void main() {
  test('gio thuc te: xac suat 1/0 khong duoc dung cho loi khuyen', () {
    // Backend dat 1.0 cho gio thuc te co mua do duoc (>= nguong) nhung mm
    // nho; chi tinh mm cua gio do.
    expect(
      NowcastCard.advice([
        _h(0, 1.0, 0.1, DataSource.observed),
        _h(1, 0.1, 0, DataSource.ai),
      ]),
      contains('chưa cần áo mưa'),
    );
    expect(
      NowcastCard.advice([
        _h(0, 0.0, 0, DataSource.observed),
        _h(1, 0.7, 0, DataSource.ai),
      ]),
      startsWith('Mưa khá chắc'),
    );
  });
}
