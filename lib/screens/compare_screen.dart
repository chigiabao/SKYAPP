/// So sanh thoi tiet giua 2-3 dia diem: cot kinh canh nhau (hien tai) va
/// bieu do nhiet do 24 gio toi tren cung truc, co chu giai (mau + nhan +
/// kieu net + hinh diem, khong chi dua vao mau).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/weather_icons.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import 'forecast/forecast_format.dart';

/// Kieu cua mot chuoi so sanh.
@immutable
class CompareSeriesStyle {
  const CompareSeriesStyle(this.color, this.dash, this.shape, this.shapeName);

  final Color color;

  /// null = net lien.
  final List<int>? dash;
  final CompareDotShape shape;

  /// Ten kieu (cho trinh doc man hinh / chu giai).
  final String shapeName;

  static const List<CompareSeriesStyle> all = [
    CompareSeriesStyle(Color(0xFF7DD3FC), null, CompareDotShape.circle, 'nét liền'),
    CompareSeriesStyle(Color(0xFFFCD34D), [8, 5], CompareDotShape.square, 'nét đứt'),
    CompareSeriesStyle(
      Color(0xFFF0ABFC),
      [2, 4],
      CompareDotShape.triangle,
      'nét chấm',
    ),
  ];
}

enum CompareDotShape { circle, square, triangle }

/// Kha nang mua lon nhat (%) trong 3 gio toi; null neu khong co.
int? rainNext3h(List<HourlyForecast> hours, DateTime nowHcm) {
  final start = HcmTime.startOfHour(nowHcm);
  final end = start.add(const Duration(hours: 3));
  int? best;
  for (final h in hours) {
    if (h.time.isBefore(start) || !h.time.isBefore(end)) continue;
    if (h.rainProbability == null) continue;
    best = math.max(best ?? 0, h.rainPercent);
  }
  return best;
}

class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.locations,
    required this.locationIds,
  });

  final LocationProvider locations;
  final List<String> locationIds;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  final Map<String, WeatherResult> _data = {};
  final Map<String, ApiException> _errors = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final wp = context.read<WeatherProvider>();
    setState(() {
      _loading = true;
      _errors.clear();
    });
    Future<void> one(String id) async {
      try {
        _data[id] = await wp.fetchWeatherFor(id);
      } on ApiException catch (e) {
        _errors[id] = e;
      } catch (e) {
        debugPrint('CompareScreen: $e');
        _errors[id] = ApiException(ApiErrorKind.invalidData);
      }
    }

    await Future.wait([for (final id in widget.locationIds) one(id)]);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final wp = context.watch<WeatherProvider>();
    final lp = widget.locations;
    final ids = widget.locationIds.take(CompareSeriesStyle.all.length).toList();
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;

    final series = <CompareSeries>[
      for (var i = 0; i < ids.length; i++)
        CompareSeries(
          place: lp.placeById(ids[i]),
          label: _labelFor(lp, ids[i]),
          style: CompareSeriesStyle.all[i],
          result: _errors.containsKey(ids[i]) ? null : _data[ids[i]],
          error: _errors[ids[i]],
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'So sánh',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < series.length; i++) ...[
                  if (i > 0) const SizedBox(width: Space.s),
                  Expanded(
                    child: _CompareColumn(
                      series: series[i],
                      loading: _loading && series[i].result == null,
                      provider: wp,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Space.cardGap),
          GlassCard(
            title: 'Nhiệt độ 24 giờ tới',
            icon: Icons.show_chart_rounded,
            footer:
                'Mỗi đường một địa điểm; xem chú giải để phân biệt '
                '(màu, kiểu nét và hình điểm).',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CompareLegend(series: series),
                const SizedBox(height: Space.m),
                SizedBox(
                  height: 220,
                  child: _loading && _data.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : CompareChart(series: series, provider: wp),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.m),
          Text(
            'Số liệu của mỗi địa điểm lấy theo ô dữ liệu ≈ 8 km chứa địa '
            'điểm; hai phường trong cùng ô sẽ giống nhau.',
            style: TypeScale.small.copyWith(
              fontSize: 13,
              color: GlassInk.of(context).headerSecondary,
            ),
          ),
        ],
      ),
    );
  }

  static String? _labelFor(LocationProvider lp, String id) {
    for (final s in lp.saved) {
      if (s.locationId == id) return s.labelText;
    }
    return id == lp.currentLocationId ? 'Vị trí hiện tại' : null;
  }
}

/// Mot dia diem trong so sanh.
class CompareSeries {
  CompareSeries({
    required this.place,
    required this.label,
    required this.style,
    required this.result,
    required this.error,
  });

  final Place place;
  final String? label;
  final CompareSeriesStyle style;
  final WeatherResult? result;
  final ApiException? error;

  WeatherData? get data => result?.data;
}

class _CompareColumn extends StatelessWidget {
  const _CompareColumn({
    required this.series,
    required this.loading,
    required this.provider,
  });

  final CompareSeries series;
  final bool loading;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final d = series.data;
    final c = d?.current;
    final now = provider.nowHcm;
    final small = TypeScale.small.copyWith(color: ink.secondary);
    final value = TypeScale.label.copyWith(
      color: Palette.white,
      fontWeight: FontWeight.w600,
      fontFeatures: kTabular,
    );
    Widget metric(String title, String v) => Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: small),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(v, style: value),
          ),
        ],
      ),
    );

    final rain = d == null ? null : rainNext3h(d.hourlyForecast, now);
    return GlassSurface(
      padding: const EdgeInsets.all(Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _LegendSwatch(style: series.style),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  series.place.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TypeScale.body.copyWith(
                    color: Palette.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Text(
            series.label ?? series.place.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small,
          ),
          if (series.result?.fromCache == true && c != null)
            Text('Dữ liệu cũ', style: small.copyWith(color: ink.warning)),
          const SizedBox(height: Space.s),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.l),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (c == null)
            Text(
              series.error?.message ?? 'Không tải được dữ liệu.',
              style: small.copyWith(color: Palette.white),
            )
          else ...[
            Row(
              children: [
                WeatherIcon.fromCode(
                  c.weatherCode,
                  isDay: isDayAt(now),
                  size: 28,
                ),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${provider.formatTempValue(c.temperature)}°',
                      style: TypeScale.bigValue.copyWith(color: Palette.white),
                    ),
                  ),
                ),
              ],
            ),
            metric(
              'Cảm giác',
              c.feelsLike == null
                  ? '--'
                  : '${provider.formatTempValue(c.feelsLike!)}°',
            ),
            metric('Mưa 3 giờ tới', rain == null ? '--' : '$rain%'),
            metric(
              'Gió',
              c.windSpeed == null ? '--' : '${c.windSpeed!.round()} km/h',
            ),
            metric('AQI (US)', c.usAqi == null ? '--' : '${c.usAqi}'),
          ],
        ],
      ),
    );
  }
}

/// Chu giai: mau + kieu net + hinh diem + ten.
class CompareLegend extends StatelessWidget {
  const CompareLegend({super.key, required this.series});

  final List<CompareSeries> series;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.l,
      runSpacing: Space.xs,
      children: [
        for (final s in series)
          Semantics(
            label: '${s.place.name}: ${s.style.shapeName}',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendSwatch(style: s.style),
                const SizedBox(width: Space.xs),
                Text(
                  s.place.name,
                  style: TypeScale.small.copyWith(color: Palette.white),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.style});

  final CompareSeriesStyle style;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(28, 12), painter: _SwatchPainter(style));
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.style);

  final CompareSeriesStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = style.color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final dash = style.dash;
    if (dash == null) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    } else {
      var x = 0.0;
      while (x < size.width) {
        final x2 = math.min(size.width, x + dash[0]);
        canvas.drawLine(Offset(x, y), Offset(x2, y), p);
        x = x2 + dash[1];
      }
    }
    _drawShape(canvas, style.shape, Offset(size.width / 2, y), 4, style.color);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.style != style;
}

void _drawShape(Canvas c, CompareDotShape s, Offset o, double r, Color color) {
  final fill = Paint()..color = color;
  final stroke = Paint()
    ..color = const Color(0xFF141C2B)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;
  switch (s) {
    case CompareDotShape.circle:
      c.drawCircle(o, r, fill);
      c.drawCircle(o, r, stroke);
    case CompareDotShape.square:
      final rect = Rect.fromCenter(center: o, width: 2 * r, height: 2 * r);
      c.drawRect(rect, fill);
      c.drawRect(rect, stroke);
    case CompareDotShape.triangle:
      final path = Path()
        ..moveTo(o.dx, o.dy - r - 1)
        ..lineTo(o.dx + r + 1, o.dy + r)
        ..lineTo(o.dx - r - 1, o.dy + r)
        ..close();
      c.drawPath(path, fill);
      c.drawPath(path, stroke);
  }
}

class _ShapeDotPainter extends FlDotPainter {
  _ShapeDotPainter(this.shape, this.color);

  final CompareDotShape shape;
  final Color color;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) =>
      _drawShape(canvas, shape, offsetInCanvas, 4, color);

  @override
  Size getSize(FlSpot spot) => const Size(10, 10);

  @override
  Color get mainColor => color;

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) => b;

  @override
  List<Object?> get props => [shape, color];
}

/// Bieu do nhiet do 24 gio toi cua cac dia diem tren cung truc.
class CompareChart extends StatelessWidget {
  const CompareChart({super.key, required this.series, required this.provider});

  final List<CompareSeries> series;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final start = HcmTime.startOfHour(provider.nowHcm);
    double conv(double c) => provider.isCelsius ? c : c * 9 / 5 + 32;
    final bars = <LineChartBarData>[];
    final drawn = <CompareSeries>[];
    final all = <double>[];
    for (final s in series) {
      final hours = s.data?.hourlyForecast ?? const <HourlyForecast>[];
      final spots = <FlSpot>[];
      for (final h in hours) {
        final x = h.time.difference(start).inMinutes / 60;
        if (x < 0 || x > 23) continue;
        final y = conv(h.temperature);
        spots.add(FlSpot(x, y));
        all.add(y);
      }
      if (spots.isEmpty) continue;
      drawn.add(s);
      bars.add(
        LineChartBarData(
          spots: spots,
          isCurved: true,
          preventCurveOverShooting: true,
          color: s.style.color,
          barWidth: 2.5,
          dashArray: s.style.dash,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show: true,
            checkToShowDot: (spot, _) => spot.x.round() % 4 == 0,
            getDotPainter: (spot, p, bar, i) =>
                _ShapeDotPainter(s.style.shape, s.style.color),
          ),
        ),
      );
    }
    if (bars.isEmpty) {
      return Center(
        child: Text(
          'Chưa có dữ liệu theo giờ để vẽ biểu đồ.',
          style: TypeScale.body.copyWith(color: Palette.white),
        ),
      );
    }
    final lo = (all.reduce(math.min) - 1).floorToDouble();
    final hi = (all.reduce(math.max) + 1).ceilToDouble();
    final step = math.max(1, ((hi - lo) / 4).ceil()).toDouble();
    final axis = TypeScale.small.copyWith(color: ink.secondary);
    final unit = provider.tempUnit.replaceAll('C', '').replaceAll('F', '');
    return Semantics(
      label:
          'Biểu đồ nhiệt độ 24 giờ tới của ${series.length} địa điểm, '
          'từ ${lo.round()}$unit đến ${hi.round()}$unit',
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: 23,
          minY: lo,
          maxY: hi,
          clipData: const FlClipData.horizontal(),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: step,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: Color(0x29FFFFFF), strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: step,
                getTitlesWidget: (v, meta) => v == meta.min || v == meta.max
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text('${v.round()}°', style: axis),
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (v != i || i % 4 != 0) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      ForecastFormat.hourShort(start.add(Duration(hours: i))),
                      style: axis,
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => const Color(0xF0141C2B),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${drawn[s.barIndex].place.name}: '
                    '${s.y.round()}°',
                    TypeScale.small.copyWith(color: Palette.white),
                  ),
              ],
            ),
          ),
          lineBarsData: bars,
        ),
      ),
    );
  }
}
