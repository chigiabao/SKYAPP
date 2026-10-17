import '../../models/hcm_time.dart';

/// Dinh dang ngay/gio cho man hinh du bao. Moi DateTime la gio dong ho
/// TP.HCM (xem [HcmTime]) nen chi doc truc tiep cac truong, khong doi mui gio.
class ForecastFormat {
  ForecastFormat._();

  static const _weekdays = [
    'Chủ nhật',
    'Thứ 2',
    'Thứ 3',
    'Thứ 4',
    'Thứ 5',
    'Thứ 6',
    'Thứ 7',
  ];
  static const _weekdaysShort = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];

  static String weekday(DateTime d) => _weekdays[d.weekday % 7];

  static String weekdayShort(DateTime d) => _weekdaysShort[d.weekday % 7];

  /// "16/10"
  static String dayMonth(DateTime d) => '${d.day}/${d.month}';

  /// Tieu de man hinh: "Thứ 5, 16/10".
  static String title(DateTime d) => '${weekday(d)}, ${dayMonth(d)}';

  /// "14:00"
  static String hourMinute(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// Nhan truc gio: "14h"
  static String hourShort(DateTime d) => '${d.hour}h';

  static bool sameDay(DateTime a, DateTime b) =>
      HcmTime.startOfDay(a) == HcmTime.startOfDay(b);

  /// "12:00 Thứ 4, 07/10/2026" (banner xem lai).
  static String moment(DateTime d) =>
      '${hourMinute(d)} ${weekday(d)}, '
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Gio muc tieu: cung ngay voi [nowHcm] -> "23:00", khac ngay -> "00:00 · T6".
  static String targetTime(DateTime d, DateTime nowHcm) => sameDay(d, nowHcm)
      ? hourMinute(d)
      : '${hourMinute(d)} · ${weekdayShort(d)}';

  /// "Hôm nay" / "Ngày mai" / "T6"
  static String relativeDay(DateTime d, DateTime nowHcm) {
    final diff = HcmTime.startOfDay(d)
        .difference(HcmTime.startOfDay(nowHcm))
        .inDays;
    if (diff == 0) return 'Hôm nay';
    if (diff == 1) return 'Ngày mai';
    return weekdayShort(d);
  }
}
