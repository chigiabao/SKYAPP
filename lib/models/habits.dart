/// Hoc thoi quen don gian, minh bach, chi tren may (de bai muc 4.4: "Mở
/// rộng học thói quen với sự đồng ý; cho phép xác nhận, sửa hoặc xóa lịch
/// được gợi ý"; muc 9: "chủ động bật/tắt học thói quen").
///
/// Chi dem so lan theo gio trong ngay (0-23):
///   - lan mo app;
///   - lan nguoi dung bam "Đã làm" mot hoat dong.
/// Khong ghi vi tri, khong gui di dau. Tat -> khong ghi them; "Xóa" -> ve 0.
library;

import 'activities.dart';

/// So lan "Đã làm" toi thieu de mot gio duoc coi la "giờ quen".
const int kHabitMinDone = 2;

/// So lan "Đã làm" toi thieu de goi y tao lich.
const int kHabitSuggestDone = 3;

/// Diem cong cho khung gio trung "giờ quen" (minh bach: hien "Hợp giờ quen").
const double kHabitBonus = 8;

/// Diem cong nho cho gio hay mo app (it nhat 3 lan).
const double kOpenBonus = 3;

/// Goi y tao lich tu thoi quen.
class RoutineSuggestion {
  const RoutineSuggestion(this.activity, this.hour, this.count);
  final Activity activity;
  final int hour;

  /// So lan da lam vao gio nay.
  final int count;

  String get key => '${activity.name}|$hour';
}

class HabitData {
  const HabitData({
    this.enabled = false,
    this.opens = const {},
    this.done = const {},
    this.dismissed = const {},
  });

  /// Nguoi dung dong y hoc thoi quen. Mac dinh tat.
  final bool enabled;

  /// Gio (0-23) -> so lan mo app.
  final Map<int, int> opens;

  /// Hoat dong -> gio (0-23) -> so lan "Đã làm".
  final Map<Activity, Map<int, int>> done;

  /// Goi y da bo qua ([RoutineSuggestion.key]).
  final Set<String> dismissed;

  bool get isEmpty => opens.isEmpty && done.isEmpty && dismissed.isEmpty;

  HabitData copyWith({
    bool? enabled,
    Map<int, int>? opens,
    Map<Activity, Map<int, int>>? done,
    Set<String>? dismissed,
  }) => HabitData(
    enabled: enabled ?? this.enabled,
    opens: opens ?? this.opens,
    done: done ?? this.done,
    dismissed: dismissed ?? this.dismissed,
  );

  /// Ghi mot lan mo app luc [nowHcm] (chi khi da dong y).
  HabitData recordOpen(DateTime nowHcm) {
    if (!enabled) return this;
    final h = nowHcm.hour;
    return copyWith(opens: {...opens, h: (opens[h] ?? 0) + 1});
  }

  /// Ghi "Đã làm" [a] luc [nowHcm] (chi khi da dong y).
  HabitData recordDone(Activity a, DateTime nowHcm) {
    if (!enabled) return this;
    final h = nowHcm.hour;
    final m = done[a] ?? const {};
    return copyWith(
      done: {
        ...done,
        a: {...m, h: (m[h] ?? 0) + 1},
      },
    );
  }

  /// Xoa du lieu, giu lua chon bat/tat.
  HabitData cleared() => HabitData(enabled: enabled);

  int doneAt(Activity a, int hour) => done[a]?[hour] ?? 0;

  /// "Giờ quen" cua [a] (>= [kHabitMinDone] lan), nhieu lan truoc.
  List<int> habitHours(Activity a) {
    final m = done[a] ?? const {};
    final hs = [
      for (final e in m.entries)
        if (e.value >= kHabitMinDone) e.key,
    ]..sort((x, y) => m[y]!.compareTo(m[x]!));
    return hs;
  }

  /// Gio hay mo app (>= 3 lan), nhieu lan truoc.
  List<int> get openHours {
    final hs = [
      for (final e in opens.entries)
        if (e.value >= 3) e.key,
    ]..sort((x, y) => opens[y]!.compareTo(opens[x]!));
    return hs;
  }

  /// Diem cong theo gio bat dau cho [a] (dung trong bestWindows). Rong khi
  /// tat hoac chua co du lieu.
  Map<int, double> hourBonus(Activity a) {
    if (!enabled) return const {};
    final out = <int, double>{
      for (final h in openHours) h: kOpenBonus,
    };
    for (final h in habitHours(a)) {
      out[h] = kHabitBonus;
    }
    return out;
  }

  /// Goi y tao lich: gio da lam >= [kHabitSuggestDone] lan, chua co lich cung
  /// hoat dong va cung gio, chua bi bo qua.
  List<RoutineSuggestion> suggestions(List<ActivityRoutine> routines) {
    if (!enabled) return const [];
    final out = <RoutineSuggestion>[];
    for (final e in done.entries) {
      for (final h in e.value.entries) {
        if (h.value < kHabitSuggestDone) continue;
        final s = RoutineSuggestion(e.key, h.key, h.value);
        if (dismissed.contains(s.key)) continue;
        if (routines.any((r) => r.activity == e.key && r.hour == h.key)) {
          continue;
        }
        out.add(s);
      }
    }
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  HabitData dismiss(RoutineSuggestion s) =>
      copyWith(dismissed: {...dismissed, s.key});

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'opens': {for (final e in opens.entries) '${e.key}': e.value},
    'done': {
      for (final e in done.entries)
        e.key.name: {for (final h in e.value.entries) '${h.key}': h.value},
    },
    'dismissed': dismissed.toList()..sort(),
  };

  /// Doc an toan: truong sai bi bo qua.
  factory HabitData.fromJson(Map<String, dynamic> j) {
    Map<int, int> hours(Object? raw) {
      final out = <int, int>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          final h = int.tryParse('$k');
          if (h != null && h >= 0 && h < 24 && v is int && v > 0) out[h] = v;
        });
      }
      return out;
    }

    final done = <Activity, Map<int, int>>{};
    final d = j['done'];
    if (d is Map) {
      for (final a in Activity.values) {
        final m = hours(d[a.name]);
        if (m.isNotEmpty) done[a] = m;
      }
    }
    final dis = j['dismissed'];
    return HabitData(
      enabled: j['enabled'] == true,
      opens: hours(j['opens']),
      done: done,
      dismissed: dis is List ? {...dis.whereType<String>()} : const {},
    );
  }
}
