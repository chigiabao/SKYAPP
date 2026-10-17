/// Don vi hien thi (thuan Dart, khong phu thuoc Flutter).
///
/// Du lieu goc luon la km/h, hPa, mm, km; nguong canh bao tinh tren don vi
/// goc. Lop nay CHI doi phan hien thi. Dau thap phan kieu Viet Nam (phay).
library;

enum WindUnit {
  kmh('km/h'),
  ms('m/s'),
  mph('mph'),
  beaufort('Beaufort');

  const WindUnit(this.label);
  final String label;
}

enum PressureUnit {
  hpa('hPa'),
  mmhg('mmHg'),
  inhg('inHg');

  const PressureUnit(this.label);
  final String label;
}

enum PrecipUnit {
  mm('mm'),
  inch('inch');

  const PrecipUnit(this.label);
  final String label;
}

enum DistanceUnit {
  km('km'),
  mi('mi');

  const DistanceUnit(this.label);
  final String label;
}

/// Gia tri + don vi tach rieng (cho o so lon + don vi nho).
typedef UnitParts = ({String value, String? unit});

abstract final class UnitConvert {
  static double kmhToMs(double kmh) => kmh / 3.6;
  static double kmhToMph(double kmh) => kmh / 1.609344;
  static double hpaToMmHg(double hpa) => hpa * 0.750061683;
  static double hpaToInHg(double hpa) => hpa * 0.0295299831;
  static double mmToInch(double mm) => mm / 25.4;
  static double kmToMi(double km) => km / 1.609344;

  /// Can tren (km/h, khong gom) cua cap 0..11 theo bang WMO; >= 118 -> 12.
  static const List<double> beaufortUpperKmh = [
    1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118, //
  ];

  /// Cap Beaufort 0..12 tu km/h.
  static int beaufort(double kmh) {
    for (var i = 0; i < beaufortUpperKmh.length; i++) {
      if (kmh < beaufortUpperKmh[i]) return i;
    }
    return 12;
  }

  /// Ten cap gio tieng Viet.
  static String beaufortName(int level) => const [
    'Lặng gió',
    'Gió rất nhẹ',
    'Gió nhẹ',
    'Gió yếu',
    'Gió vừa',
    'Gió khá mạnh',
    'Gió mạnh',
    'Gió to',
    'Gió rất to',
    'Gió bão',
    'Bão',
    'Bão mạnh',
    'Bão rất mạnh',
  ][level.clamp(0, 12)];
}

/// Lua chon don vi cua nguoi dung + ham dinh dang chung.
class UnitPrefs {
  const UnitPrefs({
    this.wind = WindUnit.kmh,
    this.pressure = PressureUnit.hpa,
    this.precip = PrecipUnit.mm,
    this.distance = DistanceUnit.km,
  });

  final WindUnit wind;
  final PressureUnit pressure;
  final PrecipUnit precip;
  final DistanceUnit distance;

  static const String noData = '--';

  UnitPrefs copyWith({
    WindUnit? wind,
    PressureUnit? pressure,
    PrecipUnit? precip,
    DistanceUnit? distance,
  }) => UnitPrefs(
    wind: wind ?? this.wind,
    pressure: pressure ?? this.pressure,
    precip: precip ?? this.precip,
    distance: distance ?? this.distance,
  );

  // ---- Gio ----

  /// Gia tri + don vi; Beaufort -> ("Cấp 3", null).
  UnitParts windParts(double kmh) {
    switch (wind) {
      case WindUnit.kmh:
        return (value: '${kmh.round()}', unit: 'km/h');
      case WindUnit.ms:
        final ms = UnitConvert.kmhToMs(kmh);
        return (value: ms < 10 ? _dec(ms, 1) : '${ms.round()}', unit: 'm/s');
      case WindUnit.mph:
        return (value: '${UnitConvert.kmhToMph(kmh).round()}', unit: 'mph');
      case WindUnit.beaufort:
        return (value: 'Cấp ${UnitConvert.beaufort(kmh)}', unit: null);
    }
  }

  /// "12 km/h", "3,3 m/s", "7 mph", "Cấp 3"; null -> "--".
  String windText(double? kmh) => kmh == null ? noData : _join(windParts(kmh));

  /// Don vi truc bieu do gio (Beaufort khong tuyen tinh -> ve theo m/s).
  WindUnit get windAxisUnit => wind == WindUnit.beaufort ? WindUnit.ms : wind;

  /// Gia tri ve tren truc theo [windAxisUnit].
  double windAxisValue(double kmh) => switch (windAxisUnit) {
    WindUnit.ms => UnitConvert.kmhToMs(kmh),
    WindUnit.mph => UnitConvert.kmhToMph(kmh),
    _ => kmh,
  };

  // ---- Ap suat ----

  UnitParts pressureParts(double hpa) {
    switch (pressure) {
      case PressureUnit.hpa:
        return (value: '${hpa.round()}', unit: 'hPa');
      case PressureUnit.mmhg:
        return (value: '${UnitConvert.hpaToMmHg(hpa).round()}', unit: 'mmHg');
      case PressureUnit.inhg:
        return (value: _dec(UnitConvert.hpaToInHg(hpa), 2), unit: 'inHg');
    }
  }

  String pressureText(double? hpa) =>
      hpa == null ? noData : _join(pressureParts(hpa));

  // ---- Luong mua ----

  /// mm: 0 -> "0 mm", vet (< 0,05) -> "< 0,1 mm", < 1 -> 1 so le, con lai so
  /// nguyen. inch: 0 -> "0 in", < 0,005 -> "< 0,01 in", 2 so le.
  String rainText(double? mm) {
    if (mm == null) return noData;
    if (precip == PrecipUnit.mm) {
      if (mm <= 0) return '0 mm';
      if (mm < 0.05) return '< 0,1 mm';
      final oneDecimal = (mm * 10).round() / 10;
      if (oneDecimal < 1) return '${_dec(oneDecimal, 1)} mm';
      return '${mm.round()} mm';
    }
    if (mm <= 0) return '0 in';
    final inch = UnitConvert.mmToInch(mm);
    if (inch < 0.005) return '< 0,01 in';
    return '${_dec(inch, 2)} in';
  }

  /// Don vi cuong do mua ("mm/h" | "in/h").
  String get rainRateUnit => precip == PrecipUnit.mm ? 'mm/h' : 'in/h';

  /// Cuong do mua: "12,5 mm/h" | "0,49 in/h".
  String rainRateText(double mmPerHour) => precip == PrecipUnit.mm
      ? '${_dec(mmPerHour, 1)} mm/h'
      : '${_dec(UnitConvert.mmToInch(mmPerHour), 2)} in/h';

  // ---- Khoang cach ----

  /// < 10 -> 1 so le, con lai so nguyen.
  String distanceText(double? km) {
    if (km == null) return noData;
    final v = distance == DistanceUnit.km ? km : UnitConvert.kmToMi(km);
    final u = distance.label;
    return v < 10 ? '${_dec(v, 1)} $u' : '${v.round()} $u';
  }

  // ---- Luu tru ----

  Map<String, dynamic> toJson() => {
    'wind': wind.name,
    'pressure': pressure.name,
    'precip': precip.name,
    'distance': distance.name,
  };

  factory UnitPrefs.fromJson(Map<String, dynamic>? json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final j = json ?? const {};
    return UnitPrefs(
      wind: pick(WindUnit.values, j['wind'], WindUnit.kmh),
      pressure: pick(PressureUnit.values, j['pressure'], PressureUnit.hpa),
      precip: pick(PrecipUnit.values, j['precip'], PrecipUnit.mm),
      distance: pick(DistanceUnit.values, j['distance'], DistanceUnit.km),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UnitPrefs &&
      other.wind == wind &&
      other.pressure == pressure &&
      other.precip == precip &&
      other.distance == distance;

  @override
  int get hashCode => Object.hash(wind, pressure, precip, distance);

  static String _join(UnitParts p) =>
      p.unit == null ? p.value : '${p.value} ${p.unit}';

  static String _dec(double v, int digits) =>
      v.toStringAsFixed(digits).replaceAll('.', ',');
}
