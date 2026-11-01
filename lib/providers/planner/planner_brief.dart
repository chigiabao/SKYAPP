part of '../planner_provider.dart';

class _PlannerBriefHelper {
  static ({DateTime at, String body})? planBrief({
    required DateTime now,
    required CommuteSettings commute,
    required NotifySettings notifySettings,
    required AlertSettings settings,
    required Map<String, String> names,
    required Map<String, List<HourlyForecast>> liveHours,
  }) {
    if (!notifySettings.system || !commute.briefEnabled) return null;
    var at = HcmTime.startOfDay(now)
        .add(Duration(hours: commute.briefHour, minutes: commute.briefMinute));
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    if (!commute.briefInQuiet && settings.inQuietHours(at)) return null;
    final ids = <String>{?commute.homeId, ?commute.workId};
    final body = morningBrief(
      [for (final id in ids) (name: names[id] ?? id, hours: liveHours[id])],
      at,
      commute,
    );
    return (
      at: at,
      body:
          body ??
          (ids.isEmpty
              ? 'Chọn Nhà và Nơi làm trong Cài đặt để nhận tóm tắt mưa.'
              : 'Chưa có dự báo mới cho hôm nay. Mở Sky Weather để cập nhật.'),
    );
  }
}
