part of '../ai_forecast_card.dart';

/// Mot cot moc du bao (khong co nen rieng - tranh "the trong the").
class _PredictionColumn extends StatelessWidget {
  final AIPrediction prediction;
  final AIForecast forecast;

  /// Mien nhiet do (do C) chung cho thanh khoang; null = khong ve.
  final (double, double)? domain;

  const _PredictionColumn({
    required this.prediction,
    required this.forecast,
    this.domain,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    final units = PreferencesProvider.unitsOf(context);
    final ink = GlassInk.of(context);
    final p = prediction;
    final target = p.targetTime;
    final targetText = target == null
        ? 'Sau ${p.timeLabel}'
        : ForecastFormat.targetTime(target, provider.nowHcm);
    final showInterval =
        forecast.isEnabled('temperature_interval') && p.hasInterval;
    final showRain = forecast.isEnabled('rain_probability');
    String t(double c) => units.tempNumber(c);
    final rangeText = showInterval
        ? '${t(p.intervalLow!)}–${t(p.intervalHigh!)}°'
        : null;

    final extras = <(IconData, String, String)>[
      if (forecast.isEnabled('humidity') && p.humidity != null)
        (Icons.opacity_rounded, 'Ẩm', '${p.humidity!.round()}%'),
      if (forecast.isEnabled('wind_speed') && p.windSpeed != null)
        (Icons.air_rounded, 'Gió', units.windText(p.windSpeed)),
      if (forecast.isEnabled('wind_gusts') && p.windGusts != null)
        (Icons.storm_outlined, 'Giật', units.windText(p.windGusts)),
      if (forecast.isEnabled('precipitation_mm') && p.precipitationMm != null)
        (Icons.umbrella_outlined, 'Mưa', units.rainText(p.precipitationMm)),
    ];

    final semantics = StringBuffer(
      'Lúc $targetText (sau ${p.timeLabel}): '
      '${units.tempText(p.temperature)}',
    );
    if (rangeText != null) {
      semantics.write(
        ', ${intervalLevelLabel(p.effectiveIntervalLevel)} từ '
        '${t(p.intervalLow!)} đến ${t(p.intervalHigh!)} độ',
      );
    }
    if (showRain) semantics.write(', khả năng mưa ${p.rainPercent}%');
    for (final e in extras) {
      semantics.write(', ${e.$2.toLowerCase()} ${e.$3}');
    }

    final small = TypeScale.footnote.copyWith(
      color: ink.secondary,
      fontFeatures: kTabular,
    );

    return Semantics(
      label: semantics.toString(),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SAU ${p.timeLabel.toUpperCase()}',
            style: TypeScale.cardTitle.copyWith(color: ink.title),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              targetText,
              style: TypeScale.subhead.copyWith(
                fontWeight: FontWeight.w600,
                color: Palette.white,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${t(p.temperature)}°',
              style: TypeScale.bigValue.copyWith(color: Palette.white),
            ),
          ),
          if (rangeText != null) ...[
            Text(
              '($rangeText)',
              style: small.copyWith(
                fontWeight: FontWeight.w600,
                color: Palette.white,
              ),
            ),
            if (domain != null) ...[
              const SizedBox(height: Space.xs),
              _IntervalBar(
                domain: domain!,
                low: p.intervalLow!,
                high: p.intervalHigh!,
                point: p.temperature,
                color: ink.accent,
              ),
            ],
          ],
          const SizedBox(height: Space.s),
          if (showRain) ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.water_drop_outlined, size: 14, color: ink.rain),
                  const SizedBox(width: 2),
                  Text(
                    '${p.rainPercent}%',
                    style: TypeScale.footnote.copyWith(
                      fontWeight: FontWeight.w700,
                      color: ink.rain,
                      fontFeatures: kTabular,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.xs),
            _RainBar(percent: p.rainPercent, color: ink.rain),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: Space.s),
            for (final e in extras)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(e.$1, size: 14, color: ink.secondary),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        // Giu so + don vi tren cung dong khi xuong dong.
                        '${e.$2} ${e.$3.replaceAll(' ', String.fromCharCode(0x00A0))}',
                        style: small,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

/// Thanh nho: vach khoang nhiet do tren mien chung cua 3 moc, cham = gia tri du bao.
class _IntervalBar extends StatelessWidget {
  const _IntervalBar({
    required this.domain,
    required this.low,
    required this.high,
    required this.point,
    required this.color,
  });

  final (double, double) domain;
  final double low;
  final double high;
  final double point;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // CustomPaint thay LayoutBuilder: cot nam trong IntrinsicHeight.
    return SizedBox(
      height: 8,
      width: double.infinity,
      child: CustomPaint(
        painter: _IntervalPainter(
          domain: domain,
          low: low,
          high: high,
          point: point,
          color: color,
        ),
      ),
    );
  }
}

class _IntervalPainter extends CustomPainter {
  _IntervalPainter({
    required this.domain,
    required this.low,
    required this.high,
    required this.point,
    required this.color,
  });

  final (double, double) domain;
  final double low;
  final double high;
  final double point;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final (lo, hi) = domain;
    final span = hi - lo;
    final w = size.width;
    double x(double v) =>
        (span <= 0 ? 0.5 : ((v - lo) / span).clamp(0.0, 1.0)) * w;
    final cy = size.height / 2;
    final r = const Radius.circular(Radii.bar);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - 2, w, 4), r),
      Paint()..color = Palette.track,
    );
    final a = x(low);
    final b = math.max(x(high), math.min(a + 4, w));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(a, cy - 2, b, cy + 2), r),
      Paint()..color = color,
    );
    final px = x(point).clamp(4.0, math.max(4.0, w - 4)).toDouble();
    canvas.drawCircle(Offset(px, cy), 4, Paint()..color = Palette.white);
  }

  @override
  bool shouldRepaint(_IntervalPainter old) =>
      old.domain != domain ||
      old.low != low ||
      old.high != high ||
      old.point != point ||
      old.color != color;
}

class _RainBar extends StatelessWidget {
  final int percent;
  final Color color;

  const _RainBar({required this.percent, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.bar),
      child: SizedBox(
        height: 4,
        width: double.infinity,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Palette.track)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: percent.clamp(0, 100) / 100,
              heightFactor: 1,
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
