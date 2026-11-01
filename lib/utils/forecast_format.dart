import '../models/hcm_time.dart';

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

  /// Nhan ngan theo so thu ISO (1 = Thu 2 ... 7 = Chu nhat): "T2" / "CN".
  static String weekdayShortOf(int isoWeekday) =>
      _weekdaysShort[isoWeekday % 7];

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// "16/10" / "07/10" (ngay/thang luon 2 chu so).
  static String dayMonth(DateTime d) => '${_two(d.day)}/${_two(d.month)}';

  /// Ngay-gio ngan, kieu duy nhat cho moi nhan "luc ...": "20/10 10:00".
  static String dateTime(DateTime d) => '${dayMonth(d)} ${hourMinute(d)}';

  /// Tieu de man hinh: "Thứ 5, 16/10".
  static String title(DateTime d) => '${weekday(d)}, ${dayMonth(d)}';

  /// "14:00"
  static String hourMinute(DateTime d) => clock(d.hour, d.minute);

  /// Gio trong ngay, dinh dang thong nhat: "07:30" / "17:00" (khong dung
  /// "7h30" trong cau chu hay thong bao).
  static String clock(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  /// Nhan truc gio: "14h"
  static String hourShort(DateTime d) => '${d.hour}h';

  static bool sameDay(DateTime a, DateTime b) =>
      HcmTime.startOfDay(a) == HcmTime.startOfDay(b);

  /// Ngay-gio day du: "Thứ 3, 20/10 · 10:00" (xem lai, kiem chung AI).
  static String moment(DateTime d) => '${title(d)} · ${hourMinute(d)}';

  /// Gio muc tieu: cung ngay voi [nowHcm] -> "23:00", khac ngay -> "00:00 · T6".
  static String targetTime(DateTime d, DateTime nowHcm) => sameDay(d, nowHcm)
      ? hourMinute(d)
      : '${hourMinute(d)} · ${weekdayShort(d)}';

  /// "Hôm nay" / "Ngày mai" / "Thứ 6" (ten day du, cho nhan ngan dau dong).
  static String relativeDayLong(DateTime d, DateTime nowHcm) {
    final r = relativeDay(d, nowHcm);
    return r == 'Hôm nay' || r == 'Ngày mai' ? r : weekday(d);
  }

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
