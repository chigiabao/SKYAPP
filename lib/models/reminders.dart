/// Nhac truoc gio hoat dong (de bai muc 5: "Nhắc trước hoạt động hoặc giờ
/// đi/về theo thời gian người dùng chọn"). Thuan Dart: tinh gio hen, diem
/// thoi tiet cua khung gio va goi y khung thay the khi thoi tiet xau.
library;

import 'activities.dart';
import 'weather.dart';
import 'weather_alerts.dart';

/// Cai dat thong bao he thong (Android) va nhac hoat dong.
class NotifySettings {
  const NotifySettings({
    this.system = false,
    this.reminders = true,
    this.minutesBefore = 30,
    this.reminderQuiet = false,
  });

  /// Lua chon "nhac truoc X phut".
  static const List<int> minuteOptions = [15, 30, 60, 120];

  /// Gui thong bao he thong (canh bao + nhac). Mac dinh tat: chi bat khi
  /// nguoi dung chon (luc do moi xin quyen).
  final bool system;

  /// Nhac truoc gio cua lich hoat dong.
  final bool reminders;
  final int minutesBefore;

  /// "Tôn trọng giờ yên lặng cho lời nhắc". Mac dinh tat: nhac do nguoi dung
  /// tu dat van gui trong gio yen lang (gio yen lang chi ap cho canh bao tu
  /// dong).
  final bool reminderQuiet;

  NotifySettings copyWith({
    bool? system,
    bool? reminders,
    int? minutesBefore,
    bool? reminderQuiet,
  }) => NotifySettings(
    system: system ?? this.system,
    reminders: reminders ?? this.reminders,
    minutesBefore: minutesBefore ?? this.minutesBefore,
    reminderQuiet: reminderQuiet ?? this.reminderQuiet,
  );

  Map<String, dynamic> toJson() => {
    'system': system,
    'reminders': reminders,
    'minutesBefore': minutesBefore,
    'reminderQuiet': reminderQuiet,
  };

  factory NotifySettings.fromJson(Map<String, dynamic> j) {
    const d = NotifySettings();
    final m = j['minutesBefore'];
    return NotifySettings(
      system: j['system'] is bool ? j['system'] as bool : d.system,
      reminders: j['reminders'] is bool ? j['reminders'] as bool : d.reminders,
      minutesBefore: m is int && m > 0 && m <= 24 * 60 ? m : d.minutesBefore,
      reminderQuiet: j['reminderQuiet'] is bool
          ? j['reminderQuiet'] as bool
          : d.reminderQuiet,
    );
  }
}

/// Lan dien ra tiep theo ma con kip nhac truoc [minutesBefore] phut: tra ve
/// (gio hoat dong, gio nhac), gio TP.HCM. Tu nhien qua nua dem (vd. lich
/// 00:15, nhac 30 phut -> 23:45 hom truoc). null neu lich khong co ngay.
({DateTime occurrence, DateTime fireAt})? nextReminder(
  ActivityRoutine r,
  DateTime nowHcm,
  int minutesBefore,
) {
  final lead = Duration(minutes: minutesBefore);
  final occ = r.nextAfter(nowHcm.add(lead));
  if (occ == null) return null;
  return (occurrence: occ, fireAt: occ.subtract(lead));
}

/// Khung gio thay the gan [occurrence] (+-[span] gio) cho lich [r] khi gio da
/// chon xau: diem >= 55 va hon gio da chon it nhat 15 diem; chi xet gio sau
/// [notBefore]. null neu khong co.
HourScore? alternativeSlot(
  ActivityRoutine r,
  List<HourlyForecast> hours,
  DateTime occurrence, {
  required DateTime notBefore,
  int span = 3,
}) {
  final current = scoreRoutineAt(r, hours, occurrence);
  final base = current?.score ?? 0;
  final slot = HcmTime.startOfHour(occurrence);
  HourScore? best;
  for (var k = 1; k <= span; k++) {
    for (final d in [k, -k]) {
      final t = slot.add(Duration(hours: d));
      if (t.isBefore(notBefore)) continue;
      final s = scoreRoutineAt(r, hours, t);
      if (s == null || s.score < 55 || s.score < base + 15) continue;
      if (best == null || s.score > best.score) best = s;
    }
  }
  return best;
}

/// Mot thong bao nhac da len lich.
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.routine,
    required this.occurrence,
    required this.fireAt,
    required this.title,
    required this.body,
    this.score,
    this.alternative,
  });

  final int id;
  final ActivityRoutine routine;
  final DateTime occurrence;
  final DateTime fireAt;
  final String title;
  final String body;
  final HourScore? score;
  final HourScore? alternative;
}

/// Ket qua [planReminders].
class ReminderPlan {
  const ReminderPlan(this.reminders, this.skippedQuiet);
  final List<PlannedReminder> reminders;

  /// So lan nhac bo qua vi roi vao gio yen lang.
  final int skippedQuiet;
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Id thong bao nhac: 1..[maxReminders] (canh bao dung khoang khac).
const int maxReminders = 40;

/// Len lich nhac cho moi lich hoat dong trong [horizon] toi: moi lan dien ra
/// co gio nhac >= [nowHcm]. Nhac do nguoi dung tu dat van gui trong gio yen
/// lang, tru khi [respectQuiet] (luc do bi bo, dem vao
/// [ReminderPlan.skippedQuiet]). Noi dung gom diem thoi tiet cua khung gio
/// (neu da co du bao) va goi y khung thay the khi xau.
ReminderPlan planReminders(
  List<ActivityRoutine> routines, {
  required DateTime nowHcm,
  required int minutesBefore,
  required AlertSettings quiet,
  required List<HourlyForecast>? Function(String placeId) hoursFor,
  String Function(String placeId)? placeName,
  bool respectQuiet = false,
  Duration horizon = const Duration(hours: 48),
}) {
  final until = nowHcm.add(horizon);
  final lead = Duration(minutes: minutesBefore);
  final out = <PlannedReminder>[];
  var skipped = 0;
  for (final r in routines) {
    var from = nowHcm;
    for (var guard = 0; guard < 16; guard++) {
      final next = nextReminder(r, from, minutesBefore);
      if (next == null || next.fireAt.isAfter(until)) break;
      from = next.fireAt.add(const Duration(minutes: 1));
      if (respectQuiet && quiet.inQuietHours(next.fireAt)) {
        skipped++;
        continue;
      }
      final hours = hoursFor(r.placeId);
      final score = hours == null
          ? null
          : scoreRoutineAt(r, hours, next.occurrence);
      HourScore? alt;
      final parts = <String>[
        if (placeName != null && placeName(r.placeId).isNotEmpty)
          placeName(r.placeId),
      ];
      if (score == null) {
        parts.add('Chưa có dự báo cho khung giờ này');
      } else {
        final rating = WindowRating.of(score.score);
        final worst = score.penalties.entries.isEmpty
            ? null
            : score.penalties.entries.reduce(
                (a, b) => a.value >= b.value ? a : b,
              );
        parts.add(
          'Thời tiết ${rating.label.toLowerCase()} '
          '(${score.score.round()}/100)'
          '${worst != null && worst.value >= 10 ? ', lưu ý ${worst.key}' : ''}',
        );
        if (rating == WindowRating.poor) {
          alt = alternativeSlot(r, hours!, next.occurrence, notBefore: nowHcm);
          parts.add(
            alt == null
                ? 'Không có khung giờ tốt hơn gần đó'
                : 'Gợi ý: ${_hm(alt.time)} '
                      '(${WindowRating.of(alt.score).label.toLowerCase()})',
          );
        }
      }
      out.add(
        PlannedReminder(
          id: 0,
          routine: r,
          occurrence: next.occurrence,
          fireAt: next.fireAt,
          title:
              '${r.activity.label} lúc ${_hm(next.occurrence)} '
              '(còn ${_lead(lead)})',
          body: parts.join(' · '),
          score: score,
          alternative: alt,
        ),
      );
    }
  }
  out.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  final kept = out.take(maxReminders).toList();
  return ReminderPlan([
    for (var i = 0; i < kept.length; i++)
      PlannedReminder(
        id: i + 1,
        routine: kept[i].routine,
        occurrence: kept[i].occurrence,
        fireAt: kept[i].fireAt,
        title: kept[i].title,
        body: kept[i].body,
        score: kept[i].score,
        alternative: kept[i].alternative,
      ),
  ], skipped);
}

String _lead(Duration d) => d.inMinutes % 60 == 0
    ? '${d.inHours} giờ'
    : '${d.inMinutes} phút';

/// Id thong bao he thong cua mot canh bao (on dinh giua cac lan chay, theo
/// khoa chong trung: "Cập nhật" thay the thong bao cu cung khoa). Khoang
/// 1000.. (nhac dung 1..[maxReminders]).
int alertNotificationId(AlertNotice n) {
  // FNV-1a 32 bit (String.hashCode khong dam bao on dinh).
  var h = 0x811c9dc5;
  for (final c in noticeKey(n).codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return 1000 + h % 1000000;
}
