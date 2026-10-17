/// Noi DUY NHAT tinh canh nen cua app tu du lieu that.
///
/// * `isDay` = [isDaytime] tai [WeatherProvider.nowHcm] (che do xem lai ->
///   thoi diem xem lai) cho diem du lieu [ApiConfig.latitude] /
///   [ApiConfig.longitude].
/// * `scene` = [effectiveScene] ([resolveScene] (ma WMO, isDay, gio, tam nhin,
///   may) cua thoi tiet hien tai, [SceneOverride]).
/// * Khi dang tai lai (du lieu tam thoi null) giu canh cu de khong nhay nen.
///
/// [AppSceneScope] dat trong `MaterialApp.builder` (main.dart) va cung cap
/// [AppSceneData] cho moi man hinh qua [AppScene.of].
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../models/weather.dart';
import '../../providers/weather_provider.dart';
import 'sun_times.dart';
import 'weather_background.dart';

/// Ma WMO dai dien cho [WeatherCondition] - chi dung khi backend khong gui
/// `weather_code` (du lieu cu / test). Khong dung de hien thi so lieu.
int wmoForCondition(WeatherCondition c) {
  switch (c) {
    case WeatherCondition.sunny:
      return 0;
    case WeatherCondition.partlyCloudy:
      return 2;
    case WeatherCondition.cloudy:
    case WeatherCondition.windy:
      return 3;
    case WeatherCondition.drizzle:
      return 51;
    case WeatherCondition.rainy:
      return 61;
    case WeatherCondition.showers:
      return 80;
    case WeatherCondition.thunderstorm:
      return 95;
    case WeatherCondition.foggy:
      return 45;
  }
}

/// Ngay/dem tai diem du lieu cua app.
bool isDayAt(DateTime hcm) =>
    isDaytime(hcm, lat: ApiConfig.latitude, lon: ApiConfig.longitude);

/// Ket qua tinh canh: tat ca man hinh dung chung.
@immutable
class AppSceneData {
  const AppSceneData({
    required this.scene,
    required this.isDay,
    required this.windSpeedKmh,
    required this.intensity,
    required this.resolved,
  });

  /// Canh dang hien (da tinh gia lap).
  final WeatherScene scene;

  /// Ban ngay (da tinh gia lap ngay/dem).
  final bool isDay;

  final double windSpeedKmh;
  final double intensity;

  /// Canh suy ra tu du lieu that (truoc gia lap).
  final WeatherScene resolved;

  SceneTheme get theme => SceneTheme.of(scene, isDay: isDay);

  /// Tinh canh. [previous]: canh that lan truoc, giu lai khi chua co du lieu.
  static AppSceneData compute({
    required WeatherProvider provider,
    SceneOverride? sceneOverride,
    WeatherScene? previous,
  }) {
    final bool realIsDay = isDayAt(provider.nowHcm);
    final CurrentWeather? c = provider.currentWeather;
    final WeatherScene resolved;
    if (c != null) {
      final double? vis = c.visibilityKm;
      resolved = resolveScene(
        weatherCode: c.weatherCode ?? wmoForCondition(c.condition),
        isDay: realIsDay,
        windSpeedKmh: c.windSpeed,
        visibilityMeters: vis == null ? null : vis * 1000,
        cloudCover: c.cloudCover?.toDouble(),
      );
    } else if (previous != null) {
      resolved = previous.withDaytime(realIsDay);
    } else {
      resolved = resolveScene(weatherCode: null, isDay: realIsDay);
    }
    final SceneOverride? o = sceneOverride;
    final WeatherScene scene = effectiveScene(resolved, o);
    final bool active = o != null && o.active;
    final bool isDay = active
        ? (o.isDay ??
              (scene.isNightVariant
                  ? false
                  : scene.isDayVariant
                  ? true
                  : realIsDay))
        : realIsDay;
    return AppSceneData(
      scene: scene,
      isDay: isDay,
      windSpeedKmh: (active ? o.windSpeedKmh : null) ?? c?.windSpeed ?? 0,
      intensity: (active ? o.intensity : null) ?? 1.0,
      resolved: resolved,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSceneData &&
      other.scene == scene &&
      other.isDay == isDay &&
      other.windSpeedKmh == windSpeedKmh &&
      other.intensity == intensity &&
      other.resolved == resolved;

  @override
  int get hashCode =>
      Object.hash(scene, isDay, windSpeedKmh, intensity, resolved);
}

/// [SceneOverride] cua app neu co (ban debug dang ky trong main.dart).
SceneOverride? maybeSceneOverride(BuildContext context, {bool listen = true}) {
  try {
    return Provider.of<SceneOverride>(context, listen: listen);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Tinh [AppSceneData] mot lan cho ca app, cap nhat khi du lieu / gia lap
/// doi va moi phut (qua moc mat troi moc / lan).
class AppSceneScope extends StatefulWidget {
  const AppSceneScope({super.key, required this.child});

  final Widget child;

  @override
  State<AppSceneScope> createState() => _AppSceneScopeState();
}

class _AppSceneScopeState extends State<AppSceneScope> {
  WeatherScene? _lastResolved;
  Timer? _minute;

  @override
  void initState() {
    super.initState();
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _minute?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final o = maybeSceneOverride(context);
    final data = AppSceneData.compute(
      provider: provider,
      sceneOverride: o,
      previous: _lastResolved,
    );
    if (provider.currentWeather != null) _lastResolved = data.resolved;
    return AppScene(data: data, child: widget.child);
  }
}

/// Phat [AppSceneData] xuong cay widget.
class AppScene extends InheritedWidget {
  const AppScene({super.key, required this.data, required super.child});

  final AppSceneData data;

  /// Canh hien tai. Khong co [AppSceneScope] (vd. test chi dung mot man
  /// hinh) -> tinh truc tiep tu provider (khong nho canh cu).
  static AppSceneData of(BuildContext context) {
    final AppScene? s = context.dependOnInheritedWidgetOfExactType<AppScene>();
    if (s != null) return s.data;
    return AppSceneData.compute(
      provider: context.watch<WeatherProvider>(),
      sceneOverride: maybeSceneOverride(context),
    );
  }

  @override
  bool updateShouldNotify(AppScene oldWidget) => oldWidget.data != data;
}
