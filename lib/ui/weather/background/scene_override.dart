import 'package:flutter/material.dart';

import '../weather_scene.dart';

/// Gia lap thoi tiet (debug): khi [active], app hien canh trong day thay vi
/// canh suy ra tu du lieu that. Home cung cap mot instance cho toan app.
class SceneOverride extends ChangeNotifier {
  WeatherScene? _scene;
  bool? _isDay;
  double? _windSpeedKmh;
  double? _intensity;

  /// Canh ep buoc (null = giu canh that).
  WeatherScene? get scene => _scene;

  /// Ep ngay/dem (null = giu theo du lieu that).
  bool? get isDay => _isDay;

  /// Toc do gio gia lap km/h (null = gio that).
  double? get windSpeedKmh => _windSpeedKmh;

  /// Cuong do hieu ung gia lap (null = mac dinh 1.0).
  double? get intensity => _intensity;

  /// Dang gia lap hay khong.
  bool get active =>
      _scene != null ||
      _isDay != null ||
      _windSpeedKmh != null ||
      _intensity != null;

  /// Ghi de TOAN BO gia tri gia lap (tham so null = bo gia lap truong do).
  void set({
    WeatherScene? scene,
    bool? isDay,
    double? windSpeedKmh,
    double? intensity,
  }) {
    _scene = scene;
    _isDay = isDay;
    _windSpeedKmh = windSpeedKmh;
    _intensity = intensity;
    notifyListeners();
  }

  /// Tat gia lap.
  void clear() {
    if (!active) return;
    _scene = null;
    _isDay = null;
    _windSpeedKmh = null;
    _intensity = null;
    notifyListeners();
  }
}

/// Vi tri mat troi / mat trang (px, toa do cua WeatherBackground). Dung de
/// dat than sang vao goc tren phai, tranh chu cua dau trang.
@immutable
class CelestialPlacement {
  const CelestialPlacement({
    required this.center,
    required this.radius,
    this.opacity = 1.0,
  });

  /// Goc tren phai, ngay DUOI thanh cong cu ([top] + [toolbarHeight]):
  /// thanh cong cu co the co 1-3 nut o ben phai nen dia khong duoc nam
  /// ngang hang voi chung. Ban kinh 16-21 px theo chieu rong.
  factory CelestialPlacement.topRight(
    double width, {
    double top = 0,
    double toolbarHeight = 64,
    double opacity = 1.0,
  }) {
    final double r = (width * 0.055).clamp(16.0, 21.0);
    return CelestialPlacement(
      center: Offset(width * 0.85, top + toolbarHeight + 8 + r),
      radius: r,
      opacity: opacity,
    );
  }

  final Offset center;
  final double radius;
  final double opacity;

  /// Hinh vuong bao dia (khong tinh quang mo).
  Rect get discRect => Rect.fromCircle(center: center, radius: radius * 1.06);

  @override
  bool operator ==(Object other) =>
      other is CelestialPlacement &&
      other.center == center &&
      other.radius == radius &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(center, radius, opacity);
}

/// Canh thuc su hien thi: [resolved] neu khong gia lap, nguoc lai canh cua
/// [o] (va doi ban ngay/dem neu [SceneOverride.isDay] duoc dat).
WeatherScene effectiveScene(WeatherScene resolved, SceneOverride? o) {
  if (o == null || !o.active) return resolved;
  final WeatherScene s = o.scene ?? resolved;
  final bool? isDay = o.isDay;
  return isDay == null ? s : s.withDaytime(isDay);
}
