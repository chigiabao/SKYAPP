part of '../activities.dart';

class ActivityRoutine {
  const ActivityRoutine({
    required this.id,
    required this.activity,
    required this.placeId,
    required this.hour,
    this.minute = 0,
    this.weekdays = const {1, 2, 3, 4, 5, 6, 7},
    this.sensitivity = Sensitivity.normal,
  });

  final String id;
  final Activity activity;
  final String placeId;
  final int hour;
  final int minute;

  /// DateTime.monday (1) .. DateTime.sunday (7).
  final Set<int> weekdays;
  final Sensitivity sensitivity;

  /// Lan dien ra tiep theo tu [nowHcm] (trong 8 ngay), null neu khong co ngay.
  DateTime? nextAfter(DateTime nowHcm) {
    if (weekdays.isEmpty) return null;
    final day = HcmTime.startOfDay(nowHcm);
    for (var i = 0; i < 8; i++) {
      final d = day.add(Duration(days: i));
      final t = d.add(Duration(hours: hour, minutes: minute));
      if (weekdays.contains(d.weekday) && !t.isBefore(nowHcm)) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'activity': activity.name,
    'placeId': placeId,
    'hour': hour,
    'minute': minute,
    'weekdays': weekdays.toList()..sort(),
    'sensitivity': sensitivity.name,
  };

  static ActivityRoutine? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final a = Activity.values.where((e) => e.name == j['activity']);
    final h = j['hour'];
    final m = j['minute'];
    if (a.isEmpty ||
        j['id'] is! String ||
        j['placeId'] is! String ||
        h is! int ||
        h < 0 ||
        h > 23) {
      return null;
    }
    final wd = j['weekdays'];
    return ActivityRoutine(
      id: j['id'] as String,
      activity: a.first,
      placeId: j['placeId'] as String,
      hour: h,
      minute: m is int && m >= 0 && m < 60 ? m : 0,
      weekdays: wd is List
          ? {
              for (final d in wd)
                if (d is int && d >= 1 && d <= 7) d,
            }
          : const {1, 2, 3, 4, 5, 6, 7},
      sensitivity: Sensitivity.values.firstWhere(
        (s) => s.name == j['sensitivity'],
        orElse: () => Sensitivity.normal,
      ),
    );
  }
}

/// Danh gia mot lan dien ra cua lich: diem gio do (khong xet khung gio cho
/// phep cua hoat dong vi nguoi dung da chon gio), null neu thieu du lieu.
HourScore? scoreRoutineAt(
  ActivityRoutine r,
  List<HourlyForecast> hours,
  DateTime at,
) {
  final slot = HcmTime.startOfHour(at);
  for (final h in hours) {
    if (h.time == slot) {
      return scoreHour(
        r.activity,
        HourScoreInput.from(h),
        sensitivity: r.sensitivity,
        anyHour: true,
      );
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Gio di / ve va thong bao buoi sang

/// "07:30" / "17:00" (dinh dang gio thong nhat ca app, ke ca thong bao).
String clockHm(int h, int m) => ForecastFormat.clock(h, m);

/// Gio di / ve (di lam / di hoc), dia diem Nha / Noi lam, thong bao buoi
/// sang. Mac dinh: di 7:30, ve 17:30, thong bao 6:30 (tat cho toi khi
/// nguoi dung bat).
