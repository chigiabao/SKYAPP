/// Nen dong theo thoi tiet: gradient + cac lop hieu ung + noi dung tuy chon.
///
/// Dung:
/// ```dart
/// WeatherBackground(
///   scene: effectiveScene(resolveScene(...), sceneOverride),
///   windSpeedKmh: current.windSpeed ?? 0,
///   child: homeContent,
/// )
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'painters/cloud_layer_painter.dart';
import 'painters/fog_painter.dart';
import 'painters/lightning_painter.dart';
import 'painters/moon_stars_painter.dart';
import 'painters/rain_painter.dart';
import 'painters/snow_painter.dart';
import 'painters/sun_painter.dart';
import 'painters/wind_painter.dart';
import 'weather_scene.dart';

export 'painters/rain_painter.dart' show SplashEdge;
export 'weather_scene.dart';

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

  /// Goc tren phai: tam x = 85 % chieu rong, ban kinh 16-21 px theo chieu
  /// rong, mep duoi cach [top] + 4 + 2r (nam tren dong chu dau tien neu dong
  /// do bat dau tu [top] + 48).
  factory CelestialPlacement.topRight(
    double width, {
    double top = 0,
    double opacity = 1.0,
  }) {
    final double r = (width * 0.055).clamp(16.0, 21.0);
    return CelestialPlacement(
      center: Offset(width * 0.85, top + 3 + r),
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

/// Nen dong theo canh thoi tiet.
///
/// * Doi [scene] -> chuyen canh 700 ms (gradient noi suy mau, lop cu mo dan
///   va chi bi go khi chuyen xong - khong nhay trang).
/// * Ton trong `MediaQuery.disableAnimationsOf`: nen tinh, khong hat.
/// * Dung ticker khi app vao nen (lifecycle) hoac khi bi an (TickerMode).
/// * Moi lop co RepaintBoundary rieng; tu giam so hat khi khung hinh cham
///   ([qualityScale] 1.0 -> 0.6 -> 0.35).
class WeatherBackground extends StatefulWidget {
  const WeatherBackground({
    super.key,
    required this.scene,
    this.windSpeedKmh = 0,
    this.intensity = 1.0,
    this.child,
    this.isDay,
    this.lowPower = false,
    this.splashTargets,
    this.splashEdge = SplashEdge.bottom,
    this.lightningHaptics = false,
    this.seed,
    this.debugFixedTime,
    this.transitionDuration = const Duration(milliseconds: 700),
    this.celestial,
  });

  /// Canh can ve.
  final WeatherScene scene;

  /// Ghi de vi tri mat troi / mat trang (null = vi tri mac dinh cua painter).
  final CelestialPlacement? celestial;

  /// Toc do gio (km/h): do xien mua, toc do may, vet gio.
  final double windSpeedKmh;

  /// Cuong do hieu ung 0.3 - 1.5 (toc do / do dai hat, do day suong).
  final double intensity;

  /// Noi dung ve tren nen.
  final Widget? child;

  /// Ban ngay? Chi dung cho canh dung chung ngay/dem (rain, fog, windy...).
  /// null -> suy tu [scene] (clearNight / partlyCloudyNight = dem).
  final bool? isDay;

  /// Che do tiet kiem pin: gioi han so hat o muc thap nhat (35 %).
  final bool lowPower;

  /// Cac o chu nhat (toa do cua widget nay, thuong la mep the kinh) ma mot
  /// phan hat mua se "cham" vao va tao gon song.
  final ValueListenable<List<Rect>>? splashTargets;

  /// Mep nao cua [splashTargets] la mat cham (mac dinh: mep duoi).
  final SplashEdge splashEdge;

  /// Rung nhe (HapticFeedback.lightImpact) moi lan chop. Mac dinh tat.
  final bool lightningHaptics;

  /// Seed ngau nhien co dinh (golden test). null = ngau nhien.
  final int? seed;

  /// Ve dung mot khung tai thoi diem nay (giay) va khong chay ticker.
  final double? debugFixedTime;

  /// Thoi gian chuyen canh.
  final Duration transitionDuration;

  /// He so chat luong dung chung (1.0 / 0.6 / 0.35). Co the doc de hien thi
  /// hoac dat thu cong.
  static final ValueNotifier<double> qualityScale = ValueNotifier<double>(1.0);

  /// Cac muc chat luong, giam dan.
  static const List<double> qualitySteps = [1.0, 0.6, 0.35];

  /// Nguong trung binh build + raster (ms) de ha mot muc chat luong.
  static const double slowFrameMs = 16;

  /// Dua chat luong ve 100 %.
  static void resetQuality() => qualityScale.value = qualitySteps.first;

  static int _runningTickers = 0;
  static int _liveStates = 0;

  /// So ticker hoat canh dang chay (cho test ro ri).
  @visibleForTesting
  static int get debugRunningTickers => _runningTickers;

  /// So State dang song (cho test ro ri).
  @visibleForTesting
  static int get debugLiveStates => _liveStates;

  @override
  State<WeatherBackground> createState() => _WeatherBackgroundState();
}

@immutable
class _LayerSet {
  const _LayerSet(this.scene, this.isDay, this.theme, this.id);
  final WeatherScene scene;
  final bool isDay;
  final SceneTheme theme;
  final int id;
}

class _WeatherBackgroundState extends State<WeatherBackground>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final ValueNotifier<double> _clock;
  late final Ticker _ticker;
  late final AnimationController _fade;
  late final CurvedAnimation _curve;
  double _base = 0;
  bool _tickerCounted = false;

  late _LayerSet _current;
  _LayerSet? _previous;
  double _prevStartOpacity = 1;
  late SceneTheme _fromTheme;
  int _gen = 0;

  bool _reduceMotion = false;
  bool _appVisible = true;
  bool _timingsOn = false;
  int _timingFrames = 0;
  int _timingSumUs = 0;

  bool get _isDay => widget.isDay ?? !widget.scene.isNightVariant;

  _LayerSet _makeSet() => _LayerSet(
    widget.scene,
    _isDay,
    SceneTheme.of(widget.scene, isDay: _isDay),
    _gen++,
  );

  @override
  void initState() {
    super.initState();
    WeatherBackground._liveStates++;
    WidgetsBinding.instance.addObserver(this);
    final AppLifecycleState? life = WidgetsBinding.instance.lifecycleState;
    _appVisible =
        life == null ||
        life == AppLifecycleState.resumed ||
        life == AppLifecycleState.inactive;
    _clock = ValueNotifier<double>(widget.debugFixedTime ?? 0);
    _ticker = createTicker(_onTick);
    _fade = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
      value: 1,
    )..addStatusListener(_onFadeStatus);
    _curve = CurvedAnimation(parent: _fade, curve: Curves.easeInOut);
    _current = _makeSet();
    _fromTheme = _current.theme;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion && _fade.isAnimating) _finishFade();
    _syncTicker();
  }

  @override
  void didUpdateWidget(WeatherBackground old) {
    super.didUpdateWidget(old);
    _fade.duration = widget.transitionDuration;
    if (widget.scene != _current.scene || _isDay != _current.isDay) {
      _transition();
    }
    if (widget.debugFixedTime != null) _clock.value = widget.debugFixedTime!;
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setTimings(false);
    if (_tickerCounted) {
      _tickerCounted = false;
      WeatherBackground._runningTickers--;
    }
    _ticker.dispose();
    _curve.dispose();
    _fade.dispose();
    _clock.dispose();
    WeatherBackground._liveStates--;
    super.dispose();
  }

  void _transition() {
    final _LayerSet next = _makeSet();
    final double c = _curve.value;
    _fromTheme = SceneTheme.lerp(_fromTheme, _current.theme, c);
    final _LayerSet? prev = _previous;
    if (prev != null) {
      // Giu lai bo lop dang hien ro hon de khong bi nhay.
      final double prevVis = _prevStartOpacity * (1 - c);
      if (prevVis >= c) {
        _prevStartOpacity = prevVis;
      } else {
        _previous = _current;
        _prevStartOpacity = c;
      }
    } else {
      _previous = _current;
      _prevStartOpacity = 1;
    }
    _current = next;
    if (_reduceMotion || widget.transitionDuration == Duration.zero) {
      _finishFade();
    } else {
      _fade.forward(from: 0);
    }
  }

  void _finishFade() {
    _fade.value = 1;
    _previous = null;
    _fromTheme = _current.theme;
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null && mounted) {
      setState(() {
        _previous = null;
        _fromTheme = _current.theme;
      });
    }
  }

  void _syncTicker() {
    final bool shouldRun =
        !_reduceMotion && widget.debugFixedTime == null && _appVisible;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
      if (!_tickerCounted) {
        _tickerCounted = true;
        WeatherBackground._runningTickers++;
      }
      _setTimings(true);
    } else if (!shouldRun && _ticker.isActive) {
      _base = _clock.value;
      _ticker.stop();
      if (_tickerCounted) {
        _tickerCounted = false;
        WeatherBackground._runningTickers--;
      }
      _setTimings(false);
    }
  }

  void _onTick(Duration elapsed) {
    _clock.value = _base + elapsed.inMicroseconds / 1e6;
  }

  void _setTimings(bool on) {
    if (on == _timingsOn) return;
    _timingsOn = on;
    _timingFrames = 0;
    _timingSumUs = 0;
    if (on) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _timingSumUs +=
          t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds;
      _timingFrames++;
    }
    // ~1 s o 60 Hz.
    if (_timingFrames < 60) return;
    final double avgMs = _timingSumUs / _timingFrames / 1000;
    _timingFrames = 0;
    _timingSumUs = 0;
    if (avgMs <= WeatherBackground.slowFrameMs) return;
    final ValueNotifier<double> q = WeatherBackground.qualityScale;
    for (final double step in WeatherBackground.qualitySteps) {
      if (step < q.value - 1e-6) {
        q.value = step;
        return;
      }
    }
  }

  Widget _layers(_LayerSet set, double quality) => _SceneLayers(
    theme: set.theme,
    clock: _clock,
    windSpeedKmh: widget.windSpeedKmh,
    intensity: widget.intensity,
    quality: quality,
    seed: widget.seed,
    reduceMotion: _reduceMotion,
    splashTargets: widget.splashTargets,
    splashEdge: widget.splashEdge,
    lightningHaptics: widget.lightningHaptics,
    celestial: widget.celestial,
  );

  @override
  Widget build(BuildContext context) {
    final _LayerSet? prev = _previous;
    return ValueListenableBuilder<double>(
      valueListenable: WeatherBackground.qualityScale,
      builder: (context, q, _) {
        final double quality = widget.lowPower
            ? WeatherBackground.qualitySteps.last
            : q;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              key: const ValueKey<String>('wb-gradient'),
              animation: _curve,
              builder: (context, _) {
                final SceneTheme th = SceneTheme.lerp(
                  _fromTheme,
                  _current.theme,
                  _curve.value,
                );
                return DecoratedBox(
                  decoration: BoxDecoration(gradient: th.linearGradient),
                  child: ColoredBox(color: th.overlay),
                );
              },
            ),
            if (prev != null)
              FadeTransition(
                key: ValueKey<int>(prev.id),
                opacity: _curve.drive(
                  Tween<double>(begin: _prevStartOpacity, end: 0),
                ),
                child: _layers(prev, quality),
              ),
            FadeTransition(
              key: ValueKey<int>(_current.id),
              opacity: _curve,
              child: _layers(_current, quality),
            ),
            AnimatedBuilder(
              key: const ValueKey<String>('wb-scrim'),
              animation: _curve,
              builder: (context, _) {
                final double a = SceneTheme.lerp(
                  _fromTheme,
                  _current.theme,
                  _curve.value,
                ).contrastScrim;
                return IgnorePointer(
                  child: ColoredBox(
                    color: const Color(0xFF000000).withValues(alpha: a),
                  ),
                );
              },
            ),
            if (widget.child != null)
              KeyedSubtree(
                key: const ValueKey<String>('wb-child'),
                child: widget.child!,
              ),
          ],
        );
      },
    );
  }
}

/// Lop hat (bi an khi giam chuyen dong).
const Set<SceneLayer> _particleLayers = {
  SceneLayer.shootingStar,
  SceneLayer.drizzle,
  SceneLayer.rain,
  SceneLayer.heavyRain,
  SceneLayer.lightning,
  SceneLayer.snow,
  SceneLayer.sleet,
  SceneLayer.windStreaks,
};

class _SceneLayers extends StatelessWidget {
  const _SceneLayers({
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
            if (!reduceMotion || !_particleLayers.contains(layer))
              RepaintBoundary(
                key: ValueKey<SceneLayer>(layer),
                child: _LayerView(
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

class _LayerView extends StatefulWidget {
  const _LayerView({
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
  State<_LayerView> createState() => _LayerViewState();
}

class _LayerViewState extends State<_LayerView> {
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
  void didUpdateWidget(_LayerView old) {
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
