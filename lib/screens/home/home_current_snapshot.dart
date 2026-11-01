import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/weather.dart';
import '../../providers/preferences_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/metric_tile.dart';
import '../../utils/formatters.dart';

/// Cot "Điều kiện hiện tại" o man rong (hai cot).
class HomeCurrentSnapshot extends StatelessWidget {
  const HomeCurrentSnapshot({
    super.key,
    required this.current,
    required this.onShowAll,
  });

  final CurrentWeather current;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final units = PreferencesProvider.unitsOf(context);
    final visible =
        PreferencesProvider.maybeOf(context)?.visibleMetrics ??
        HomeMetric.values;
    final rows = [
      (
        HomeMetric.feelsLike,
        Icons.thermostat_outlined,
        'Cảm giác như',
        current.feelsLike == null
            ? kNoData
            : units.tempText(current.feelsLike!),
      ),
      (
        HomeMetric.wind,
        Icons.air_rounded,
        'Gió',
        units.windText(current.windSpeed),
      ),
      (
        HomeMetric.humidity,
        Icons.water_drop_outlined,
        'Độ ẩm',
        current.humidity == null
            ? kNoData
            : WeatherFormat.percent(current.humidity),
      ),
    ].where((row) => visible.contains(row.$1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Điều kiện hiện tại',
            style: TypeScale.title3.copyWith(color: Palette.white),
          ),
        ),
        const SizedBox(height: Space.m),
        for (final row in rows) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(row.$2, size: 20, color: Palette.white),
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        row.$3,
                        style: TypeScale.subhead.copyWith(color: Palette.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s),
                Text(
                  row.$4,
                  style: TypeScale.title2.copyWith(
                    fontFeatures: TypeScale.tabular,
                    color: Palette.white,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Palette.divider, height: 1),
        ],
        const SizedBox(height: Space.s),
        TextButton.icon(
          onPressed: onShowAll,
          icon: const Icon(CupertinoIcons.forward),
          label: const Text('Tất cả chỉ số'),
          style: TextButton.styleFrom(
            foregroundColor: Palette.white,
            minimumSize: const Size(48, 48),
          ),
        ),
      ],
    );
  }
}
