import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/units.dart';
import '../models/weather.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import '../widgets/ai_forecast_card.dart';
import 'forecast/forecast_charts.dart';
import 'forecast/forecast_format.dart';

/// Kiem chung du bao AI: moi moc (1h/3h/6h) so du bao voi "thuc te"
/// (du lieu phan tich cua mo hinh, khong phai tram do). Dung thoi diem
/// "hien tai" cua app (che do xem lai -> thoi diem xem lai).
class AIVerifyScreen extends StatefulWidget {
  const AIVerifyScreen({super.key, this.intervalLoader});

  /// Tai lai ban du bao AI phat hanh luc [issuedAt] de lay khoang 90%
  /// (ai-verify khong gui khoang). null = mac dinh: GET /weather/ai-forecast
  /// ?at= cho dia diem mac dinh; dia diem khac -> khong ve dai (khong bia).
  final Future<AIForecast?> Function(DateTime issuedAt)? intervalLoader;

  @override
  State<AIVerifyScreen> createState() => _AIVerifyScreenState();
}

class _AIVerifyScreenState extends State<AIVerifyScreen> {
  Future<AIVerification>? _future;
  Future<AIForecast?>? _intervals;
  DateTime? _intervalsFor;

  Future<AIForecast?> _intervalsOf(WeatherProvider p, DateTime issuedAt) {
    if (_intervals != null && _intervalsFor == issuedAt) return _intervals!;
    _intervalsFor = issuedAt;
    final loader = widget.intervalLoader;
    return _intervals = loader != null
        ? loader(issuedAt)
        : p.locationId == Place.defaultId
        ? ApiService().fetchAIForecast(at: issuedAt).catchError((_) => null)
        : Future.value(null);
  }

  /// Thoi diem xem lai ung voi [_future] (null = truc tiep).
  DateTime? _loadedFor;
  String? _loadedLocation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) _load(context.read<WeatherProvider>());
  }

  void _load(WeatherProvider p) {
    _loadedFor = p.isReplay ? p.replayAt : null;
    _loadedLocation = p.locationId;
    _intervals = null;
    _intervalsFor = null;
    _future = p.fetchAIVerification();
  }

  void _reload() => setState(() => _load(context.read<WeatherProvider>()));

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  /// Noi dung (context nam duoi theme kinh cua GlassPage).
  Widget _buildPage(BuildContext context) {
    final provider = context.watch<WeatherProvider>();
    // Bat/tat xem lai khi man hinh dang mo -> tai lai cho thoi diem moi
    final key = provider.isReplay ? provider.replayAt : null;
    if (key != _loadedFor || provider.locationId != _loadedLocation) {
      _load(provider);
    }
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Kiểm chứng dự báo AI',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<AIVerification>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return _ErrorView(error: snap.error, onRetry: _reload);
          }
          final data = snap.data!;
          return FutureBuilder<AIForecast?>(
            future: _intervalsOf(provider, data.issuedAt),
            builder: (context, iv) => _VerifyBody(
              data: data,
              provider: provider,
              issued: iv.connectionState == ConnectionState.done
                  ? iv.data
                  : null,
            ),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final String message;
    if (e is ApiException && e.kind == ApiErrorKind.notFound) {
      message =
          'Máy chủ chưa hỗ trợ kiểm chứng dự báo AI, '
          'hoặc chưa có bản dự báo nào cho thời điểm này.';
    } else if (e is ApiException) {
      message = e.message;
    } else {
      message = ApiException.messageFor(ApiErrorKind.invalidData);
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSizes.paddingL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: AppSizes.iconSizeL,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
            const SizedBox(height: AppSizes.paddingM),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSizes.paddingM),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerifyBody extends StatelessWidget {
  const _VerifyBody({required this.data, required this.provider, this.issued});

  final AIVerification data;
  final WeatherProvider provider;

  /// Ban du bao goc (cung luc phat hanh) - chi de lay khoang 90%.
  final AIForecast? issued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = provider.nowHcm;
    final noneAvailable = data.horizons.every((h) => !h.hasActual);
    final original = issued;
    final match =
        original != null &&
            original.issuedAt == data.issuedAt &&
            original.modelVersion == data.modelVersion &&
            original.isEnabled('temperature_interval')
        ? original
        : null;

    return ListView(
      padding: const EdgeInsets.all(AppSizes.paddingM),
      children: [
        _VerdictCard(data: data, provider: provider),
        if (data.horizons.any((h) => h.predictedTemperature != null)) ...[
          const SizedBox(height: AppSizes.paddingM),
          _VerifyChart(data: data, issued: match, provider: provider),
        ],
        const SizedBox(height: AppSizes.paddingM),
        if (data.horizons.isEmpty)
          const Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.all(AppSizes.paddingM),
              child: Text('Chưa có mốc nào để kiểm chứng.'),
            ),
          ),
        for (final h in data.horizons) ...[
          _HorizonCard(item: h, nowHcm: now, provider: provider),
          const SizedBox(height: AppSizes.paddingM),
        ],
        _NotesCard(showReplayTip: noneAvailable && !provider.isReplay),
        const SizedBox(height: AppSizes.paddingM),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: Text(
                'Chi tiết kỹ thuật',
                style: AppTextStyles.bodyLarge.copyWith(
                  color: theme.textTheme.bodyLarge?.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                'Sai số MAE, F1 mưa, độ phủ khoảng, phiên bản mô hình',
                style: theme.textTheme.bodySmall,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                AppSizes.paddingM,
                0,
                AppSizes.paddingM,
                AppSizes.paddingM,
              ),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bản dự báo phát hành ${ForecastFormat.moment(data.issuedAt)}'
                  '${data.modelVersion.isEmpty ? '' : ' · ${data.modelVersion}'}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSizes.paddingS),
                _EvaluationCard(
                  evaluation: data.evaluation,
                  provider: provider,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Nhiet do 1 chu so thap phan theo don vi dang chon: "26,5°".
String _temp1(double celsius, WeatherProvider provider) {
  final v = provider.isCelsius ? celsius : celsius * 9 / 5 + 32;
  return '${v.toStringAsFixed(1).replaceAll('.', ',')}°';
}

/// Cau ket luan dau man (moc xa nhat da co thuc te) + dong phu.
class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.data, required this.provider});

  final AIVerification data;
  final WeatherProvider provider;

  /// Moc du bao khong phai so gio da troi qua ke tu luc phat hanh.
  static String? headline(AIVerification data, WeatherProvider provider) {
    final done = [
      for (final h in data.horizons)
        if (h.temperatureError != null &&
            h.predictedTemperature != null &&
            h.actualTemperature != null)
          h,
    ];
    if (done.isEmpty) return null;
    final h = done.last;
    return 'Mốc ${h.horizon}: AI dự báo '
        '${_temp1(h.predictedTemperature!, provider)}, thực tế '
        '${_temp1(h.actualTemperature!, provider)} – lệch '
        '${_degrees(h.temperatureError!, provider)}.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = headline(data, provider);
    final errors = [
      for (final h in data.horizons)
        if (h.temperatureError != null) h.temperatureError!,
    ];
    final sub = [
      'Bản dự báo lúc ${ForecastFormat.moment(data.issuedAt)}.',
      'Thực tế: phân tích mô hình Open-Meteo (không phải trạm đo).',
      if (errors.length > 1)
        'Lệch trung bình '
            '${_degrees(errors.reduce((a, b) => a + b) / errors.length, provider)}'
            ' (${errors.length}/${data.horizons.length} mốc).',
    ].join(' ');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                head ?? 'Chưa có số liệu thực tế để so với dự báo AI.',
                style: AppTextStyles.heading3.copyWith(
                  color: theme.textTheme.titleLarge?.color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: AppSizes.paddingXS),
            Text(sub, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSizes.paddingS),
            Text(
              AIEvaluationLine.text(data.evaluation, provider),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Du bao (net dut) so voi thuc te (net lien) tai cac moc; dai mo = khoang
/// cua ban du bao goc (neu tai duoc; khong co thi khong ve).
class _VerifyChart extends StatelessWidget {
  const _VerifyChart({
    required this.data,
    required this.issued,
    required this.provider,
  });

  final AIVerification data;
  final AIForecast? issued;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final p = ChartPalette(context);
    final c = provider.isCelsius;
    double u(double v) => c ? v : v * 9 / 5 + 32;
    final items = data.horizons;

    final pred = <FlSpot>[];
    final act = <FlSpot>[];
    final lo = <FlSpot>[];
    final hi = <FlSpot>[];
    final all = <double>[];
    for (var i = 0; i < items.length; i++) {
      final h = items[i];
      final x = i.toDouble();
      if (h.predictedTemperature case final v?) {
        pred.add(FlSpot(x, u(v)));
        all.add(u(v));
      } else {
        pred.add(FlSpot.nullSpot);
      }
      if (h.actualTemperature case final v?) {
        act.add(FlSpot(x, u(v)));
        all.add(u(v));
      } else {
        act.add(FlSpot.nullSpot);
      }
      final b = issued?.predictions
          .where((pr) => pr.timeLabel == h.horizon && pr.hasInterval)
          .firstOrNull;
      if (b != null) {
        lo.add(FlSpot(x, u(b.intervalLow!)));
        hi.add(FlSpot(x, u(b.intervalHigh!)));
        all
          ..add(u(b.intervalLow!))
          ..add(u(b.intervalHigh!));
      } else {
        lo.add(FlSpot.nullSpot);
        hi.add(FlSpot.nullSpot);
      }
    }
    final minY = (all.reduce(math.min) - 1).floorToDouble();
    final maxY = (all.reduce(math.max) + 1).ceilToDouble();
    final hasBand = lo.where((spot) => !spot.isNull()).length >= 2;
    final level = issued?.predictions
        .where((x) => x.hasInterval)
        .firstOrNull
        ?.effectiveIntervalLevel;
    final bandLabel = 'Dải ${intervalLevelLabel(level)}';
    final bandColor = (GlassThemeMarker.inkOf(context)?.accent ?? p.low)
        .withValues(alpha: 0.28);
    final actualColor = p.isDark || GlassThemeMarker.isGlass(context)
        ? Colors.white
        : const Color(0xFF0F172A);

    LineChartBarData edge(List<FlSpot> s) => LineChartBarData(
      spots: s,
      color: Colors.transparent,
      barWidth: 0,
      dotData: const FlDotData(show: false),
    );
    FlDotData dots(Color color) => FlDotData(
      getDotPainter: (s, _, _, _) =>
          FlDotCirclePainter(radius: 4, color: color, strokeWidth: 0),
    );

    return ChartFrame(
      height: 200,
      semanticsLabel:
          'Biểu đồ dự báo AI so với thực tế tại ${items.length} mốc'
          '${hasBand ? ', có $bandLabel' : ''}',
      footer: ChartLegend(
        items: [
          (p.high, 'Dự báo AI (nét đứt)', true),
          (actualColor, 'Thực tế', false),
          if (hasBand) (bandColor, bandLabel, false),
        ],
      ),
      child: LineChart(
        duration: p.duration,
        curve: kChartCurve,
        LineChartData(
          minX: -0.3,
          maxX: items.length - 0.7,
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: 1,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: p.grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 1,
                getTitlesWidget: (v, meta) =>
                    v == meta.min || v == meta.max || v != v.roundToDouble()
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text('${v.round()}°', style: p.axisStyle),
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (v != i || i < 0 || i >= items.length) {
                    return const SizedBox.shrink();
                  }
                  final t = items[i].targetTime;
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(
                      '${t == null ? '' : ForecastFormat.hourMinute(t)}\n'
                      'sau ${items[i].horizon}',
                      textAlign: TextAlign.center,
                      style: p.axisStyle,
                    ),
                  );
                },
              ),
            ),
          ),
          betweenBarsData: hasBand
              ? [BetweenBarsData(fromIndex: 0, toIndex: 1, color: bandColor)]
              : const [],
          lineBarsData: [
            edge(hasBand ? lo : const []),
            edge(hasBand ? hi : const []),
            LineChartBarData(
              spots: pred,
              color: p.high,
              barWidth: 2.5,
              dashArray: const [6, 4],
              dotData: dots(p.high),
            ),
            LineChartBarData(
              spots: act,
              color: actualColor,
              barWidth: 2.5,
              dotData: dots(actualColor),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => p.tooltipBg,
              tooltipRoundedRadius: 8,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  s.barIndex < 2
                      ? null
                      : LineTooltipItem(
                          '${s.barIndex == 2 ? 'Dự báo' : 'Thực tế'} '
                          '${s.y.toStringAsFixed(1).replaceAll('.', ',')}°',
                          p.tooltipStyle,
                        ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Danh gia mo hinh tren tap kiem tra tai o luoi cua dia diem.
class _EvaluationCard extends StatelessWidget {
  const _EvaluationCard({required this.evaluation, required this.provider});

  final AIEvaluation? evaluation;
  final WeatherProvider provider;

  static const Map<String, String> _targetNames = {
    'humidity': 'độ ẩm',
    'wind_speed': 'gió',
    'wind_gusts': 'gió giật',
    'precipitation_mm': 'lượng mưa',
  };

  /// MAE theo don vi dang chon (goc %, km/h, mm).
  static String _maeText(String target, double v, UnitPrefs u) {
    String dec(double x, int d) => x.toStringAsFixed(d).replaceAll('.', ',');
    switch (target) {
      case 'humidity':
        return '±${dec(v, 1)}%';
      case 'wind_speed':
      case 'wind_gusts':
        // Beaufort khong tuyen tinh -> sai so hien theo m/s.
        return '±${dec(u.windAxisValue(v), 1)} ${u.windAxisUnit.label}';
      default:
        return u.precip == PrecipUnit.mm
            ? '±${dec(v, 2)} mm'
            : '±${dec(UnitConvert.mmToInch(v), 3)} in';
    }
  }

  /// Dong MAE cac muc tieu moi + do phu khoang nhiet do (neu co).
  List<Widget> _extraLines(BuildContext context, AIEvaluation e) {
    final theme = Theme.of(context);
    final units = PreferencesProvider.unitsOf(context);
    final body = AppTextStyles.bodyMedium.copyWith(
      color: theme.textTheme.bodyLarge?.color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final lines = <String>[];
    for (final t in AIEvaluation.extraTargets) {
      final m = e.targetMae[t];
      if (!e.isEnabled(t) || m == null || m.isEmpty) continue;
      final parts = [
        for (final h in m.entries) '${_maeText(t, h.value, units)} (${h.key})',
      ];
      lines.add('Sai số ${_targetNames[t]}: ${parts.join(' · ')}');
    }
    final cov = e.intervalCoverage;
    if (e.isEnabled('temperature_interval') && cov.isNotEmpty) {
      final parts = [
        for (final h in cov.entries) '${(h.value * 100).round()}% (${h.key})',
      ];
      final nominal = e.intervalNominalCoverage;
      final goal = nominal == null
          ? ''
          : ' (mục tiêu ${(nominal * 100).round()}%)';
      final name = nominal == null ? 'dự báo' : '${(nominal * 100).round()}%';
      lines.add(
        'Khoảng nhiệt độ $name phủ ${parts.join(' · ')} trên tập kiểm '
        'tra$goal. Đây là mức bất định, không phải điểm độ chính xác.',
      );
    }
    return [
      for (final l in lines) ...[
        const SizedBox(height: AppSizes.paddingS),
        Text(l, style: body),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = evaluation;
    final warn = e != null && e.beatsBaselines == false;
    final ink = GlassThemeMarker.inkOf(context);
    final strong = AppTextStyles.bodyMedium.copyWith(
      color: warn && ink != null
          ? ink.warning
          : theme.textTheme.bodyLarge?.color,
      fontWeight: FontWeight.w600,
    );
    final horizons = [
      for (final h in AIForecast.horizons)
        if (e != null &&
            (e.temperatureMae.containsKey(h) || e.rainF1.containsKey(h)))
          h,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Đánh giá tại ô lưới này',
          style: AppTextStyles.heading3.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        const SizedBox(height: AppSizes.paddingS),
        Text(AIEvaluationLine.text(e, provider), style: strong),
        if (horizons.isNotEmpty) ...[
          const SizedBox(height: AppSizes.paddingS),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              _row(context, const [
                'Mốc',
                'Sai số nhiệt độ',
                'F1 mưa',
              ], header: true),
              for (final h in horizons)
                _row(context, [
                  h,
                  e!.temperatureMae[h] == null
                      ? '--'
                      : '±${formatTempDelta(e.temperatureMae[h]!, provider)}',
                  e.rainF1[h] == null
                      ? '--'
                      : e.rainF1[h]!.toStringAsFixed(2).replaceAll('.', ','),
                ]),
            ],
          ),
        ],
        if (e != null) ..._extraLines(context, e),
        const SizedBox(height: AppSizes.paddingS),
        Text(
          e == null
              ? 'Máy chủ chưa gửi kết quả đánh giá cho ô dữ liệu của địa '
                    'điểm này.'
              : [
                  'Một mô hình chung cho mọi ô dữ liệu, đánh giá riêng '
                      'trên dữ liệu kiểm tra của ô này'
                      '${e.cellId == null ? '' : ' (${e.cellId})'}.',
                  if (e.testPeriodText != null)
                    'Giai đoạn kiểm tra: ${e.testPeriodText}.',
                  'F1 mưa: 0 = kém, 1 = đúng hoàn toàn.',
                ].join(' '),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  TableRow _row(
    BuildContext context,
    List<String> cells, {
    bool header = false,
  }) {
    final theme = Theme.of(context);
    return TableRow(
      children: [
        for (var i = 0; i < cells.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              cells[i],
              style: header || i == 0
                  ? theme.textTheme.bodySmall
                  : AppTextStyles.bodyMedium.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
            ),
          ),
      ],
    );
  }
}

/// Do lech nhiet do theo don vi dang chon, 1 chu so thap phan.
String _degrees(double celsiusDelta, WeatherProvider provider) {
  final v = provider.isCelsius ? celsiusDelta : celsiusDelta * 9 / 5;
  return '${v.toStringAsFixed(1).replaceAll('.', ',')}${provider.tempUnit}';
}

class _HorizonCard extends StatelessWidget {
  const _HorizonCard({
    required this.item,
    required this.nowHcm,
    required this.provider,
  });

  final AIVerificationItem item;
  final DateTime nowHcm;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = item.targetTime;
    final notYet = target != null && target.isAfter(nowHcm);
    final targetText = target == null
        ? ''
        : ' · ${ForecastFormat.hourMinute(target)} ${ForecastFormat.title(target)}';

    final String status;
    final Color statusColor;
    if (item.hasActual) {
      status = 'Đã có thực tế';
      statusColor = GlassThemeMarker.isGlass(context)
          ? Colors.white
          : theme.brightness == Brightness.dark
          ? const Color(0xFF81C784)
          : const Color(0xFF2E7D32);
    } else if (notYet) {
      status = 'Chưa tới giờ';
      statusColor = theme.textTheme.bodySmall?.color ?? Colors.grey;
    } else {
      status = 'Chưa có số liệu';
      statusColor = theme.textTheme.bodySmall?.color ?? Colors.grey;
    }

    final predTemp = item.predictedTemperature;
    final actTemp = item.actualTemperature;
    final err = item.temperatureError;
    final predRain = item.predictedRainPercent;
    final String actualRain;
    if (item.actualRain == null) {
      actualRain = '--';
    } else {
      final mm = item.actualPrecipitation == null
          ? ''
          : ' (${PreferencesProvider.unitsOf(context).rainText(item.actualPrecipitation)})';
      actualRain = '${item.actualRain! ? 'Có mưa' : 'Không mưa'}$mm';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Sau ${item.horizon}$targetText',
                    style: AppTextStyles.heading3.copyWith(
                      color: theme.textTheme.titleLarge?.color,
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.paddingS),
                Text(
                  status,
                  style: AppTextStyles.caption.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSizes.paddingS),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.1),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1.2),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _row(context, const ['', 'Dự báo', 'Thực tế'], header: true),
                _row(context, [
                  'Nhiệt độ',
                  predTemp == null
                      ? '--'
                      : provider.formatTemperature(predTemp),
                  actTemp == null ? '--' : provider.formatTemperature(actTemp),
                ]),
                _row(context, [
                  'Mưa',
                  predRain == null ? '--' : '$predRain% khả năng',
                  actualRain,
                ]),
              ],
            ),
            const SizedBox(height: AppSizes.paddingS),
            if (err != null)
              Text(
                'Sai số nhiệt độ: ${_degrees(err, provider)}',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: theme.textTheme.bodyLarge?.color,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (!item.hasActual)
              Text(
                notYet
                    ? 'Mốc ${ForecastFormat.hourMinute(target)} chưa tới — '
                          'chưa có số liệu thực tế để so sánh.'
                    : 'Chưa có số liệu thực tế cho mốc này.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  TableRow _row(
    BuildContext context,
    List<String> cells, {
    bool header = false,
  }) {
    final theme = Theme.of(context);
    return TableRow(
      children: [
        for (var i = 0; i < cells.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4, right: 8),
            child: Text(
              cells[i],
              style: header || i == 0
                  ? theme.textTheme.bodySmall
                  : AppTextStyles.bodyMedium.copyWith(
                      color: theme.textTheme.bodyLarge?.color,
                      fontWeight: FontWeight.w600,
                    ),
            ),
          ),
      ],
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.showReplayTip});

  final bool showReplayTip;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final notes = [
      '"Thực tế" là dữ liệu phân tích của mô hình (Open-Meteo), '
          'không phải số đo từ trạm khí tượng.',
      'Thực tế = dữ liệu phân tích của mô hình; phản hồi người dùng không '
          'được dùng làm thực tế.',
      '"Có mưa / Không mưa" do máy chủ đánh giá từ lượng mưa thực tế '
          'trong giờ đó.',
      'Vài mốc kiểm chứng không đủ để đánh giá độ chính xác của mô hình.',
      if (showReplayTip)
        'Mẹo: bật "Chế độ xem lại" trong Cài đặt để kiểm chứng dự báo tại '
            'một thời điểm trong quá khứ.',
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSizes.paddingXS),
                child: Text('• $n', style: style),
              ),
          ],
        ),
      ),
    );
  }
}
