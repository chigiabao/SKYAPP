import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/activities.dart';
import '../models/weather.dart';

/// Chia se tom tat thoi tiet / goi y hoat dong dang van ban (nhom 10).

const String kShareSignature = '– Sky Weather (dữ liệu mô hình Open-Meteo)';

String _two(int n) => n.toString().padLeft(2, '0');

/// "15:00 17/10".
String shareTimeLabel(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)} ${_two(t.day)}/${_two(t.month)}';

String _lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

/// Kha nang mua lon nhat (%) trong 3 gio toi; null neu khong co so lieu.
int? rainNext3h(List<HourlyForecast> hours, DateTime nowHcm) {
  final from = HcmTime.startOfHour(nowHcm);
  final to = from.add(const Duration(hours: 3));
  int? best;
  for (final h in hours) {
    if (h.time.isBefore(from) || !h.time.isBefore(to)) continue;
    if (h.rainProbability == null) continue;
    final p = h.rainPercent;
    if (best == null || p > best) best = p;
  }
  return best;
}

/// "Phường Bến Thành, 15:00 17/10: 31°, mưa rào, khả năng mưa 3 giờ tới
/// 70%. – Sky Weather (dữ liệu mô hình Open-Meteo)".
/// [tempText] da dinh dang theo don vi nguoi dung (vd. "31°").
String weatherShareText({
  required String placeName,
  required DateTime at,
  required String tempText,
  required String condition,
  int? rainPercent3h,
}) {
  final parts = [
    tempText,
    _lowerFirst(condition),
    if (rainPercent3h != null) 'khả năng mưa 3 giờ tới $rainPercent3h%',
  ];
  return '$placeName, ${shareTimeLabel(at)}: ${parts.join(', ')}. '
      '$kShareSignature';
}

/// Tom tat tu du lieu theo gio (uu tien gio hien tai) hoac [current].
/// null neu khong co du lieu nao.
String? forecastShareText({
  required String placeName,
  required DateTime nowHcm,
  required List<HourlyForecast> hours,
  CurrentWeather? current,
  required String Function(double celsius) formatTempValue,
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
  return weatherShareText(
    placeName: placeName,
    at: hour,
    tempText: '${formatTempValue(temp)}°',
    condition: cond.description,
    rainPercent3h: rainNext3h(hours, nowHcm),
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
  lines.add(kShareSignature);
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
