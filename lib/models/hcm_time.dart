/// Gio TP.HCM (UTC+7, Viet Nam khong co gio mua he).
///
/// Quy uoc trong app: moi DateTime trong model (time, date, lastUpdated,
/// issuedAt, cachedAt...) la "gio dong ho TP.HCM" - cac truong year/month/
/// day/hour... chinh la gio tai TP.HCM, bat ke mui gio cua thiet bi.
/// De tranh bi lech khi thiet bi co DST, gia tri nay duoc luu voi isUtc = true
/// (chi la vo chua, KHONG phai gio UTC that). Vi vay:
///   - Hien thi: dung truc tiep .hour / DateFormat(...).format(t). KHONG goi
///     .toLocal().
///   - So sanh voi "bay gio": dung [HcmTime.now], khong dung DateTime.now().
///   - Can thoi diem tuyet doi (UTC that): [HcmTime.toInstant].
class HcmTime {
  HcmTime._();

  static const Duration offset = Duration(hours: 7);

  /// Gio dong ho TP.HCM hien tai. [clock] tra ve thoi diem that (de test).
  static DateTime now([DateTime Function()? clock]) =>
      fromInstant((clock ?? DateTime.now)());

  /// Thoi diem bat ky -> gio dong ho TP.HCM.
  static DateTime fromInstant(DateTime instant) => instant.toUtc().add(offset);

  /// Gio dong ho TP.HCM -> thoi diem that (UTC).
  static DateTime toInstant(DateTime hcmWallClock) => DateTime.utc(
    hcmWallClock.year,
    hcmWallClock.month,
    hcmWallClock.day,
    hcmWallClock.hour,
    hcmWallClock.minute,
    hcmWallClock.second,
    hcmWallClock.millisecond,
    hcmWallClock.microsecond,
  ).subtract(offset);

  /// Parse timestamp tu backend:
  ///   - co offset ("...+07:00", "...Z") -> doi dung thoi diem sang gio TP.HCM;
  ///   - khong offset ("2026-10-10T23:00:00", "2026-10-15") -> hieu la gio
  ///     TP.HCM (KHONG phai gio cua thiet bi).
  /// Tra ve null neu chuoi khong hop le.
  static DateTime? tryParse(String? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null) return null;
    if (parsed.isUtc) return fromInstant(parsed);
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  /// Gio dong ho TP.HCM -> chuoi ISO co offset, vd "2026-10-07T12:00:00+07:00"
  /// (dung cho tham so `at` cua backend).
  static String toIso(DateTime hcmWallClock) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = hcmWallClock;
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
        'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}+07:00';
  }

  /// Dau ngay (00:00) theo gio TP.HCM.
  static DateTime startOfDay(DateTime hcmWallClock) =>
      DateTime.utc(hcmWallClock.year, hcmWallClock.month, hcmWallClock.day);

  /// Dau gio (HH:00) theo gio TP.HCM.
  static DateTime startOfHour(DateTime hcmWallClock) => DateTime.utc(
    hcmWallClock.year,
    hcmWallClock.month,
    hcmWallClock.day,
    hcmWallClock.hour,
  );
}
