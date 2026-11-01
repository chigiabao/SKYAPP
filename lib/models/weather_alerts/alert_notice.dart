part of '../weather_alerts.dart';

class AlertNotice {
  const AlertNotice({
    required this.type,
    required this.level,
    required this.placeId,
    required this.placeName,
    required this.start,
    required this.end,
    required this.createdAt,
    required this.title,
    required this.body,
    this.updated = false,
    this.read = false,
  });

  final AlertType type;
  final AlertLevel level;
  final String placeId;
  final String placeName;
  final DateTime start;
  final DateTime end;

  /// Luc tao (gio TP.HCM).
  final DateTime createdAt;
  final String title;
  final String body;

  /// Thong bao cap nhat (du bao thay doi dang ke: muc do tang).
  final bool updated;
  final bool read;

  AlertNotice markRead() => AlertNotice(
    type: type,
    level: level,
    placeId: placeId,
    placeName: placeName,
    start: start,
    end: end,
    createdAt: createdAt,
    title: title,
    body: body,
    updated: updated,
    read: true,
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'level': level.name,
    'placeId': placeId,
    'placeName': placeName,
    'start': HcmTime.toIso(start),
    'end': HcmTime.toIso(end),
    'createdAt': HcmTime.toIso(createdAt),
    'title': title,
    'body': body,
    'updated': updated,
    'read': read,
  };

  /// null neu du lieu hong.
  static AlertNotice? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final type = AlertType.values.where((t) => t.name == j['type']);
    final level = AlertLevel.values.where((l) => l.name == j['level']);
    final start = HcmTime.tryParse(j['start'] as String?);
    final end = HcmTime.tryParse(j['end'] as String?);
    final created = HcmTime.tryParse(j['createdAt'] as String?);
    if (type.isEmpty ||
        level.isEmpty ||
        start == null ||
        end == null ||
        created == null ||
        j['placeId'] is! String) {
      return null;
    }
    return AlertNotice(
      type: type.first,
      level: level.first,
      placeId: j['placeId'] as String,
      placeName: j['placeName'] is String ? j['placeName'] as String : '',
      start: start,
      end: end,
      createdAt: created,
      title: j['title'] is String ? j['title'] as String : '',
      body: j['body'] is String ? j['body'] as String : '',
      updated: j['updated'] == true,
      read: j['read'] == true,
    );
  }
}

/// Ket qua [planNotices]: thong bao moi + so canh bao bi giu do gio yen lang.
class NoticePlan {
  const NoticePlan(this.notices, this.held);
  final List<AlertNotice> notices;
  final int held;
}

/// Chong spam: chi tao thong bao khi
///   - muc >= [AlertSettings.minNotifyLevel];
///   - chua co thong bao cung loai + dia diem co khung gio giao nhau, HOAC co
///     nhung muc do moi cao hon (du bao xau di dang ke -> "Cập nhật");
///   - khong trong gio yen lang (tru muc Nguy hiem).
/// Gio "thuc te" va du bao duoc ghi ro trong noi dung.
NoticePlan planNotices(
  List<AlertEvent> events, {
  required List<AlertNotice> history,
  required AlertSettings settings,
  required DateTime nowHcm,
  required String placeName,
  UnitPrefs units = const UnitPrefs(),
}) {
  final out = <AlertNotice>[];
  var held = 0;
  final quiet = settings.inQuietHours(nowHcm);
  for (final e in events) {
    if (!(e.level >= settings.minNotifyLevel)) continue;
    final prior = [
      for (final n in [...history, ...out])
        if (n.type == e.type &&
            n.placeId == e.placeId &&
            e.overlaps(n.start, n.end))
          n,
    ];
    final updated = prior.isNotEmpty;
    if (updated && prior.any((n) => n.level >= e.level)) continue;
    if (quiet && e.level != AlertLevel.danger) {
      held++;
      continue;
    }
    out.add(
      AlertNotice(
        type: e.type,
        level: e.level,
        placeId: e.placeId,
        placeName: placeName,
        start: e.start,
        end: e.end,
        createdAt: nowHcm,
        title:
            '${updated ? 'Cập nhật: ' : ''}${e.level.label} '
            '${e.type.label.toLowerCase()} · ${alertRange(e.start, e.end)}',
        body: '$placeName · ${e.detailFor(units)}',
        updated: updated,
      ),
    );
  }
  return NoticePlan(out, held);
}

/// Khoa chong trung / gop cua mot thong bao: loai | dia diem | gio bat dau.
String noticeKey(AlertNotice n) =>
    '${n.type.name}|${n.placeId}|${HcmTime.toIso(n.start)}';

/// Gop hai ban luu (vd. app dang mo va tac vu nen) theo [noticeKey]: giu muc
/// cao nhat (bang nhau -> ban moi hon), `read` = OR hai ben. Thu tu: theo lan
/// xuat hien dau tien ([a] truoc).
List<AlertNotice> mergeNotices(
  Iterable<AlertNotice> a,
  Iterable<AlertNotice> b,
) {
  final byKey = <String, AlertNotice>{};
  for (final n in [...a, ...b]) {
    final k = noticeKey(n);
    final o = byKey[k];
    if (o == null) {
      byKey[k] = n;
      continue;
    }
    final keep =
        n.level > o.level ||
            (n.level == o.level && n.createdAt.isAfter(o.createdAt))
        ? n
        : o;
    byKey[k] = (n.read || o.read) && !keep.read ? keep.markRead() : keep;
  }
  return byKey.values.toList();
}
