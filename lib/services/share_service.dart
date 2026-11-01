import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/activities.dart';
import '../models/units.dart';
import '../models/weather.dart';
import '../utils/forecast_format.dart';

/// Chia se tom tat thoi tiet / goi y hoat dong dang van ban (nhom 10).

const String kShareSignature = '– Sky Weather (dự báo AI của nhóm)';

/// Chu ky khi nhiet do/troi la so lieu phan tich (gio hien tai), con kha
/// nang mua la du bao AI cua nhom.
const String kShareSignatureAnalysis =
    '– Sky Weather (số liệu đã ghi nhận theo mô hình; khả năng mưa: dự báo '
    'AI của nhóm)';

/// Chu ky khi chi co so lieu phan tich, khong co so du bao nao.
const String kShareSignatureAnalysisOnly =
    '– Sky Weather (số liệu đã ghi nhận theo mô hình, không phải dự báo)';

/// Chu ky che do xem lai: du lieu lich su/thong ke, khong phai du bao AI.
const String kShareSignatureReplay = '– Sky Weather (xem lại dữ liệu lịch sử)';

String _two(int n) => n.toString().padLeft(2, '0');

/// "17/10 15:00".
String shareTimeLabel(DateTime t) => ForecastFormat.dateTime(t);

String _lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

/// "Phường Bến Thành, 15:00 17/10: 31°, mưa rào, khả năng mưa 3 giờ tới
/// 70%. – Sky Weather (dự báo AI của nhóm)".
/// [tempText] da dinh dang theo don vi nguoi dung (vd. "31°").
String weatherShareText({
  required String placeName,
  required DateTime at,
  required String tempText,
  required String condition,
  int? rainPercent3h,
  String signature = kShareSignature,
}) {
  final parts = [
    tempText,
    _lowerFirst(condition),
    if (rainPercent3h != null) 'khả năng mưa 3 giờ tới $rainPercent3h%',
  ];
  return '$placeName, ${shareTimeLabel(at)}: ${parts.join(', ')}. '
      '$signature';
}

/// Tom tat tu du lieu theo gio (uu tien gio hien tai) hoac [current].
/// null neu khong co du lieu nao. Chu ky ghi dung nguon: so lieu phan tich
/// khong bi ghi la du bao AI; [replay] dung chu ky xem lai trung tinh.
String? forecastShareText({
  required String placeName,
  required DateTime nowHcm,
  required List<HourlyForecast> hours,
  CurrentWeather? current,
  required String Function(double celsius) formatTempValue,
  bool replay = false,
}) {
  final hour = HcmTime.startOfHour(nowHcm);
  HourlyForecast? h;
  for (final x in hours) {
    if (HcmTime.startOfHour(x.time) == hour) {
      h = x;
      break;
    }
  }
  final temp = current?.temperature ?? h?.temperature;
  final cond = current?.condition ?? h?.condition;
  if (temp == null || cond == null) return null;
  final rain = rainNext3h(hours, nowHcm);
  final source = current?.temperature != null ? current?.source : h?.source;
  final signature = replay
      ? kShareSignatureReplay
      : source == DataSource.observed
      ? (rain == null ? kShareSignatureAnalysisOnly : kShareSignatureAnalysis)
      : kShareSignature;
  return weatherShareText(
    placeName: placeName,
    at: hour,
    tempText: '${formatTempValue(temp)}°',
    condition: cond.description,
    rainPercent3h: rain,
    signature: signature,
  );
}

/// Goi y khung gio hoat dong, moi hoat dong mot dong.
String activityShareText({
  required String placeName,
  required List<Activity> activities,
  required List<HourlyForecast> hours,
  required DateTime nowHcm,
  int horizonHours = 24,
  Sensitivity sensitivity = Sensitivity.normal,
  bool replay = false,
  UnitPrefs units = const UnitPrefs(),
}) {
  final lines = <String>['Gợi ý khung giờ hoạt động · $placeName:'];
  for (final a in activities) {
    final w = bestWindows(
      a,
      hours,
      nowHcm: nowHcm,
      horizonHours: horizonHours,
      limit: 1,
      sensitivity: sensitivity,
      units: units,
    );
    if (w.isEmpty) {
      lines.add('• ${a.label}: chưa có khung giờ phù hợp');
    } else {
      final x = w.first;
      lines.add(
        '• ${a.label}: ${_dayLabel(x.start, nowHcm)} '
        '${_two(x.start.hour)}:${_two(x.start.minute)}–'
        '${_two(x.end.hour)}:${_two(x.end.minute)} '
        '(${x.rating.label}; ${x.reason})',
      );
    }
  }
  lines.add(replay ? kShareSignatureReplay : kShareSignature);
  return lines.join('\n');
}

String _dayLabel(DateTime t, DateTime nowHcm) {
  final d = HcmTime.startOfDay(t).difference(HcmTime.startOfDay(nowHcm)).inDays;
  return d == 0
      ? 'hôm nay'
      : (d == 1 ? 'mai' : '${_two(t.day)}/${_two(t.month)}');
}

enum ShareOutcome { shared, copied, failed }

/// Ham chia se van ban (thay duoc trong test).
typedef TextSharer = Future<ShareOutcome> Function(String text);

/// share_plus (Web: Web Share API neu trinh duyet co). Khong co bang chia
/// se / loi -> sao chep vao clipboard.
Future<ShareOutcome> shareOrCopy(String text) async {
  try {
    // Web: thanh cong cung tra "unavailable"; khong co Web Share -> nem loi
    // (tat fallback mailto) -> clipboard.
    await SharePlus.instance.share(
      ShareParams(text: text, mailToFallbackEnabled: false),
    );
    return ShareOutcome.shared;
  } catch (_) {
    // Web khong co navigator.share / desktop khong ho tro -> clipboard.
  }
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return ShareOutcome.copied;
  } catch (_) {
    return ShareOutcome.failed;
  }
}
