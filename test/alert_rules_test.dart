import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';

/// Gio TP.HCM "hien tai" cua test (12:20).
final DateTime _now = DateTime.utc(2026, 10, 16, 12, 20);
final DateTime _base = DateTime.utc(2026, 10, 16, 12);

HourlyForecast _h(
  int offset, {
  double temp = 28,
  double? prob = 0.1,
  double? mm,
  double? uv,
  int? aqi,
  double? gust,
  int? code = 3,
  double? humidity,
  double? feels,
  DataSource? source = DataSource.forecast,
}) => HourlyForecast(
  time: _base.add(Duration(hours: offset)),
  temperature: temp,
  condition: conditionFromWmo(code),
  rainProbability: prob,
  precipitationMm: mm,
  uvIndex: uv,
  usAqi: aqi,
  windGusts: gust,
  weatherCode: code,
  humidity: humidity,
  apparentTemperature: feels,
  source: source,
);

const _s = AlertSettings();

void main() {
  group('evaluateHour - nguong va muc do', () {
    test('mua: duoi / dung / tren nguong', () {
      expect(evaluateHour(AlertType.rain, _h(0, prob: 0.69), _s), isNull);
      expect(
        evaluateHour(AlertType.rain, _h(0, prob: 0.70), _s)!.level,
        AlertLevel.advisory,
      );
      expect(
        evaluateHour(AlertType.rain, _h(0, prob: 0.9), _s)!.level,
        AlertLevel.warning,
      );
      expect(evaluateHour(AlertType.rain, _h(0, prob: null), _s), isNull);
    });

    test('mua: gio thuc te dung luong mua, bo qua xac suat 0/1', () {
      final obs = _h(0, prob: 1, mm: 0.2, source: DataSource.observed);
      expect(evaluateHour(AlertType.rain, obs, _s), isNull);
      final wet = _h(0, prob: 1, mm: 2, source: DataSource.observed);
      expect(evaluateHour(AlertType.rain, wet, _s)!.value, 2);
    });

    test('mua lon: 10 mm canh bao, 20 mm nguy hiem, null bo qua', () {
      expect(evaluateHour(AlertType.heavyRain, _h(0, mm: 9.9), _s), isNull);
      expect(
        evaluateHour(AlertType.heavyRain, _h(0, mm: 10), _s)!.level,
        AlertLevel.warning,
      );
      expect(
        evaluateHour(AlertType.heavyRain, _h(0, mm: 20), _s)!.level,
        AlertLevel.danger,
      );
      expect(evaluateHour(AlertType.heavyRain, _h(0, mm: null), _s), isNull);
    });

    test('dong: WMO 95-99; 96/99 kem mua da', () {
      for (final c in [94, 100]) {
        expect(
          evaluateHour(AlertType.thunderstorm, _h(0, code: c), _s),
          isNull,
        );
      }
      expect(
        evaluateHour(AlertType.thunderstorm, _h(0, code: 95), _s)!.level,
        AlertLevel.warning,
      );
      expect(
        evaluateHour(AlertType.thunderstorm, _h(0, code: 99), _s)!.level,
        AlertLevel.danger,
      );
      expect(
        evaluateHour(AlertType.thunderstorm, _h(0, code: null), _s),
        isNull,
      );
    });

    test('nang nong: nhiet do 35 / 39, chi so nhiet', () {
      expect(evaluateHour(AlertType.heat, _h(0, temp: 34.9), _s), isNull);
      expect(
        evaluateHour(AlertType.heat, _h(0, temp: 35), _s)!.level,
        AlertLevel.warning,
      );
      expect(
        evaluateHour(AlertType.heat, _h(0, temp: 39), _s)!.level,
        AlertLevel.danger,
      );
      // 33 °C, am 70 % -> chi so nhiet ~ 41-42 °C.
      final hi = evaluateHour(
        AlertType.heat,
        _h(0, temp: 33, humidity: 70),
        _s,
      );
      expect(hi, isNotNull);
      expect(hi!.value, greaterThanOrEqualTo(41));
      // Co apparent_temperature -> dung truc tiep.
      expect(
        evaluateHour(AlertType.heat, _h(0, temp: 30, feels: 40.9), _s),
        isNull,
      );
      expect(
        evaluateHour(AlertType.heat, _h(0, temp: 30, feels: 47), _s)!.level,
        AlertLevel.warning,
      );
    });

    test('UV / gio giat / AQI', () {
      expect(evaluateHour(AlertType.uv, _h(0, uv: 7.9), _s), isNull);
      expect(
        evaluateHour(AlertType.uv, _h(0, uv: 8), _s)!.level,
        AlertLevel.warning,
      );
      expect(
        evaluateHour(AlertType.uv, _h(0, uv: 11), _s)!.level,
        AlertLevel.danger,
      );
      expect(evaluateHour(AlertType.uv, _h(0, uv: null), _s), isNull);
      expect(evaluateHour(AlertType.wind, _h(0, gust: 49), _s), isNull);
      expect(
        evaluateHour(AlertType.wind, _h(0, gust: 75), _s)!.level,
        AlertLevel.danger,
      );
      expect(evaluateHour(AlertType.aqi, _h(0, aqi: 150), _s), isNull);
      expect(
        evaluateHour(AlertType.aqi, _h(0, aqi: 151), _s)!.level,
        AlertLevel.warning,
      );
      expect(
        evaluateHour(AlertType.aqi, _h(0, aqi: 201), _s)!.level,
        AlertLevel.danger,
      );
      // Ha nguong AQI -> 101-150 la "Lưu ý".
      expect(
        evaluateHour(
          AlertType.aqi,
          _h(0, aqi: 120),
          _s.copyWith(aqi: 101),
        )!.level,
        AlertLevel.advisory,
      );
    });

    test('tat loai -> khong danh gia', () {
      final off = _s.withEnabled(AlertType.uv, false);
      expect(evaluateHour(AlertType.uv, _h(0, uv: 12), off), isNull);
    });
  });

  group('evaluateAlerts', () {
    test('gom gio lien tiep, muc va dinh lon nhat', () {
      final hours = [
        _h(0),
        _h(1, uv: 9),
        _h(2, uv: 11.5),
        _h(3, uv: 9),
        _h(4),
        _h(5, uv: 8.5),
      ];
      final ev = evaluateAlerts(hours, nowHcm: _now, placeId: 'p');
      final uv = ev.where((e) => e.type == AlertType.uv).toList();
      expect(uv, hasLength(2));
      expect(uv.first.level, AlertLevel.danger);
      expect(uv.first.start, _base.add(const Duration(hours: 1)));
      expect(uv.first.end, _base.add(const Duration(hours: 4)));
      expect(uv.first.peak, 11.5);
      expect(uv.first.title, 'UV cao · 13:00\u2060–\u206016:00');
    });

    test(
      'bo qua gio da qua, ngoai khung, climatology; ho du lieu ngat khoang',
      () {
        final hours = [
          _h(-1, uv: 12),
          _h(1, uv: 9, source: DataSource.climatology),
          _h(2, uv: 9),
          _h(4, uv: 9), // gio 3 thieu
          _h(30, uv: 9), // ngoai 24 gio
        ];
        final ev = evaluateAlerts(hours, nowHcm: _now, placeId: 'p');
        expect(ev.map((e) => e.start.hour), [14, 16]);
      },
    );

    test('rong / toan null -> khong co canh bao', () {
      expect(evaluateAlerts(const [], nowHcm: _now, placeId: 'p'), isEmpty);
      final nulls = [
        for (var i = 0; i < 5; i++) _h(i, prob: null, code: null, temp: 28),
      ];
      expect(evaluateAlerts(nulls, nowHcm: _now, placeId: 'p'), isEmpty);
    });

    test('sap xep muc cao truoc; danh dau dang xay ra', () {
      final ev = evaluateAlerts(
        [_h(0, mm: 3, prob: 1, source: DataSource.observed), _h(1, code: 99)],
        nowHcm: _now,
        placeId: 'p',
      );
      expect(ev.first.type, AlertType.thunderstorm);
      final rain = ev.firstWhere((e) => e.type == AlertType.rain);
      expect(rain.observed, isTrue);
      expect(rain.detail, contains('Đang xảy ra'));
    });

    test(
      'theo nowHcm (xem lai): gio "qua khu" so voi dong ho that van tinh',
      () {
        final replayNow = DateTime.utc(2020, 1, 1, 9);
        final h = HourlyForecast(
          time: DateTime.utc(2020, 1, 1, 10),
          temperature: 28,
          condition: WeatherCondition.sunny,
          uvIndex: 10,
        );
        expect(
          evaluateAlerts([h], nowHcm: replayNow, placeId: 'p'),
          hasLength(1),
        );
      },
    );
  });

  group('planNotices - chong trung', () {
    List<AlertEvent> events(double gust, {int from = 2}) => evaluateAlerts(
      [for (var i = from; i < from + 3; i++) _h(i, gust: gust)],
      nowHcm: _now,
      placeId: 'p',
    );

    test('cung loai + dia diem + khung giao nhau -> khong lap', () {
      final first = planNotices(
        events(55),
        history: const [],
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices;
      expect(first, hasLength(1));
      // Danh gia lai, khung lech 1 gio -> van trung.
      final again = planNotices(
        events(55, from: 3),
        history: first,
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices;
      expect(again, isEmpty);
    });

    test('muc do tang -> thong bao cap nhat', () {
      final first = planNotices(
        events(55),
        history: const [],
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices;
      final up = planNotices(
        events(80),
        history: first,
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices;
      expect(up, hasLength(1));
      expect(up.single.updated, isTrue);
      expect(up.single.title, startsWith('Cập nhật: Nguy hiểm'));
    });

    test('dia diem khac -> thong bao rieng', () {
      final first = planNotices(
        events(55),
        history: const [],
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices;
      final other = evaluateAlerts(
        [for (var i = 2; i < 5; i++) _h(i, gust: 55)],
        nowHcm: _now,
        placeId: 'q',
      );
      expect(
        planNotices(
          other,
          history: first,
          settings: _s,
          nowHcm: _now,
          placeName: 'Q3',
        ).notices,
        hasLength(1),
      );
    });

    test('duoi muc uu tien -> khong thong bao', () {
      final adv = evaluateAlerts(
        [_h(1, prob: 0.75)],
        nowHcm: _now,
        placeId: 'p',
      );
      expect(adv.single.level, AlertLevel.advisory);
      expect(
        planNotices(
          adv,
          history: const [],
          settings: _s,
          nowHcm: _now,
          placeName: 'Q1',
        ).notices,
        isEmpty,
      );
    });

    test('gio yen lang giu canh bao, tru muc Nguy hiem', () {
      final night = DateTime.utc(2026, 10, 16, 23, 10);
      List<AlertEvent> at(double gust) => evaluateAlerts(
        [_h(11, gust: gust)],
        nowHcm: night,
        placeId: 'p',
      );
      final held = planNotices(
        at(55),
        history: const [],
        settings: _s,
        nowHcm: night,
        placeName: 'Q1',
      );
      expect(held.notices, isEmpty);
      expect(held.held, 1);
      expect(
        planNotices(
          at(90),
          history: const [],
          settings: _s,
          nowHcm: night,
          placeName: 'Q1',
        ).notices,
        hasLength(1),
      );
    });
  });

  group('AlertSettings', () {
    test('gio yen lang qua nua dem va trong ngay', () {
      expect(_s.inQuietHours(DateTime.utc(2026, 1, 1, 23)), isTrue);
      expect(_s.inQuietHours(DateTime.utc(2026, 1, 1, 5, 59)), isTrue);
      expect(_s.inQuietHours(DateTime.utc(2026, 1, 1, 6)), isFalse);
      final day = _s.copyWith(quietStart: 12, quietEnd: 14);
      expect(day.inQuietHours(DateTime.utc(2026, 1, 1, 13)), isTrue);
      expect(day.inQuietHours(DateTime.utc(2026, 1, 1, 14)), isFalse);
      expect(
        _s
            .copyWith(quietEnabled: false)
            .inQuietHours(DateTime.utc(2026, 1, 1, 23)),
        isFalse,
      );
    });

    test('JSON di/ve; du lieu hong -> mac dinh', () {
      final s = _s
          .withThreshold(AlertType.uv, 6)
          .withEnabled(AlertType.aqi, false)
          .copyWith(minNotifyLevel: AlertLevel.danger);
      final back = AlertSettings.fromJson(s.toJson());
      expect(back.uvIndex, 6);
      expect(back.isEnabled(AlertType.aqi), isFalse);
      expect(back.minNotifyLevel, AlertLevel.danger);
      final bad = AlertSettings.fromJson({
        'uvIndex': 'x',
        'quietStart': 99,
        'enabled': 3,
      });
      expect(bad.uvIndex, 8);
      expect(bad.quietStart, 22);
      expect(bad.isEnabled(AlertType.rain), isTrue);
    });

    test('AlertNotice JSON; hong -> null', () {
      final n = planNotices(
        evaluateAlerts([_h(1, gust: 60)], nowHcm: _now, placeId: 'p'),
        history: const [],
        settings: _s,
        nowHcm: _now,
        placeName: 'Q1',
      ).notices.single;
      final back = AlertNotice.tryFromJson(n.toJson())!;
      expect(back.title, n.title);
      expect(back.start, n.start);
      expect(AlertNotice.tryFromJson({'type': 'x'}), isNull);
      expect(AlertNotice.tryFromJson(null), isNull);
    });
  });

  test('heatIndexC: duoi 27 °C giu nguyen; tang theo do am', () {
    expect(heatIndexC(25, 90), 25);
    expect(heatIndexC(32, 30), 32);
    expect(heatIndexC(32, 80), greaterThan(heatIndexC(32, 50)));
  });

  test('mien tru nhac Dai KTTV Nam Bo', () {
    expect(kAlertDisclaimer, contains('không phải cảnh báo chính thức'));
    expect(kAlertDisclaimer, contains('Đài KTTV khu vực Nam Bộ'));
  });
}
