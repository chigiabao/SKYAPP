import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../painters/cloud_layer_painter.dart';
import '../painters/fog_painter.dart';
import '../painters/lightning_painter.dart';
import '../painters/moon_stars_painter.dart';
import '../painters/rain_painter.dart';
import '../painters/snow_painter.dart';
import '../painters/sun_painter.dart';
import '../painters/wind_painter.dart';
import '../weather_scene.dart';
import 'scene_override.dart';

const Set<SceneLayer> particleLayers = {
  SceneLayer.shootingStar,
  SceneLayer.drizzle,
  SceneLayer.rain,
  SceneLayer.heavyRain,
  SceneLayer.sleet,
  SceneLayer.lightning,
  SceneLayer.snow,
  SceneLayer.windStreaks,
};

class SceneLayers extends StatelessWidget {
  const SceneLayers({
    super.key,
    required this.theme,
    required this.clock,
    required this.windSpeedKmh,
    required this.intensity,
    required this.quality,
    required this.seed,
    required this.reduceMotion,
    required this.splashTargets,
    required this.splashEdge,
    required this.lightningHaptics,
    required this.celestial,
  });

  final CelestialPlacement? celestial;
  final SceneTheme theme;
  final ValueListenable<double> clock;
  final double windSpeedKmh;
  final double intensity;
  final double quality;
  final int? seed;
  final bool reduceMotion;
  final ValueListenable<List<Rect>>? splashTargets;
  final SplashEdge splashEdge;
  final bool lightningHaptics;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final SceneLayer layer in theme.layers)
            if (!reduceMotion || !particleLayers.contains(layer))
              RepaintBoundary(
                key: ValueKey<SceneLayer>(layer),
                child: LayerView(
                  layer: layer,
                  theme: theme,
                  clock: clock,
                  windSpeedKmh: windSpeedKmh,
                  intensity: intensity,
                  quality: quality,
                  seed: seed == null ? null : seed! + layer.index * 101,
                  splashTargets: splashTargets,
                  splashEdge: splashEdge,
                  lightningHaptics: lightningHaptics,
                  celestial: celestial,
                ),
              ),
        ],
      ),
    );
  }
}

class LayerView extends StatefulWidget {
  const LayerView({
    super.key,
    required this.layer,
    required this.theme,
    required this.clock,
    required this.windSpeedKmh,
    required this.intensity,
    required this.quality,
    required this.seed,
    required this.splashTargets,
    required this.splashEdge,
    required this.lightningHaptics,
    required this.celestial,
  });

  final CelestialPlacement? celestial;
  final SceneLayer layer;
  final SceneTheme theme;
  final ValueListenable<double> clock;
  final double windSpeedKmh;
  final double intensity;
  final double quality;
  final int? seed;
  final ValueListenable<List<Rect>>? splashTargets;
  final SplashEdge splashEdge;
  final bool lightningHaptics;

  @override
  State<LayerView> createState() => _LayerViewState();
}

class _LayerViewState extends State<LayerView> {
  /// Trang thai hat cua lop - tao mot lan, dung lai suot vong doi.
  late final Object _state = _createState();
  int? _lastStrike;
  bool _listening = false;

  Object _createState() {
    final int? s = widget.seed;
    switch (widget.layer) {
      case SceneLayer.sun:
        return SunPaintCache();
      case SceneLayer.moonStars:
        return StarField(seed: s);
      case SceneLayer.shootingStar:
        return ShootingStarSchedule(seed: s);
      case SceneLayer.cloudsThin:
      case SceneLayer.cloudsParallax:
      case SceneLayer.cloudsDense:
        return CloudField(seed: s);
      case SceneLayer.drizzle:
        return RainField(kind: RainKind.drizzle, seed: s);
      case SceneLayer.rain:
        return RainField(kind: RainKind.rain, seed: s);
      case SceneLayer.heavyRain:
        return RainField(kind: RainKind.heavy, seed: s);
      case SceneLayer.sleet:
        return RainField(kind: RainKind.sleet, seed: s);
      case SceneLayer.lightning:
        return LightningField(seed: s);
      case SceneLayer.snow:
        return SnowField(seed: s);
      case SceneLayer.fog:
      case SceneLayer.haze:
        return FogField(seed: s);
      case SceneLayer.windStreaks:
        return WindField(seed: s);
    }
  }

  @override
  void initState() {
    super.initState();
    _syncHaptics();
  }

  @override
  void didUpdateWidget(LayerView old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock && _listening) {
      old.clock.removeListener(_onClock);
      _listening = false;
    }
    _syncHaptics();
  }

  void _syncHaptics() {
    final bool want =
        widget.lightningHaptics && widget.layer == SceneLayer.lightning;
    if (want && !_listening) {
      widget.clock.addListener(_onClock);
      _listening = true;
    } else if (!want && _listening) {
      widget.clock.removeListener(_onClock);
      _listening = false;
    }
  }

  void _onClock() {
    final int? strike = (_state as LightningField).activeStrike(
      widget.clock.value,
    );
    if (strike != null && strike != _lastStrike) {
      HapticFeedback.lightImpact();
    }
    _lastStrike = strike;
  }

  @override
  void dispose() {
    if (_listening) widget.clock.removeListener(_onClock);
    final Object s = _state;
    if (s is CloudField) s.dispose();
    if (s is FogField) s.dispose();
    super.dispose();
  }

  CustomPainter _painter() {
    final ValueListenable<double> t = widget.clock;
    final SceneTheme th = widget.theme;
    final Object s = _state;
    switch (widget.layer) {
      case SceneLayer.sun:
        return SunPainter(
          time: t,
          cache: s as SunPaintCache,
          centerPx: widget.celestial?.center,
          radiusPx: widget.celestial?.radius,
          opacity: widget.celestial?.opacity ?? 1.0,
        );
      case SceneLayer.moonStars:
        return MoonStarsPainter(
          time: t,
          field: s as StarField,
          quality: widget.quality,
          moonCenterPx: widget.celestial?.center,
          moonRadiusPx: widget.celestial?.radius,
          moonOpacity: widget.celestial?.opacity ?? 1.0,
        );
      case SceneLayer.shootingStar:
        return ShootingStarPainter(
          time: t,
          schedule: s as ShootingStarSchedule,
        );
      case SceneLayer.cloudsThin:
        return CloudLayerPainter(
          time: t,
          field: s as CloudField,
          color: th.cloudColor,
          layers: 2,
          density: 0.4,
          windSpeedKmh: widget.windSpeedKmh,
          quality: widget.quality,
          top: 0.04,
          bottom: 0.42,
        );
      case SceneLayer.cloudsParallax:
        return CloudLayerPainter(
          time: t,
          field: s as CloudField,
          color: th.cloudColor,
          layers: 3,
          density: 0.6,
          windSpeedKmh: widget.windSpeedKmh,
          quality: widget.quality,
          top: 0.03,
          bottom: 0.52,
        );
      case SceneLayer.cloudsDense:
        return CloudLayerPainter(
          time: t,
          field: s as CloudField,
          color: th.cloudColor,
          layers: 4,
          density: 1.0,
          windSpeedKmh: widget.windSpeedKmh,
          quality: widget.quality,
          top: -0.04,
          bottom: 0.62,
        );
      case SceneLayer.drizzle:
      case SceneLayer.rain:
      case SceneLayer.heavyRain:
      case SceneLayer.sleet:
        return RainPainter(
          time: t,
          field: s as RainField,
          windSpeedKmh: widget.windSpeedKmh,
          intensity: widget.intensity,
          quality: widget.quality,
          splashTargets: widget.splashTargets,
          splashEdge: widget.splashEdge,
        );
      case SceneLayer.lightning:
        return LightningPainter(
          time: t,
          field: s as LightningField,
          intensity: widget.intensity,
        );
      case SceneLayer.snow:
        return SnowPainter(
          time: t,
          field: s as SnowField,
          windSpeedKmh: widget.windSpeedKmh,
          intensity: widget.intensity,
          quality: widget.quality,
        );
      case SceneLayer.fog:
      case SceneLayer.haze:
        return FogPainter(
          time: t,
          field: s as FogField,
          warm: widget.layer == SceneLayer.haze,
          color: th.cloudColor,
          windSpeedKmh: widget.windSpeedKmh,
          intensity: widget.intensity,
        );
      case SceneLayer.windStreaks:
        return WindPainter(
          time: t,
          field: s as WindField,
          windSpeedKmh: widget.windSpeedKmh,
          quality: widget.quality,
        );
    }
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox.expand(child: CustomPaint(painter: _painter()));
}
