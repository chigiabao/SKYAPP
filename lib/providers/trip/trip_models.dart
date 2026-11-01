part of '../trip_provider.dart';

enum TripPhase { idle, active, paused, ended }

/// Mot canh bao trong chuyen di.
@immutable
class TripAlert {
  const TripAlert({required this.at, required this.title, required this.body});

  final DateTime at; // gio TP.HCM
  final String title;
  final String body;

  Map<String, dynamic> toJson() => {
    'at': HcmTime.toIso(at),
    'title': title,
    'body': body,
  };

  static TripAlert? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final at = HcmTime.tryParse(j['at']?.toString());
    final t = j['title'];
    final b = j['body'];
    if (at == null || t is! String || b is! String) return null;
    return TripAlert(at: at, title: t, body: b);
  }
}

/// Mot chuyen di da xong. Chi id phuong, khong co toa do.
@immutable
class TripRecord {
  const TripRecord({
    required this.startedAt,
    required this.endedAt,
    required this.withRoute,
    this.fromId,
    this.toId,
    this.profile,
    this.alerts = const [],
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final bool withRoute;
  final String? fromId;
  final String? toId;
  final TripProfile? profile;
  final List<TripAlert> alerts;

  String get id => HcmTime.toIso(startedAt);

  Map<String, dynamic> toJson() => {
    'started_at': HcmTime.toIso(startedAt),
    'ended_at': HcmTime.toIso(endedAt),
    'with_route': withRoute,
    'from_id': fromId,
    'to_id': toId,
    'profile': profile?.api,
    'alerts': [for (final a in alerts) a.toJson()],
  };

  static TripRecord? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final s = HcmTime.tryParse(j['started_at']?.toString());
    final e = HcmTime.tryParse(j['ended_at']?.toString());
    if (s == null || e == null) return null;
    final a = j['alerts'];
    return TripRecord(
      startedAt: s,
      endedAt: e,
      withRoute: j['with_route'] == true,
      fromId: j['from_id'] as String?,
      toId: j['to_id'] as String?,
      profile: j['profile'] == null ? null : TripProfile.parse(j['profile']),
      alerts: [
        if (a is List)
          for (final x in a) ?TripAlert.tryFromJson(x),
      ],
    );
  }
}

/// Mot phuong an gio khoi hanh khi so sanh (lech [offsetMin] phut).
@immutable
class DepartOption {
  const DepartOption(this.offsetMin, this.route);
  final int offsetMin;
  final TripRoute route;
  int get score => routeHazardScore(route);
}

/// Diem nguy hiem cua tuyen: tong muc nguy hiem cac diem mau.
int routeHazardScore(TripRoute r) => r.samples.fold(
  0,
  (s, x) =>
      s +
      switch (x.hazard) {
        RouteHazard.none || RouteHazard.lowRain => 0,
        RouteHazard.rain => 1,
        RouteHazard.heavy => 2,
        RouteHazard.storm => 3,
        RouteHazard.unknown => 4,
      },
);
