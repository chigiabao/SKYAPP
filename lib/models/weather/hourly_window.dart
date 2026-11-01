import '../hcm_time.dart';
import 'hourly_forecast.dart';

/// Kha nang mua lon nhat (%) trong 3 gio toi; null neu khong co so lieu.
/// Bo qua gio "thuc te" (phan tich): xac suat cua no chi la 1/0, khong phai
/// kha nang mua.
int? rainNext3h(List<HourlyForecast> hours, DateTime nowHcm) {
  final from = HcmTime.startOfHour(nowHcm);
  final to = from.add(const Duration(hours: 3));
  int? best;
  for (final h in hours) {
    if (h.time.isBefore(from) || !h.time.isBefore(to)) continue;
    if (h.rainProbability == null || h.isObserved) continue;
    final p = h.rainPercent;
    if (best == null || p > best) best = p;
  }
  return best;
}
