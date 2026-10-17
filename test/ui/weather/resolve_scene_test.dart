import 'package:flutter_test/flutter_test.dart';
import 'package:sky_weather_app/ui/weather/weather_scene.dart';

void main() {
  // Bang mong doi (ngay, dem) cho moi ma WMO ma Open-Meteo tra ve.
  const Map<int, (WeatherScene, WeatherScene)> table = {
    0: (WeatherScene.clearDay, WeatherScene.clearNight),
    1: (WeatherScene.clearDay, WeatherScene.clearNight),
    2: (WeatherScene.partlyCloudyDay, WeatherScene.partlyCloudyNight),
    3: (WeatherScene.cloudy, WeatherScene.cloudy),
    45: (WeatherScene.fog, WeatherScene.fog),
    48: (WeatherScene.fog, WeatherScene.fog),
    51: (WeatherScene.drizzle, WeatherScene.drizzle),
    53: (WeatherScene.drizzle, WeatherScene.drizzle),
    55: (WeatherScene.drizzle, WeatherScene.drizzle),
    56: (WeatherScene.sleet, WeatherScene.sleet),
    57: (WeatherScene.sleet, WeatherScene.sleet),
    61: (WeatherScene.rain, WeatherScene.rain),
    63: (WeatherScene.rain, WeatherScene.rain),
    65: (WeatherScene.heavyRain, WeatherScene.heavyRain),
    66: (WeatherScene.sleet, WeatherScene.sleet),
    67: (WeatherScene.sleet, WeatherScene.sleet),
    71: (WeatherScene.snow, WeatherScene.snow),
    73: (WeatherScene.snow, WeatherScene.snow),
    75: (WeatherScene.snow, WeatherScene.snow),
    77: (WeatherScene.snow, WeatherScene.snow),
    80: (WeatherScene.rain, WeatherScene.rain),
    81: (WeatherScene.rain, WeatherScene.rain),
    82: (WeatherScene.heavyRain, WeatherScene.heavyRain),
    85: (WeatherScene.snow, WeatherScene.snow),
    86: (WeatherScene.snow, WeatherScene.snow),
    95: (WeatherScene.thunderstorm, WeatherScene.thunderstorm),
    96: (WeatherScene.thunderstorm, WeatherScene.thunderstorm),
    99: (WeatherScene.thunderstorm, WeatherScene.thunderstorm),
  };

  group('moi ma WMO x ngay/dem', () {
    table.forEach((code, expected) {
      test('ma $code', () {
        expect(resolveScene(weatherCode: code, isDay: true), expected.$1);
        expect(resolveScene(weatherCode: code, isDay: false), expected.$2);
      });
    });
  });

  group('ma 3: cloudy / overcast', () {
    test('may < 90 -> cloudy', () {
      expect(
        resolveScene(weatherCode: 3, isDay: true, cloudCover: 89.9),
        WeatherScene.cloudy,
      );
    });
    test('may >= 90 -> overcast', () {
      expect(
        resolveScene(weatherCode: 3, isDay: true, cloudCover: 90),
        WeatherScene.overcast,
      );
      expect(
        resolveScene(weatherCode: 3, isDay: false, cloudCover: 100),
        WeatherScene.overcast,
      );
    });
  });

  group('haze', () {
    for (final int code in [0, 1, 2, 3]) {
      test('ma $code tam nhin < 5000 m -> haze', () {
        expect(
          resolveScene(weatherCode: code, isDay: true, visibilityMeters: 4999),
          WeatherScene.haze,
        );
        expect(
          resolveScene(weatherCode: code, isDay: false, visibilityMeters: 1200),
          WeatherScene.haze,
        );
      });
    }
    test('dung 5000 m -> khong haze', () {
      expect(
        resolveScene(weatherCode: 0, isDay: true, visibilityMeters: 5000),
        WeatherScene.clearDay,
      );
    });
    test('mua / suong khong bi haze ghi de', () {
      expect(
        resolveScene(weatherCode: 61, isDay: true, visibilityMeters: 800),
        WeatherScene.rain,
      );
      expect(
        resolveScene(weatherCode: 45, isDay: true, visibilityMeters: 200),
        WeatherScene.fog,
      );
    });
  });

  group('windy', () {
    test('nguong 39 km/h', () {
      expect(
        resolveScene(weatherCode: 1, isDay: true, windSpeedKmh: 38.9),
        WeatherScene.clearDay,
      );
      expect(
        resolveScene(weatherCode: 1, isDay: true, windSpeedKmh: 39),
        WeatherScene.windy,
      );
      expect(
        resolveScene(
          weatherCode: 3,
          isDay: false,
          windSpeedKmh: 60,
          cloudCover: 95,
        ),
        WeatherScene.windy,
      );
    });
    test('windy thang haze', () {
      expect(
        resolveScene(
          weatherCode: 2,
          isDay: true,
          windSpeedKmh: 45,
          visibilityMeters: 3000,
        ),
        WeatherScene.windy,
      );
    });
    test('mua, dong, tuyet, suong khong bi gio ghi de', () {
      for (final int code in [45, 48, 51, 56, 61, 65, 71, 82, 95, 99]) {
        final WeatherScene s = resolveScene(
          weatherCode: code,
          isDay: true,
          windSpeedKmh: 80,
          visibilityMeters: 100,
        );
        expect(s, isNot(WeatherScene.windy), reason: 'ma $code');
        expect(s, table[code]!.$1, reason: 'ma $code');
      }
    });
  });

  group('null / ma la', () {
    test('null code, null cloudCover -> cloudy', () {
      expect(resolveScene(weatherCode: null, isDay: true), WeatherScene.cloudy);
      expect(
        resolveScene(weatherCode: null, isDay: false),
        WeatherScene.cloudy,
      );
    });
    test('null code theo cloudCover', () {
      expect(
        resolveScene(weatherCode: null, isDay: true, cloudCover: 5),
        WeatherScene.clearDay,
      );
      expect(
        resolveScene(weatherCode: null, isDay: false, cloudCover: 19),
        WeatherScene.clearNight,
      );
      expect(
        resolveScene(weatherCode: null, isDay: true, cloudCover: 20),
        WeatherScene.partlyCloudyDay,
      );
      expect(
        resolveScene(weatherCode: null, isDay: false, cloudCover: 59),
        WeatherScene.partlyCloudyNight,
      );
      expect(
        resolveScene(weatherCode: null, isDay: true, cloudCover: 60),
        WeatherScene.cloudy,
      );
      expect(
        resolveScene(weatherCode: null, isDay: true, cloudCover: 90),
        WeatherScene.overcast,
      );
    });
    test('null code van ap dung haze / windy', () {
      expect(
        resolveScene(weatherCode: null, isDay: true, visibilityMeters: 2000),
        WeatherScene.haze,
      );
      expect(
        resolveScene(weatherCode: null, isDay: true, windSpeedKmh: 50),
        WeatherScene.windy,
      );
    });
    test('ma ngoai bang -> fallback nhu null', () {
      expect(resolveScene(weatherCode: 4, isDay: true), WeatherScene.cloudy);
      expect(
        resolveScene(weatherCode: 100, isDay: true, cloudCover: 10),
        WeatherScene.clearDay,
      );
    });
  });

  test('withDaytime chi doi cap ngay/dem', () {
    expect(WeatherScene.clearDay.withDaytime(false), WeatherScene.clearNight);
    expect(
      WeatherScene.partlyCloudyNight.withDaytime(true),
      WeatherScene.partlyCloudyDay,
    );
    expect(WeatherScene.rain.withDaytime(false), WeatherScene.rain);
  });

  test('moi canh co nhan tieng Viet', () {
    for (final WeatherScene s in WeatherScene.values) {
      expect(s.label, isNotEmpty);
    }
  });
}
