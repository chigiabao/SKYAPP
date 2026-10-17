import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/weather.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/ai_forecast_card.dart';
import 'forecast/forecast_format.dart';

/// Kiem chung du bao AI: moi moc (1h/3h/6h) so du bao voi "thuc te"
/// (du lieu phan tich cua mo hinh, khong phai tram do). Dung thoi diem
/// "hien tai" cua app (che do xem lai -> thoi diem xem lai).
class AIVerifyScreen extends StatefulWidget {
  const AIVerifyScreen({super.key});

  @override
  State<AIVerifyScreen> createState() => _AIVerifyScreenState();
}

class _AIVerifyScreenState extends State<AIVerifyScreen> {
  Future<AIVerification>? _future;

  /// Thoi diem xem lai ung voi [_future] (null = truc tiep).
  DateTime? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) _load(context.read<WeatherProvider>());
  }

  void _load(WeatherProvider p) {
    _loadedFor = p.isReplay ? p.replayAt : null;
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
    if (key != _loadedFor) _load(provider);
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
          return _VerifyBody(data: snap.data!, provider: provider);
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
  const _VerifyBody({required this.data, required this.provider});

  final AIVerification data;
  final WeatherProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = provider.nowHcm;
    final errors = [
      for (final h in data.horizons)
        if (h.temperatureError != null) h.temperatureError!,
    ];
    final noneAvailable = data.horizons.every((h) => !h.hasActual);

    return ListView(
      padding: const EdgeInsets.all(AppSizes.paddingM),
      children: [
        Text(
          'Bản dự báo phát hành ${ForecastFormat.moment(data.issuedAt)}'
          '${data.modelVersion.isEmpty ? '' : ' · ${data.modelVersion}'}',
          style: theme.textTheme.bodyMedium,
        ),
        if (errors.isNotEmpty) ...[
          const SizedBox(height: AppSizes.paddingS),
          Text(
            'Sai số nhiệt độ trung bình: '
            '${_degrees(errors.reduce((a, b) => a + b) / errors.length, provider)}'
            ' (${errors.length}/${data.horizons.length} mốc)',
            style: AppTextStyles.bodyLarge.copyWith(
              color: theme.textTheme.bodyLarge?.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: AppSizes.paddingM),
        _EvaluationCard(evaluation: data.evaluation, provider: provider),
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
      ],
    );
  }
}

/// Danh gia mo hinh tren tap kiem tra tai o luoi cua dia diem.
class _EvaluationCard extends StatelessWidget {
  const _EvaluationCard({required this.evaluation, required this.provider});

  final AIEvaluation? evaluation;
  final WeatherProvider provider;

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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        child: Column(
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
                          : e.rainF1[h]!
                                .toStringAsFixed(2)
                                .replaceAll('.', ','),
                    ]),
                ],
              ),
            ],
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
          : ' (${WeatherFormat.rainMm(item.actualPrecipitation)})';
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
            padding: const EdgeInsets.symmetric(vertical: 4),
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
