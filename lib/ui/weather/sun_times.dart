/// Tinh gio mat troi moc / lan theo thuat toan NOAA (Dart thuan, khong mang).
///
/// Do chinh xac ~1 phut voi vi do thap (Viet Nam). Gio tra ve theo quy uoc
/// cua app: "gio dong ho" cua dia phuong luu trong DateTime voi isUtc = true
/// (xem `HcmTime` trong lib/models/hcm_time.dart). Khong goi DateTime.now()
/// hay toLocal() o day.
library;

import 'dart:math' as math;

/// Gio mat troi moc / lan cua mot ngay.
class SunTimes {
  const SunTimes({
    required this.sunrise,
    required this.sunset,
    required this.solarNoon,
    this.isPolarDay = false,
    this.isPolarNight = false,
  });

  /// Mat troi moc (gio dong ho dia phuong, isUtc = true).
  final DateTime sunrise;

  /// Mat troi lan (gio dong ho dia phuong, isUtc = true).
  final DateTime sunset;

  /// Chinh ngo mat troi (gio dong ho dia phuong, isUtc = true).
  final DateTime solarNoon;

  /// Mat troi khong lan ca ngay (vung cuc). Khi do sunrise = sunset = solarNoon.
  final bool isPolarDay;

  /// Mat troi khong moc ca ngay (vung cuc). Khi do sunrise = sunset = solarNoon.
  final bool isPolarNight;

  /// Do dai ban ngay.
  Duration get dayLength => sunset.difference(sunrise);

  /// Tinh cho ngay cua [dateHcm] (chi dung year/month/day) tai [lat], [lon]
  /// (do, kinh do Dong duong). [utcOffsetHours]: mui gio cua gio dong ho tra
  /// ve (TP.HCM = 7).
  factory SunTimes.forDate(
    DateTime dateHcm, {
    required double lat,
    required double lon,
    double utcOffsetHours = 7,
  }) {
    final double jd = _julianDay(dateHcm.year, dateHcm.month, dateHcm.day);
    final double offsetMin = utcOffsetHours * 60;

    final double noonUtc = _solarNoonUtc(jd, lon);
    final DateTime noon = _wallClock(dateHcm, noonUtc + offsetMin);

    final double? riseUtc = _riseSetUtc(true, jd, lat, lon);
    final double? setUtc = _riseSetUtc(false, jd, lat, lon);
    if (riseUtc == null || setUtc == null) {
      // Vung cuc: xac dinh ngay hay dem theo do cao mat troi luc chinh ngo.
      final double t = _julianCentury(jd + noonUtc / 1440);
      final double decl = _sunDeclination(t);
      final double altitude = 90 - (lat - decl).abs();
      final bool polarDay = altitude > 0;
      return SunTimes(
        sunrise: noon,
        sunset: noon,
        solarNoon: noon,
        isPolarDay: polarDay,
        isPolarNight: !polarDay,
      );
    }
    return SunTimes(
      sunrise: _wallClock(dateHcm, riseUtc + offsetMin),
      sunset: _wallClock(dateHcm, setUtc + offsetMin),
      solarNoon: noon,
    );
  }

  /// [nowHcm] (gio dong ho dia phuong) co nam giua luc moc (tinh ca phut moc)
  /// va luc lan (khong tinh) hay khong.
  static bool isDaytime(
    DateTime nowHcm, {
    required double lat,
    required double lon,
    double utcOffsetHours = 7,
  }) {
    final SunTimes s = SunTimes.forDate(
      nowHcm,
      lat: lat,
      lon: lon,
      utcOffsetHours: utcOffsetHours,
    );
    if (s.isPolarDay) return true;
    if (s.isPolarNight) return false;
    return !nowHcm.isBefore(s.sunrise) && nowHcm.isBefore(s.sunset);
  }

  @override
  String toString() => 'SunTimes(sunrise: $sunrise, sunset: $sunset)';
}

/// Ham tien loi, tuong duong [SunTimes.isDaytime].
bool isDaytime(
  DateTime nowHcm, {
  required double lat,
  required double lon,
  double utcOffsetHours = 7,
}) => SunTimes.isDaytime(
  nowHcm,
  lat: lat,
  lon: lon,
  utcOffsetHours: utcOffsetHours,
);

// ---------------------------------------------------------------------------
// NOAA Solar Calculator (https://gml.noaa.gov/grad/solcalc/), rut gon.

DateTime _wallClock(DateTime date, double minutesFromMidnight) {
  final int ms = (minutesFromMidnight * 60000).round();
  return DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).add(Duration(milliseconds: ms));
}

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// Ngay Julius luc 0h UT.
double _julianDay(int year, int month, int day) {
  int y = year;
  int m = month;
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  final int a = (y / 100).floor();
  final int b = 2 - a + (a / 4).floor();
  return (365.25 * (y + 4716)).floorToDouble() +
      (30.6001 * (m + 1)).floorToDouble() +
      day +
      b -
      1524.5;
}

double _julianCentury(double jd) => (jd - 2451545.0) / 36525.0;

double _geomMeanLongSun(double t) {
  double l0 = 280.46646 + t * (36000.76983 + t * 0.0003032);
  l0 %= 360;
  if (l0 < 0) l0 += 360;
  return l0;
}

double _geomMeanAnomalySun(double t) =>
    357.52911 + t * (35999.05029 - 0.0001537 * t);

double _eccentricityEarthOrbit(double t) =>
    0.016708634 - t * (0.000042037 + 0.0000001267 * t);

double _sunEqOfCenter(double t) {
  final double m = _rad(_geomMeanAnomalySun(t));
  return math.sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
      math.sin(2 * m) * (0.019993 - 0.000101 * t) +
      math.sin(3 * m) * 0.000289;
}

double _sunApparentLong(double t) {
  final double trueLong = _geomMeanLongSun(t) + _sunEqOfCenter(t);
  final double omega = 125.04 - 1934.136 * t;
  return trueLong - 0.00569 - 0.00478 * math.sin(_rad(omega));
}

double _obliquityCorrection(double t) {
  final double seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813));
  final double e0 = 23 + (26 + seconds / 60) / 60;
  final double omega = 125.04 - 1934.136 * t;
  return e0 + 0.00256 * math.cos(_rad(omega));
}

double _sunDeclination(double t) {
  final double e = _rad(_obliquityCorrection(t));
  final double lambda = _rad(_sunApparentLong(t));
  return _deg(math.asin(math.sin(e) * math.sin(lambda)));
}

/// Phuong trinh thoi gian (phut).
double _equationOfTime(double t) {
  final double e = _obliquityCorrection(t);
  final double l0 = _rad(_geomMeanLongSun(t));
  final double ecc = _eccentricityEarthOrbit(t);
  final double m = _rad(_geomMeanAnomalySun(t));
  double y = math.tan(_rad(e) / 2);
  y *= y;
  final double eTime =
      y * math.sin(2 * l0) -
      2 * ecc * math.sin(m) +
      4 * ecc * y * math.sin(m) * math.cos(2 * l0) -
      0.5 * y * y * math.sin(4 * l0) -
      1.25 * ecc * ecc * math.sin(2 * m);
  return _deg(eTime) * 4;
}

/// Goc gio luc moc (rad), null neu khong moc/lan (vung cuc).
double? _hourAngleSunrise(double lat, double decl) {
  final double latR = _rad(lat);
  final double declR = _rad(decl);
  final double cosHa =
      math.cos(_rad(90.833)) / (math.cos(latR) * math.cos(declR)) -
      math.tan(latR) * math.tan(declR);
  if (cosHa < -1 || cosHa > 1) return null;
  return math.acos(cosHa);
}

double _solarNoonUtc(double jd, double lon) {
  // Hai buoc lap de chinh phuong trinh thoi gian theo dung thoi diem.
  double noon = 720 - 4 * lon - _equationOfTime(_julianCentury(jd - lon / 360));
  noon = 720 - 4 * lon - _equationOfTime(_julianCentury(jd + noon / 1440));
  return noon;
}

double? _riseSetOnce(bool rise, double jd, double lat, double lon) {
  final double t = _julianCentury(jd);
  final double eqTime = _equationOfTime(t);
  final double decl = _sunDeclination(t);
  final double? ha = _hourAngleSunrise(lat, decl);
  if (ha == null) return null;
  final double hourAngle = rise ? ha : -ha;
  final double delta = lon + _deg(hourAngle);
  return 720 - 4 * delta - eqTime;
}

/// Phut UTC tinh tu 0h UT cua ngay [jd] (co the am hoac > 1440).
double? _riseSetUtc(bool rise, double jd, double lat, double lon) {
  final double? first = _riseSetOnce(rise, jd, lat, lon);
  if (first == null) return null;
  return _riseSetOnce(rise, jd + first / 1440, lat, lon);
}
