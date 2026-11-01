import 'package:flutter/material.dart';

import '../../models/units.dart';
import '../../services/route_service.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import 'route_endpoint_badge.dart';
import 'trip_helpers.dart';

class RouteWeatherDetails extends StatelessWidget {
  const RouteWeatherDetails({
    super.key,
    required this.route,
    required this.units,
    required this.fromLabel,
    required this.toLabel,
  });

  final TripRoute route;
  final UnitPrefs units;
  final String fromLabel;
  final String toLabel;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final style = TypeScale.body.copyWith(color: Palette.white);
    final metrics =
        <
          ({
            String label,
            double? Function(RouteSample) read,
            String Function(double) format,
          })
        >[
          (
            label: 'Nhiệt độ',
            read: (s) => s.temperature,
            format: units.tempText,
          ),
          (
            label: 'Độ ẩm',
            read: (s) => _valid(s.humidity, max: 100),
            format: (v) => '${v.round()}%',
          ),
          (
            label: 'Gió',
            read: (s) => _valid(s.windSpeed),
            format: units.windText,
          ),
          (
            label: 'Gió giật',
            read: (s) => _valid(s.windGusts),
            format: units.windText,
          ),
          (
            label: 'UV',
            read: (s) => _valid(s.uvIndex),
            format: (v) => v.toStringAsFixed(1),
          ),
          (
            label: 'Khả năng mưa',
            read: (s) => s.hasValidRainProbability ? s.rainProbability : null,
            format: (v) => '${(v * 100).round()}%',
          ),
          (
            label: 'Lượng mưa',
            read: (s) => s.hasValidRainAmount ? s.precipitation : null,
            format: units.rainRateText,
          ),
        ];

    Widget endpoint(bool destination) {
      final sample = route.samples.isEmpty
          ? null
          : destination
          ? route.samples.last
          : route.samples.first;
      final eta = destination ? route.arriveAt : route.departAt;
      final source = switch (sample?.source) {
        'ai' => 'AI của nhóm',
        'observed' => 'Dữ liệu phân tích',
        'forecast' => 'Dự báo',
        _ => 'Chưa có nguồn dữ liệu',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RouteEndpointBadge(destination: destination),
              const SizedBox(width: Space.s),
              Expanded(
                child: Text(
                  destination ? 'Điểm đến · $toLabel' : fromLabel,
                  style: TypeScale.headline.copyWith(color: Palette.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            '${formatHhmm(eta)} · $source',
            style: TypeScale.caption1.copyWith(color: ink.secondary),
          ),
          const SizedBox(height: Space.s),
          for (final metric in metrics)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Text(
                '${metric.label}: ${_text(sample, metric.read, metric.format)}',
                style: style,
              ),
            ),
        ],
      );
    }

    final along = <String>[];
    for (final metric in metrics.take(4)) {
      final values = [
        for (final sample in route.samples)
          if (_value(sample, metric.read) case final double v) v,
      ]..sort();
      if (values.isEmpty) continue;
      final low = metric.format(values.first);
      final high = metric.format(values.last);
      final range = low == high ? low : '$low – $high';
      final partial = values.length == route.samples.length
          ? ''
          : ' (${values.length}/${route.samples.length} điểm)';
      along.add('${metric.label}: $range$partial');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (along.isNotEmpty) ...[
          Text('Dọc tuyến · ${along.join(' · ')}', style: style),
          const SizedBox(height: Space.m),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 560 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: endpoint(false)),
                  const SizedBox(width: Space.l),
                  Expanded(child: endpoint(true)),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                endpoint(false),
                const Divider(height: Space.xl, color: Palette.divider),
                endpoint(true),
              ],
            );
          },
        ),
        const SizedBox(height: Space.s),
        Text(
          'Theo ô lưới và giờ gần nhất lúc đi qua, không phải đo tại chỗ.',
          style: TypeScale.caption1.copyWith(color: ink.secondary),
        ),
      ],
    );
  }

  static double? _valid(double? value, {double? max}) =>
      value != null && value >= 0 && (max == null || value <= max)
      ? value
      : null;

  static double? _value(
    RouteSample? sample,
    double? Function(RouteSample) read,
  ) {
    if (sample == null || !sample.forecastAvailable) return null;
    final value = read(sample);
    return value != null && value.isFinite ? value : null;
  }

  static String _text(
    RouteSample? sample,
    double? Function(RouteSample) read,
    String Function(double) format,
  ) {
    final value = _value(sample, read);
    return value == null ? 'Chưa có dữ liệu' : format(value);
  }
}
