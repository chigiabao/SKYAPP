part of '../compare_screen.dart';

@immutable
class CompareSeriesStyle {
  const CompareSeriesStyle(this.color, this.dash, this.shape, this.shapeName);

  final Color color;

  /// null = net lien.
  final List<int>? dash;
  final CompareDotShape shape;

  /// Ten kieu (cho trinh doc man hinh / chu giai).
  final String shapeName;

  static const List<CompareSeriesStyle> all = [
    CompareSeriesStyle(
      DataColors.seriesA,
      null,
      CompareDotShape.circle,
      'nét liền',
    ),
    CompareSeriesStyle(
      DataColors.seriesB,
      [8, 5],
      CompareDotShape.square,
      'nét đứt',
    ),
    CompareSeriesStyle(
      DataColors.seriesC,
      [2, 4],
      CompareDotShape.triangle,
      'nét chấm',
    ),
  ];
}

enum CompareDotShape { circle, square, triangle }

/// Gio "co mua" theo CUNG mot quy tac cho cot va cau ket luan: gio thuc te
/// (so lieu phan tich, vd. che do xem lai) -> luong mua >= 0,1 mm; gio du
/// bao -> kha nang mua >= 50%.
bool compareHourIsRainy(HourlyForecast h) => h.isObserved
    ? (h.precipitationMm ?? 0) >= 0.1
    : (h.rainProbability ?? 0) >= 0.5;

/// Gio dau tien (trong 12 gio toi) co mua theo [compareHourIsRainy]; null =
/// khong co.
DateTime? rainOnset(List<HourlyForecast> hours, DateTime nowHcm) {
  final start = HcmTime.startOfHour(nowHcm);
  final end = start.add(const Duration(hours: 12));
  final sorted = [...hours]..sort((a, b) => a.time.compareTo(b.time));
  for (final h in sorted) {
    if (h.time.isBefore(start) || !h.time.isBefore(end)) continue;
    if (compareHourIsRainy(h)) return h.time;
  }
  return null;
}

/// O "Mưa 3 giờ tới" cua cot so sanh. [score] (0-100) dung de so noi mua
/// nhieu nhat; [note] giai thich nguon / ly do thieu.
typedef CompareRain = ({String value, String? note, int score});

CompareRain compareRain3h(
  List<HourlyForecast> hours,
  DateTime nowHcm,
  UnitPrefs units,
) {
  final p = rainNext3h(hours, nowHcm);
  if (p != null) return (value: '$p%', note: 'khả năng (dự báo)', score: p);
  final from = HcmTime.startOfHour(nowHcm);
  final to = from.add(const Duration(hours: 3));
  final observed = [
    for (final h in hours)
      if (h.isObserved && !h.time.isBefore(from) && h.time.isBefore(to)) h,
  ];
  if (observed.isNotEmpty) {
    final mm = observed.fold<double>(0, (a, h) => a + (h.precipitationMm ?? 0));
    final rainy = observed.any(compareHourIsRainy);
    return (
      value: rainy ? 'Có mưa' : 'Không mưa',
      note: rainy
          ? '${DataCopy.observedShort} · ${units.rainText(mm)}'
          : DataCopy.observedShort,
      score: rainy ? 100 : 0,
    );
  }
  return (value: 'Chưa có', note: 'chưa có số liệu theo giờ', score: 0);
}

/// Noi noi bat: mua nhieu nhat (3 gio toi) va nong nhat (hien tai).
typedef CompareHighlights = ({String? rainiestId, String? hottestId});

CompareHighlights compareHighlights(List<CompareSeries> s, DateTime now) {
  final ok = [
    for (final x in s)
      if (x.data != null) x,
  ];
  if (ok.length < 2) return (rainiestId: null, hottestId: null);
  // Chi noi bat khi hon han noi thu hai (tranh "nóng nhất" khi bang nhau).
  String? leader(num Function(CompareSeries) v, num margin, num floor) {
    final sorted = [...ok]..sort((a, b) => v(b).compareTo(v(a)));
    final a = v(sorted[0]), b = v(sorted[1]);
    return a >= floor && a - b >= margin ? sorted[0].place.id : null;
  }

  return (
    rainiestId: leader(
      (x) =>
          compareRain3h(x.data!.hourlyForecast, now, const UnitPrefs()).score,
      10,
      20,
    ),
    hottestId: leader((x) => x.data!.current.temperature, 1, -100),
  );
}

/// Mot cau ket luan, vd. "Thủ Đức mưa sớm hơn Bến Thành khoảng 1 giờ."
String? compareVerdict(
  List<CompareSeries> series,
  DateTime now,
  String Function(double c) temp,
) {
  final ok = [
    for (final x in series)
      if (x.data != null) x,
  ];
  if (ok.length < 2) return null;
  final onset = {for (final x in ok) x: rainOnset(x.data!.hourlyForecast, now)};
  final wet = ok.where((x) => onset[x] != null).toList()
    ..sort((a, b) => onset[a]!.compareTo(onset[b]!));
  String hh(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:00';
  // Gio bat dau mua la so lieu thuc te (vd. xem lai) -> noi ro nguon.
  String src(CompareSeries x) {
    final t = onset[x]!;
    final h = x.data!.hourlyForecast.where((h) => h.time == t).firstOrNull;
    return h != null && h.isObserved
        ? ' (theo ${DataCopy.observedInParens})'
        : '';
  }

  if (wet.length >= 2) {
    final a = wet.first, b = wet.last;
    final dh = onset[b]!.difference(onset[a]!).inHours;
    if (dh >= 1) {
      return '${a.place.name} mưa sớm hơn ${b.place.name} khoảng $dh giờ '
          '(từ ${hh(onset[a]!)})${src(a)}.';
    }
    return 'Các nơi cùng có thể mưa từ khoảng ${hh(onset[a]!)}${src(a)}.';
  }
  if (wet.length == 1) {
    final a = wet.first;
    return '${a.place.name} có thể mưa từ ${hh(onset[a]!)}${src(a)}; '
        'nơi còn lại ít khả năng mưa trong 12 giờ tới.';
  }
  final hot = ok.reduce(
    (a, b) =>
        a.data!.current.temperature >= b.data!.current.temperature ? a : b,
  );
  return 'Ít khả năng mưa ở cả ${ok.length} nơi trong 12 giờ tới; '
      '${hot.place.name} nóng nhất (${temp(hot.data!.current.temperature)}°).';
}

/// Mot dia diem trong so sanh.
class CompareSeries {
  CompareSeries({
    required this.place,
    required this.label,
    required this.style,
    required this.result,
    required this.error,
  });

  final Place place;
  final String? label;
  final CompareSeriesStyle style;
  final WeatherResult? result;
  final ApiException? error;

  WeatherData? get data => result?.data;
}
