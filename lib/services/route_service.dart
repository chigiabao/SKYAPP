/// Tuyen duong + thoi tiet doc tuyen (nhom 6): GET /route va
/// POST /route/along-weather cua backend (backend goi OSRM, app khong goi).
///
/// Du lieu tuyen (c) OpenStreetMap contributors, OSRM.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/api_config.dart';
import '../models/hcm_time.dart';

/// Phuong tien (tham so `profile` cua backend).
enum TripProfile {
  driving('Ô tô / xe máy', 'driving'),
  cycling('Xe đạp', 'cycling'),
  foot('Đi bộ', 'foot');

  const TripProfile(this.label, this.api);
  final String label;
  final String api;

  static TripProfile parse(Object? v) => TripProfile.values.firstWhere(
    (p) => p.api == v || p.name == v,
    orElse: () => TripProfile.driving,
  );
}

/// Muc nguy hiem cua mot diem mau (de to mau tuyen).
enum RouteHazard {
  none('Khô ráo'),
  rain('Có mưa'),
  heavy('Mưa to / gió giật'),
  storm('Dông');

  const RouteHazard(this.label);
  final String label;
}

/// Mot diem mau doc tuyen (~2 km mot diem).
@immutable
class RouteSample {
  const RouteSample({
    required this.point,
    required this.eta,
    this.cellId,
    this.temperature,
    this.precipitation,
    this.rainProbability,
    this.weatherCode,
    this.windGusts,
    this.source,
    this.alert = false,
    this.alertReason,
  });

  final LatLng point;

  /// Gio du kien toi diem nay (gio TP.HCM, xem HcmTime).
  final DateTime eta;
  final String? cellId;
  final double? temperature;
  final double? precipitation; // mm/h
  final double? rainProbability; // 0..1
  final int? weatherCode;
  final double? windGusts; // km/h
  final String? source;

  /// Backend: dong (95-99), >= 5 mm/h hoac gio giat >= 50 km/h.
  final bool alert;
  final String? alertReason;

  bool get isStorm =>
      weatherCode != null && weatherCode! >= 95 && weatherCode! <= 99;

  /// Mua lon (nguong backend 5 mm/h).
  bool get isHeavyRain => (precipitation ?? 0) >= 5;

  /// Diem can bao truoc khi di qua: mua lon hoac dong.
  bool get isRainOrStormAlert => isStorm || isHeavyRain;

  RouteHazard get hazard {
    if (isStorm) return RouteHazard.storm;
    if (alert) return RouteHazard.heavy;
    if ((precipitation ?? 0) >= 0.5 || (rainProbability ?? 0) >= 0.6) {
      return RouteHazard.rain;
    }
    return RouteHazard.none;
  }

  factory RouteSample.fromJson(Map<String, dynamic> j) {
    final eta = HcmTime.tryParse(j['eta']?.toString());
    final lat = _d(j['lat']);
    final lon = _d(j['lon']);
    if (eta == null || lat == null || lon == null) {
      throw const FormatException('route sample');
    }
    return RouteSample(
      point: LatLng(lat, lon),
      eta: eta,
      cellId: j['cell_id']?.toString(),
      temperature: _d(j['temperature']),
      precipitation: _d(j['precipitation']),
      rainProbability: _d(j['rain_probability']),
      weatherCode: (j['weather_code'] as num?)?.toInt(),
      windGusts: _d(j['wind_gusts']),
      source: j['source']?.toString(),
      alert: j['alert'] == true,
      alertReason: j['alert_reason']?.toString(),
    );
  }
}

/// Ket qua GET /route hoac POST /route/along-weather.
@immutable
class TripRoute {
  const TripRoute({
    required this.profile,
    required this.departAt,
    required this.arriveAt,
    required this.distanceKm,
    required this.durationMin,
    required this.geometry,
    required this.samples,
    this.worst,
    this.alert = false,
    this.attribution = kRouteAttribution,
  });

  final TripProfile profile;
  final DateTime departAt; // gio TP.HCM
  final DateTime arriveAt; // gio TP.HCM
  final double distanceKm;
  final double durationMin;
  final List<LatLng> geometry;
  final List<RouteSample> samples;
  final RouteSample? worst;
  final bool alert;
  final String attribution;

  /// Diem xau nhat co canh bao (null neu tuyen khong co canh bao).
  RouteSample? get worstAlert => worst != null && worst!.alert ? worst : null;

  factory TripRoute.fromJson(Map<String, dynamic> j) {
    final depart = HcmTime.tryParse(j['depart_at']?.toString());
    final arrive = HcmTime.tryParse(j['arrive_at']?.toString());
    final geo = j['geometry'];
    final samples = j['samples'];
    if (depart == null || arrive == null || geo is! List || samples is! List) {
      throw const FormatException('route');
    }
    final points = <LatLng>[];
    for (final p in geo) {
      if (p is List && p.length >= 2) {
        final lat = _d(p[0]);
        final lon = _d(p[1]);
        if (lat != null && lon != null) points.add(LatLng(lat, lon));
      }
    }
    final w = j['worst'];
    return TripRoute(
      profile: TripProfile.parse(j['profile']),
      departAt: depart,
      arriveAt: arrive,
      distanceKm: _d(j['distance_km']) ?? 0,
      durationMin: _d(j['duration_min']) ?? 0,
      geometry: points,
      samples: [
        for (final s in samples)
          if (s is Map<String, dynamic>) RouteSample.fromJson(s),
      ],
      worst: w is Map<String, dynamic> ? RouteSample.fromJson(w) : null,
      alert: j['alert'] == true,
      attribution: j['attribution']?.toString() ?? kRouteAttribution,
    );
  }
}

const String kRouteAttribution = '© OpenStreetMap contributors, OSRM';

enum RouteErrorKind { unavailable, badRequest, noRoute, network, invalid }

/// Loi tim duong; [message] la cau tieng Viet de hien thi.
class RouteException implements Exception {
  RouteException(this.kind, [String? detail])
    : message = detail ?? _default(kind);

  final RouteErrorKind kind;
  final String message;

  static String _default(RouteErrorKind k) => switch (k) {
    RouteErrorKind.unavailable =>
      'Dịch vụ tìm đường đang lỗi hoặc quá tải, vui lòng thử lại sau.',
    RouteErrorKind.badRequest => 'Tuyến nằm ngoài TP.HCM hoặc dài quá 300 km.',
    RouteErrorKind.noRoute => 'Không tìm thấy đường đi giữa hai điểm.',
    RouteErrorKind.network => 'Không tới được máy chủ.',
    RouteErrorKind.invalid => 'Dữ liệu tuyến đường không hợp lệ.',
  };

  @override
  String toString() => 'RouteException(${kind.name}): $message';
}

class RouteService {
  /// [baseUrl] chi de test; mac dinh doc [ApiConfig.baseUrl] moi lan goi.
  RouteService({http.Client? client, this._baseUrl, this.timeout = _timeout})
    : _client = client ?? http.Client();

  // OSRM co the cham hon cac API thoi tiet.
  static const Duration _timeout = Duration(seconds: 25);

  final http.Client _client;
  final String? _baseUrl;
  final Duration timeout;

  /// Doc moi lan (dia chi may chu co the doi luc chay).
  String get baseUrl => _baseUrl ?? ApiConfig.baseUrl;

  /// GET /route. [departAt] la gio TP.HCM.
  Future<TripRoute> fetchRoute({
    required LatLng from,
    required LatLng to,
    required DateTime departAt,
    TripProfile profile = TripProfile.driving,
  }) {
    final uri = Uri.parse('$baseUrl/route').replace(
      queryParameters: {
        'from_lat': from.latitude.toStringAsFixed(5),
        'from_lon': from.longitude.toStringAsFixed(5),
        'to_lat': to.latitude.toStringAsFixed(5),
        'to_lon': to.longitude.toStringAsFixed(5),
        'depart_at': HcmTime.toIso(departAt),
        'profile': profile.api,
      },
    );
    return _send(() => _client.get(uri));
  }

  /// POST /route/along-weather: thoi tiet doc [geometry] (phan tuyen con
  /// lai), khoi hanh [departAt], tong thoi gian [durationMin].
  Future<TripRoute> alongWeather({
    required List<LatLng> geometry,
    required DateTime departAt,
    double? durationMin,
    TripProfile profile = TripProfile.driving,
  }) {
    final uri = Uri.parse('$baseUrl/route/along-weather');
    final body = jsonEncode({
      'geometry': [
        for (final p in geometry)
          [
            double.parse(p.latitude.toStringAsFixed(5)),
            double.parse(p.longitude.toStringAsFixed(5)),
          ],
      ],
      'depart_at': HcmTime.toIso(departAt),
      if (durationMin != null && durationMin > 0)
        'duration_min': math.min(durationMin, 24 * 60),
      'profile': profile.api,
    });
    return _send(
      () => _client.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: body,
      ),
    );
  }

  Future<TripRoute> _send(Future<http.Response> Function() call) async {
    final http.Response r;
    try {
      r = await call().timeout(timeout);
    } catch (e) {
      debugPrint('RouteService: $e');
      throw RouteException(RouteErrorKind.network);
    }
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode != 200) {
      final detail = body is Map ? body['detail'] : null;
      final msg = detail is String ? detail : null;
      throw switch (r.statusCode) {
        503 => RouteException(RouteErrorKind.unavailable),
        400 || 422 => RouteException(RouteErrorKind.badRequest, msg),
        404 => RouteException(RouteErrorKind.noRoute),
        _ => RouteException(RouteErrorKind.unavailable),
      };
    }
    if (body is! Map<String, dynamic>) {
      throw RouteException(RouteErrorKind.invalid);
    }
    try {
      return TripRoute.fromJson(body);
    } on FormatException {
      throw RouteException(RouteErrorKind.invalid);
    } on TypeError {
      throw RouteException(RouteErrorKind.invalid);
    }
  }
}

double? _d(Object? v) => v is num ? v.toDouble() : null;

/// Khoang cach (km) giua hai diem.
double routeKm(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b) / 1000;

/// Do dai tich luy (km) tai moi dinh cua [line].
List<double> cumulativeKm(List<LatLng> line) {
  final out = <double>[0];
  for (var i = 1; i < line.length; i++) {
    out.add(out.last + routeKm(line[i - 1], line[i]));
  }
  return out;
}

/// Chi so dinh gan [p] nhat tren [line].
int nearestIndex(List<LatLng> line, LatLng p) {
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < line.length; i++) {
    final d = routeKm(line[i], p);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}
