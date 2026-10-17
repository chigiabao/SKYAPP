/// Dia diem (phuong / xa / dac khu cua TP.HCM moi), dia diem da luu va o
/// du lieu ban do. Hop dong backend: GET /locations, /locations/search,
/// /locations/nearest, /weather/map, /locations/boundary.
library;

import 'dart:math' as math;

import '../config/api_config.dart';
import 'weather.dart';

/// Loai don vi hanh chinh (truong `kind`).
enum PlaceKind { phuong, xa, dacKhu, special }

PlaceKind parsePlaceKind(dynamic v) {
  switch (v?.toString()) {
    case 'phuong':
      return PlaceKind.phuong;
    case 'xa':
      return PlaceKind.xa;
    case 'dac_khu':
      return PlaceKind.dacKhu;
  }
  return PlaceKind.special;
}

extension PlaceKindText on PlaceKind {
  String get json => switch (this) {
    PlaceKind.phuong => 'phuong',
    PlaceKind.xa => 'xa',
    PlaceKind.dacKhu => 'dac_khu',
    PlaceKind.special => 'special',
  };

  String get label => switch (this) {
    PlaceKind.phuong => 'Phường',
    PlaceKind.xa => 'Xã',
    PlaceKind.dacKhu => 'Đặc khu',
    PlaceKind.special => 'Điểm dữ liệu',
  };
}

/// Mot dia diem backend ho tro.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.kind,
    required this.lat,
    required this.lon,
    this.region,
    this.cellId,
  });

  /// Dia diem mac dinh cua backend.
  static const String defaultId = 'tsn';

  /// Dung khi backend chua co /locations (giu nhu ban mot diem truoc day).
  static const Place fallback = Place(
    id: defaultId,
    name: ApiConfig.locationName,
    kind: PlaceKind.special,
    lat: ApiConfig.latitude,
    lon: ApiConfig.longitude,
  );

  final String id;
  final String name;
  final PlaceKind kind;

  /// Vung cu, vd "Bình Dương cũ"; null neu khong co.
  final String? region;
  final double lat;
  final double lon;

  /// O luoi thoi tiet (~8 km) chua dia diem.
  final String? cellId;

  bool get isDefault => id == defaultId;

  /// Dong phu duoi ten (dau trang, danh sach).
  String get detail {
    if (region != null && region!.isNotEmpty) return region!;
    if (id == defaultId && kind == PlaceKind.special) {
      return ApiConfig.locationDetail;
    }
    return kind.label;
  }

  /// Nem FormatException neu thieu id / ten / toa do.
  factory Place.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final lat = json['lat'];
    final lon = json['lon'];
    if (id is! String || name is! String || lat is! num || lon is! num) {
      throw const FormatException('Địa điểm không hợp lệ');
    }
    final region = json['region'];
    final cell = json['cell_id'];
    return Place(
      id: id,
      name: name,
      kind: parsePlaceKind(json['kind']),
      region: region is String && region.isNotEmpty ? region : null,
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      cellId: cell?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.json,
    'region': region,
    'lat': lat,
    'lon': lon,
    'cell_id': cellId,
  };

  /// Phan tich danh sach, bo qua phan tu loi.
  static List<Place> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Place>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      try {
        out.add(Place.fromJson(e));
      } on FormatException {
        // bo qua
      }
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is Place && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

// ---------------------------------------------------------------------------
// Tim kiem khong dau

const Map<String, String> _accentGroups = {
  'a': 'àáạảãâầấậẩẫăằắặẳẵ',
  'e': 'èéẹẻẽêềếệểễ',
  'i': 'ìíịỉĩ',
  'o': 'òóọỏõôồốộổỗơờớợởỡ',
  'u': 'ùúụủũưừứựửữ',
  'y': 'ỳýỵỷỹ',
  'd': 'đ',
};

final Map<int, int> _foldMap = {
  for (final e in _accentGroups.entries)
    for (final c in e.value.runes) c: e.key.codeUnitAt(0),
};

/// Chu thuong, bo dau tieng Viet (đ -> d), gop khoang trang.
/// "Thủ  Đức" -> "thu duc".
String foldVietnamese(String s) {
  final lower = s.toLowerCase().trim();
  final buf = StringBuffer();
  var space = false;
  for (final c in lower.runes) {
    // Dau to hop (NFD): bo qua.
    if (c >= 0x0300 && c <= 0x036F) continue;
    final ch = _foldMap[c] ?? c;
    final isSpace = ch == 0x20 || ch == 0x09 || ch == 0x0A;
    if (isSpace) {
      if (!space && buf.isNotEmpty) buf.write(' ');
      space = true;
      continue;
    }
    space = false;
    buf.writeCharCode(ch);
  }
  return buf.toString().trimRight();
}

/// Tim dia diem khong dau, ket qua tot nhat truoc: ten bat dau bang chuoi
/// tim > mot tu trong ten bat dau bang chuoi tim > ten chua chuoi tim >
/// vung cu chua chuoi tim. Bo tien to "phuong"/"xa" trong cau tim.
List<Place> searchPlaces(List<Place> places, String query, {int limit = 30}) {
  var q = foldVietnamese(query);
  for (final prefix in const ['phuong ', 'xa ', 'dac khu ']) {
    if (q.startsWith(prefix) && q.length > prefix.length) {
      q = q.substring(prefix.length);
    }
  }
  if (q.isEmpty) return const [];
  final scored = <(int, int, Place)>[];
  for (var i = 0; i < places.length; i++) {
    final p = places[i];
    final name = foldVietnamese(p.name);
    int? score;
    if (name.startsWith(q)) {
      score = 0;
    } else if (name.contains(' $q')) {
      score = 1;
    } else if (name.contains(q)) {
      score = 2;
    } else if (p.region != null && foldVietnamese(p.region!).contains(q)) {
      score = 3;
    }
    if (score != null) scored.add((score, i, p));
  }
  scored.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return [for (final s in scored.take(limit)) s.$3];
}

/// Khoang cach (km) giua hai toa do.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Dia diem gan [lat], [lon] nhat trong [places] (null neu rong).
Place? nearestPlace(List<Place> places, double lat, double lon) {
  Place? best;
  var bestD = double.infinity;
  for (final p in places) {
    final d = distanceKm(lat, lon, p.lat, p.lon);
    if (d < bestD) {
      bestD = d;
      best = p;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Dia diem da luu

/// Nhan cua dia diem da luu.
enum PlaceLabel { none, home, work, school, favorite, custom }

extension PlaceLabelText on PlaceLabel {
  String get text => switch (this) {
    PlaceLabel.none => '',
    PlaceLabel.home => 'Nhà',
    PlaceLabel.work => 'Nơi làm việc',
    PlaceLabel.school => 'Trường học',
    PlaceLabel.favorite => 'Yêu thích',
    PlaceLabel.custom => 'Tên riêng',
  };
}

/// Dia diem nguoi dung da luu: CHI luu id dia diem + nhan (khong luu toa do).
class SavedPlace {
  const SavedPlace({
    required this.locationId,
    this.label = PlaceLabel.none,
    this.customName,
  });

  final String locationId;
  final PlaceLabel label;

  /// Ten tu dat khi [label] = custom.
  final String? customName;

  /// Nhan hien thi ("Nhà", ten tu dat...); null neu khong co.
  String? get labelText {
    if (label == PlaceLabel.custom) {
      final n = customName?.trim();
      return n == null || n.isEmpty ? null : n;
    }
    return label == PlaceLabel.none ? null : label.text;
  }

  SavedPlace copyWith({PlaceLabel? label, String? customName}) => SavedPlace(
    locationId: locationId,
    label: label ?? this.label,
    customName: customName ?? this.customName,
  );

  Map<String, dynamic> toJson() => {
    'id': locationId,
    'label': label.name,
    if (customName != null) 'name': customName,
  };

  static SavedPlace? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final label = PlaceLabel.values.firstWhere(
      (l) => l.name == json['label'],
      orElse: () => PlaceLabel.none,
    );
    final name = json['name'];
    return SavedPlace(
      locationId: id,
      label: label,
      customName: name is String ? name : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Ban do

/// Mot o luoi thoi tiet (GET /weather/map).
class MapCell {
  const MapCell({
    required this.cellId,
    required this.lat,
    required this.lon,
    required this.locationIds,
    this.temperature,
    this.weatherCode,
    this.rainProbability3h,
    this.precipitation3h,
    this.alert = false,
    this.windSpeed,
    this.windDirection,
    this.windGusts,
    this.precipitation,
    this.source,
    this.validTime,
    this.outlookSource,
    this.maxOffsetHours,
  });

  final String cellId;
  final double lat;
  final double lon;
  final List<String> locationIds;
  final double? temperature;
  final int? weatherCode;

  /// Kha nang mua 3 gio toi (0-1).
  final double? rainProbability3h;

  /// Luong mua 3 gio toi (mm).
  final double? precipitation3h;
  final bool alert;

  /// Gio (km/h); [windDirection]: do, huong gio THOI TU.
  final double? windSpeed;
  final double? windDirection;
  final double? windGusts;

  /// Luong mua cua gio [validTime] (mm).
  final double? precipitation;

  /// Nguon cua khung gio: observed | forecast (null = khong ro).
  final DataSource? source;

  /// Thoi diem cua khung (gio TP.HCM).
  final DateTime? validTime;

  /// Nguon cua phan "3 gio toi": 'forecast' | 'ai' | null.
  final String? outlookSource;
  final int? maxOffsetHours;

  int? get rainPercent => rainProbability3h == null
      ? null
      : (rainProbability3h! * 100).round().clamp(0, 100);

  WeatherCondition get condition => conditionFromWmo(weatherCode);

  static MapCell? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = json['cell_id'];
    final lat = json['lat'];
    final lon = json['lon'];
    if (id == null || lat is! num || lon is! num) return null;
    final ids = json['location_ids'];
    double? d(dynamic v) => v is num ? v.toDouble() : null;
    final rain = d(json['rain_probability_next_3h']);
    return MapCell(
      cellId: id.toString(),
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      locationIds: ids is List ? [for (final i in ids) i.toString()] : const [],
      temperature: d(json['temperature']),
      weatherCode: json['weather_code'] is num
          ? (json['weather_code'] as num).toInt()
          : null,
      rainProbability3h: rain?.clamp(0.0, 1.0).toDouble(),
      precipitation3h: d(json['precipitation_next_3h']),
      alert: json['alert'] == true,
      windSpeed: d(json['wind_speed']),
      windDirection: d(json['wind_direction']),
      windGusts: d(json['wind_gusts']),
      precipitation: d(json['precipitation']),
      source: parseDataSource(json['source']),
      validTime: HcmTime.tryParse(json['valid_time']?.toString()),
      outlookSource: switch (json['outlook_source']) {
        'forecast' => 'forecast',
        'ai' => 'ai',
        _ => null,
      },
      maxOffsetHours: json['max_offset_hours'] is num
          ? (json['max_offset_hours'] as num).toInt()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'cell_id': cellId,
    'lat': lat,
    'lon': lon,
    'location_ids': locationIds,
    'temperature': temperature,
    'weather_code': weatherCode,
    'rain_probability_next_3h': rainProbability3h,
    'precipitation_next_3h': precipitation3h,
    'alert': alert,
    'wind_speed': windSpeed,
    'wind_direction': windDirection,
    'wind_gusts': windGusts,
    'precipitation': precipitation,
    'source': source?.name,
    'valid_time': validTime == null ? null : HcmTime.toIso(validTime!),
    'outlook_source': outlookSource,
    'max_offset_hours': maxOffsetHours,
  };

  static List<MapCell> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (MapCell.fromJson(e) case final MapCell c) c,
    ];
  }
}

/// Ranh gioi thanh pho: cac vong [lat, lon] (vong ngoai cua moi da giac).
class CityBoundary {
  const CityBoundary(this.rings);

  /// Moi vong la danh sach (lat, lon).
  final List<List<(double, double)>> rings;

  bool get isEmpty => rings.isEmpty;

  /// Doc GeoJSON (FeatureCollection / Feature / Polygon / MultiPolygon).
  /// Chi lay vong ngoai; sai dinh dang -> rong.
  static CityBoundary fromGeoJson(dynamic json) {
    final rings = <List<(double, double)>>[];
    void ring(dynamic r) {
      if (r is! List) return;
      final pts = <(double, double)>[];
      for (final p in r) {
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
          pts.add(((p[1] as num).toDouble(), (p[0] as num).toDouble()));
        }
      }
      if (pts.length >= 3) rings.add(pts);
    }

    void geometry(dynamic g) {
      if (g is! Map) return;
      final coords = g['coordinates'];
      switch (g['type']) {
        case 'Polygon':
          if (coords is List && coords.isNotEmpty) ring(coords.first);
        case 'MultiPolygon':
          if (coords is List) {
            for (final poly in coords) {
              if (poly is List && poly.isNotEmpty) ring(poly.first);
            }
          }
        case 'GeometryCollection':
          final gs = g['geometries'];
          if (gs is List) gs.forEach(geometry);
      }
    }

    if (json is Map) {
      switch (json['type']) {
        case 'FeatureCollection':
          final fs = json['features'];
          if (fs is List) {
            for (final f in fs) {
              if (f is Map) geometry(f['geometry']);
            }
          }
        case 'Feature':
          geometry(json['geometry']);
        default:
          geometry(json);
      }
    }
    return CityBoundary(rings);
  }

  /// Luu cache dang GeoJSON MultiPolygon gon.
  Map<String, dynamic> toGeoJson() => {
    'type': 'MultiPolygon',
    'coordinates': [
      for (final r in rings)
        [
          [
            for (final p in r) [p.$2, p.$1],
          ],
        ],
    ],
  };

  /// Diem nam trong ranh gioi (ray casting tren moi vong).
  bool contains(double lat, double lon) {
    for (final r in rings) {
      var inside = false;
      for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
        final (yi, xi) = r[i];
        final (yj, xj) = r[j];
        if ((yi > lat) != (yj > lat) &&
            lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
          inside = !inside;
        }
      }
      if (inside) return true;
    }
    return false;
  }
}
