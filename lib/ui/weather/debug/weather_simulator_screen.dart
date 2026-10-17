/// Man hinh "Gia lap thoi tiet" (chi dung khi debug).
library;

import 'dart:ui' show FramePhase, ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../weather_background.dart';
import '../weather_icons.dart';

/// Xem truoc moi canh thoi tiet va ap dung gia lap cho toan app qua
/// [SceneOverride]. Chi mo khi [available] (ban debug).
class WeatherSimulatorScreen extends StatefulWidget {
  const WeatherSimulatorScreen({
    super.key,
    required this.sceneOverride,
    this.initialScene = WeatherScene.clearDay,
  });

  /// Gia lap dung chung cua app (Home cung cap).
  final SceneOverride sceneOverride;

  /// Canh hien luc mo neu chua co gia lap.
  final WeatherScene initialScene;

  /// Chi bat trong ban debug.
  static bool get available => kDebugMode;

  @override
  State<WeatherSimulatorScreen> createState() => _WeatherSimulatorScreenState();
}

class _WeatherSimulatorScreenState extends State<WeatherSimulatorScreen> {
  late WeatherScene _scene;
  late bool _isDay;
  late double _wind;
  late double _intensity;

  double _fps = 0;
  int _frames = 0;
  int _firstTs = 0;

  @override
  void initState() {
    super.initState();
    final SceneOverride o = widget.sceneOverride;
    _scene = o.scene ?? widget.initialScene;
    _isDay = o.isDay ?? !_scene.isNightVariant;
    _wind = (o.windSpeedKmh ?? 10).clamp(0.0, 80.0);
    _intensity = (o.intensity ?? 1.0).clamp(0.3, 1.5);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      final int ts = t.timestampInMicroseconds(FramePhase.vsyncStart);
      if (_frames == 0) _firstTs = ts;
      _frames++;
      final int span = ts - _firstTs;
      if (span >= 1000000) {
        final double fps = (_frames - 1) * 1e6 / span;
        _frames = 0;
        if (mounted && (fps - _fps).abs() >= 0.5) setState(() => _fps = fps);
      }
    }
  }

  WeatherScene get _preview => _scene.withDaytime(_isDay);

  void _apply() {
    widget.sceneOverride.set(
      scene: _preview,
      isDay: _isDay,
      windSpeedKmh: _wind,
      intensity: _intensity,
    );
    _toast('Đã áp dụng "${_preview.label}" cho ứng dụng');
  }

  void _clear() {
    widget.sceneOverride.clear();
    _toast('Đã bỏ giả lập, dùng thời tiết thật');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final WeatherScene scene = _preview;
    final SceneTheme th = SceneTheme.of(scene, isDay: _isDay);
    const TextStyle body = TextStyle(color: Colors.white, fontSize: 15);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: th.statusBar,
      child: Scaffold(
        backgroundColor: th.gradient.first,
        body: WeatherBackground(
          scene: scene,
          isDay: _isDay,
          windSpeedKmh: _wind,
          intensity: _intensity,
          child: SafeArea(
            child: Column(
              children: [
                _TopBar(onBack: () => Navigator.maybePop(context)),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WeatherIcon(scene: scene, size: 64),
                        const SizedBox(height: 8),
                        Text(
                          scene.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Gió ${_wind.round()} km/h · cường độ '
                          '${_intensity.toStringAsFixed(1)}',
                          style: body,
                        ),
                      ],
                    ),
                  ),
                ),
                _GlassPanel(theme: th, child: _controls(th, body)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(SceneTheme th, TextStyle body) {
    final SliderThemeData slider = SliderTheme.of(context).copyWith(
      activeTrackColor: th.accent,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
      thumbColor: Colors.white,
      overlayColor: Colors.white.withValues(alpha: 0.12),
      valueIndicatorColor: th.glassTint,
    );
    return SliderTheme(
      data: slider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Cảnh thời tiết',
            style: body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final WeatherScene s in WeatherScene.values)
                _SceneChip(
                  scene: s,
                  selected: s.withDaytime(_isDay) == _preview && s == _scene,
                  onTap: () => setState(() {
                    _scene = s;
                    if (s.isDayVariant) _isDay = true;
                    if (s.isNightVariant) _isDay = false;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_isDay ? 'Ban ngày' : 'Ban đêm', style: body),
            subtitle: Text(
              'Bật = ngày, tắt = đêm',
              style: body.copyWith(fontSize: 13, color: Colors.white70),
            ),
            value: _isDay,
            activeThumbColor: Colors.white,
            activeTrackColor: th.accent.withValues(alpha: 0.7),
            onChanged: (v) => setState(() {
              _isDay = v;
              _scene = _scene.withDaytime(v);
            }),
          ),
          Text('Gió: ${_wind.round()} km/h', style: body),
          Slider(
            value: _wind,
            min: 0,
            max: 80,
            divisions: 16,
            label: '${_wind.round()} km/h',
            semanticFormatterCallback: (v) => 'Gió ${v.round()} ki lô mét giờ',
            onChanged: (v) => setState(() => _wind = v),
          ),
          Text('Cường độ: ${_intensity.toStringAsFixed(1)}', style: body),
          Slider(
            value: _intensity,
            min: 0.3,
            max: 1.5,
            divisions: 12,
            label: _intensity.toStringAsFixed(1),
            onChanged: (v) => setState(() => _intensity = v),
          ),
          ValueListenableBuilder<double>(
            valueListenable: WeatherBackground.qualityScale,
            builder: (context, q, _) => Row(
              children: [
                Expanded(
                  child: Text(
                    'Hiệu năng: ${_fps == 0 ? '--' : _fps.toStringAsFixed(0)} fps'
                    ' · chất lượng ${(q * 100).round()}%',
                    style: body.copyWith(fontSize: 13),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(44, 44),
                  ),
                  onPressed: q < 1 ? WeatherBackground.resetQuality : null,
                  child: const Text('Đặt lại'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: widget.sceneOverride,
            builder: (context, _) => Text(
              widget.sceneOverride.active
                  ? 'Ứng dụng đang giả lập: '
                        '${effectiveScene(WeatherScene.cloudy, widget.sceneOverride).label}'
                  : 'Ứng dụng đang dùng thời tiết thật',
              style: body.copyWith(fontSize: 13, color: Colors.white70),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF0B1026),
                    minimumSize: const Size(44, 48),
                  ),
                  onPressed: _apply,
                  child: const Text('Áp dụng cho ứng dụng'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ListenableBuilder(
                  listenable: widget.sceneOverride,
                  builder: (context, _) => OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white70),
                      minimumSize: const Size(44, 48),
                    ),
                    onPressed: widget.sceneOverride.active ? _clear : null,
                    child: const Text('Bỏ giả lập'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Quay lại',
            color: Colors.white,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const Expanded(
            child: Text(
              'Giả lập thời tiết',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'DEBUG',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.theme, required this.child});

  final SceneTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double maxH = MediaQuery.sizeOf(context).height * 0.58;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            constraints: BoxConstraints(maxHeight: maxH),
            decoration: BoxDecoration(
              color: theme.glassTint.withValues(
                alpha: (theme.glassAlpha + 0.12).clamp(0.0, 1.0),
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            // Material trong suot de ListTile / InkWell ve hieu ung tren the.
            child: Material(
              type: MaterialType.transparency,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SceneChip extends StatelessWidget {
  const _SceneChip({
    required this.scene,
    required this.selected,
    required this.onTap,
  });

  final WeatherScene scene;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.12),
        shape: StadiumBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  WeatherIcon(
                    scene: scene,
                    size: 20,
                    color: selected ? const Color(0xFF0B1026) : null,
                    semanticLabel: '',
                  ),
                  const SizedBox(width: 6),
                  Text(
                    scene.label,
                    style: TextStyle(
                      color: selected ? const Color(0xFF0B1026) : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
