import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/units.dart';

void main() {
  group('Beaufort (km/h)', () {
    // (km/h, cap) tai cac moc bien WMO.
    const cases = <(double, int)>[
      (0, 0),
      (0.9, 0),
      (1, 1),
      (5.9, 1),
      (6, 2),
      (11.9, 2),
      (12, 3),
      (19.9, 3),
      (20, 4),
      (28.9, 4),
      (29, 5),
      (38.9, 5),
      (39, 6),
      (49.9, 6),
      (50, 7),
      (61.9, 7),
      (62, 8),
      (74.9, 8),
      (75, 9),
      (88.9, 9),
      (89, 10),
      (102.9, 10),
      (103, 11),
      (117.9, 11),
      (118, 12),
      (250, 12),
    ];
    for (final (kmh, level) in cases) {
      test('$kmh km/h -> cap $level', () {
        expect(UnitConvert.beaufort(kmh), level);
      });
    }
    test('ten cap', () {
      expect(UnitConvert.beaufortName(0), 'Lặng gió');
      expect(UnitConvert.beaufortName(12), 'Bão rất mạnh');
      expect(UnitConvert.beaufortName(99), 'Bão rất mạnh');
    });
  });

  group('Gio', () {
    test('cac don vi', () {
      expect(const UnitPrefs().windText(11.8), '12 km/h');
      expect(const UnitPrefs(wind: WindUnit.ms).windText(11.8), '3,3 m/s');
      expect(const UnitPrefs(wind: WindUnit.ms).windText(72), '20 m/s');
      expect(const UnitPrefs(wind: WindUnit.mph).windText(16.09344), '10 mph');
      expect(const UnitPrefs(wind: WindUnit.beaufort).windText(25), 'Cấp 4');
      expect(const UnitPrefs().windText(null), '--');
    });
    test('tach gia tri / don vi', () {
      final p = const UnitPrefs(wind: WindUnit.beaufort).windParts(40);
      expect(p.value, 'Cấp 6');
      expect(p.unit, isNull);
      final k = const UnitPrefs().windParts(40);
      expect((k.value, k.unit), ('40', 'km/h'));
    });
  });

  test('Ap suat', () {
    expect(const UnitPrefs().pressureText(1011.3), '1011 hPa');
    expect(
      const UnitPrefs(pressure: PressureUnit.mmhg).pressureText(1013.25),
      '760 mmHg',
    );
    expect(
      const UnitPrefs(pressure: PressureUnit.inhg).pressureText(1013.25),
      '29,92 inHg',
    );
    expect(const UnitPrefs().pressureText(null), '--');
  });

  test('Luong mua', () {
    const mm = UnitPrefs();
    expect(mm.rainText(0), '0 mm');
    expect(mm.rainText(0.01), '< 0,1 mm');
    expect(mm.rainText(0.4), '0,4 mm');
    expect(mm.rainText(13.49), '13 mm');
    const inch = UnitPrefs(precip: PrecipUnit.inch);
    expect(inch.rainText(0), '0 in');
    expect(inch.rainText(0.1), '< 0,01 in');
    expect(inch.rainText(25.4), '1,00 in');
    expect(inch.rainText(12.6), '0,50 in');
    expect(mm.rainRateText(10), '10,0 mm/h');
    expect(inch.rainRateText(25.4), '1,00 in/h');
  });

  test('Khoang cach', () {
    expect(const UnitPrefs().distanceText(16.96), '17 km');
    expect(const UnitPrefs().distanceText(4.25), '4,3 km');
    expect(
      const UnitPrefs(distance: DistanceUnit.mi).distanceText(16.09344),
      '10 mi',
    );
    expect(
      const UnitPrefs(distance: DistanceUnit.mi).distanceText(8.04672),
      '5,0 mi',
    );
  });

  test('JSON: khu hoi va gia tri sai -> mac dinh', () {
    const u = UnitPrefs(
      wind: WindUnit.beaufort,
      pressure: PressureUnit.inhg,
      precip: PrecipUnit.inch,
      distance: DistanceUnit.mi,
    );
    expect(UnitPrefs.fromJson(u.toJson()), u);
    expect(
      UnitPrefs.fromJson({'wind': 'knots', 'pressure': 3}),
      const UnitPrefs(),
    );
    expect(UnitPrefs.fromJson(null), const UnitPrefs());
  });
}
