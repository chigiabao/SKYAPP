import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/units.dart';
import '../models/weather.dart';
import '../providers/preferences_provider.dart';
import '../providers/weather_provider.dart';
import '../services/api_service.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../widgets/ai_forecast_card.dart';
import 'ai_verify/evaluation_card.dart';
import 'ai_verify/horizon_card.dart';
import 'ai_verify/verify_chart.dart';
import '../utils/forecast_format.dart';
import '../utils/formatters.dart';
import '../utils/haptics.dart';

/// Kiem chung du bao AI: moi moc (1h/3h/6h) so du bao voi "thuc te"
/// (du lieu phan tich cua mo hinh, khong phai tram do). Dung thoi diem
/// "hien tai" cua app (che do xem lai -> thoi diem xem lai).
class AIVerifyScreen extends StatefulWidget {
  const AIVerifyScreen({super.key, this.intervalLoader});

  /// Legacy integration seam for an explicitly supplied original interval.
  /// New verification responses never fetch intervals from today's model.
  final Future<AIForecast?> Function(DateTime issuedAt)? intervalLoader;

  @override
  State<AIVerifyScreen> createState() => _AIVerifyScreenState();
}

class _AIVerifyScreenState extends State<AIVerifyScreen> {
  Future<AIVerification>? _future;
  Future<AIForecast?>? _intervals;
  DateTime? _intervalsFor;

  Future<AIForecast?> _intervalsOf(AIVerification data) {
    if (data.verificationMode != 'unspecified') return Future.value(null);
    final issuedAt = data.issuedAt;
    if (_intervals != null && _intervalsFor == issuedAt) return _intervals!;
    _intervalsFor = issuedAt;
    final loader = widget.intervalLoader;
    return _intervals = loader != null ? loader(issuedAt) : Future.value(null);
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
    return IosPageScaffold(
      title: 'Kiểm chứng AI',
      onRefresh: withRefreshHaptic(() async {
        _reload();
        return await _future?.then((_) => true, onError: (_) => false) ?? false;
      }),
      actions: [
        IosBarButton(
          tooltip: 'Tải lại',
          icon: CupertinoIcons.refresh,
          onPressed: _reload,
        ),
      ],
      slivers: [
        FutureBuilder<AIVerification>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CupertinoActivityIndicator(radius: 14)),
              );
            }
            if (snap.hasError || !snap.hasData) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: _ErrorView(error: snap.error, onRetry: _reload),
              );
            }
            final data = snap.data!;
            return FutureBuilder<AIForecast?>(
              future: _intervalsOf(data),
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
      ],
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
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: IconSizes.state,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
            const SizedBox(height: Space.l),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: Space.l),
            IosButton.filled(
              onPressed: onRetry,
              icon: CupertinoIcons.refresh,
              label: 'Thử lại',
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
    final units = PreferencesProvider.unitsOf(context);
    final noneAvailable = data.horizons.every((h) => !h.hasActual);
    final original = issued;
    final match =
        original != null &&
            original.issuedAt == data.issuedAt &&
            original.modelVersion == data.modelVersion &&
            original.isEnabled('temperature_interval')
        ? original
        : null;

    final hPad = iosPageHPad(context);
    // Khong co gi de so: MOT trang thai trong ro rang (thay vi 3 the
    // "Chưa có…" chong nhau) + loi tat toi moc mau co du bao da luu.
    if (data.horizons.isEmpty || data.verificationMode == 'unavailable') {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          hPad,
          Space.s,
          hPad,
          Space.xxl + MediaQuery.paddingOf(context).bottom,
        ),
        sliver: SliverToBoxAdapter(
          child: VerifyEmptyState(data: data, provider: provider),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        hPad,
        Space.s,
        hPad,
        Space.xxl + MediaQuery.paddingOf(context).bottom,
      ),
      sliver: SliverList.list(
        children: [
          _VerdictCard(data: data, units: units),
          if (data.horizons.any((h) => h.predictedTemperature != null)) ...[
            const SizedBox(height: Space.l),
            VerifyChart(data: data, issued: match, units: units),
          ],
          const SizedBox(height: Space.l),
          for (final h in data.horizons) ...[
            HorizonCard(item: h, nowHcm: now, units: units),
            const SizedBox(height: Space.l),
          ],
          NotesCard(showReplayTip: noneAvailable && !provider.isReplay),
          const SizedBox(height: Space.l),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: Text(
                  'Chi tiết kỹ thuật',
                  style: TypeScale.bodyLarge.copyWith(
                    color: theme.textTheme.bodyLarge?.color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Sai số MAE, F1 mưa, độ phủ khoảng, phiên bản mô hình',
                  style: theme.textTheme.bodySmall,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(
                  Space.l,
                  0,
                  Space.l,
                  Space.l,
                ),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data.modeLabel}: ${ForecastFormat.moment(data.issuedAt)}'
                    '${data.modelVersion.isEmpty ? '' : ' · ${data.modelVersion}'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Space.s),
                  EvaluationCard(evaluation: data.evaluation, units: units),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Trang thai trong duy nhat cua man kiem chung (khong co moc / khong co ban
/// luu): noi ro thoi diem, ly do, va nut mo moc mau co du bao da luu.
class VerifyEmptyState extends StatelessWidget {
  const VerifyEmptyState({
    super.key,
    required this.data,
    required this.provider,
  });

  final AIVerification data;
  final WeatherProvider provider;

  /// "21/10 21:00" cua moc mau.
  static String presetShort() =>
      ForecastFormat.dateTime(WeatherProvider.replayPreset);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = switch (data.unavailableReason) {
      'issue_not_after_selection_cutoff' =>
        'Thời điểm này chưa sau mốc huấn luyện của mô hình nên không kiểm '
            'chứng hồi cứu.',
      'cutoff_unavailable' => 'Chưa xác định được mốc huấn luyện của mô hình.',
      'invalid_archived_forecast' =>
        'Bản lưu không hợp lệ; không thay bằng dự báo tính lại.',
      _ => null,
    };
    final atPreset =
        provider.isReplay && provider.replayAt == WeatherProvider.replayPreset;
    return Card(
      key: const ValueKey('verify-empty'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              CupertinoIcons.clock,
              size: IconSizes.state,
              color: theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(height: Space.m),
            Semantics(
              header: true,
              child: Text(
                'Chưa có bản dự báo đã lưu để kiểm chứng.',
                key: const ValueKey('verify-summary'),
                style: TypeScale.headline.copyWith(
                  color: theme.textTheme.titleLarge?.color,
                ),
              ),
            ),
            const SizedBox(height: Space.s),
            Text(
              'Lúc ${ForecastFormat.moment(data.issuedAt)} không có dự báo AI '
              'được lưu khi phát hành, nên chưa có gì để so với số liệu đã '
              'ghi nhận.${reason == null ? '' : ' $reason'}',
              style: theme.textTheme.bodyMedium,
            ),
            if (!atPreset) ...[
              const SizedBox(height: Space.l),
              IosButton.filled(
                onPressed: () =>
                    provider.startReplay(WeatherProvider.replayPreset),
                icon: CupertinoIcons.time,
                label: 'Xem mốc mẫu ${presetShort()}',
              ),
              const SizedBox(height: Space.xs),
              Text(
                'Mốc mẫu có dự báo AI đã lưu; app chuyển sang chế độ xem lại.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Nhiet do 1 chu so thap phan theo don vi dang chon: "26,5°".
String _temp1(double celsius, UnitPrefs units) {
  final v = units.tempValue(celsius);
  return '${WeatherFormat.decimal(v)}°';
}

/// Tom tat dau man: MOT con so (lech trung binh qua N moc da co thuc te),
/// roi tung moc mot dong, roi nguon / gioi han.
class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.data, required this.units});

  final AIVerification data;
  final UnitPrefs units;

  static List<AIVerificationItem> _done(AIVerification data) => [
    for (final h in data.horizons)
      if (h.temperatureError != null &&
          h.predictedTemperature != null &&
          h.actualTemperature != null)
        h,
  ];

  /// "Lệch trung bình 0,6°C qua 3/3 mốc đã có thực tế."; null = chua co.
  static String? headline(AIVerification data, UnitPrefs units) {
    final done = _done(data);
    if (done.isEmpty) return null;
    final mean =
        done.map((h) => h.temperatureError!).reduce((a, b) => a + b) /
        done.length;
    return 'Lệch trung bình ${units.tempDeltaText(mean)} qua '
        '${done.length}/${data.horizons.length} mốc đã có thực tế.';
  }

  /// "Sau 1h (22:00): dự báo 26,0° · thực tế 26,4° · lệch 0,4°C".
  static String checkpoint(AIVerificationItem h, UnitPrefs units) {
    final at = h.targetTime == null
        ? ''
        : ' (${ForecastFormat.hourMinute(h.targetTime!)})';
    if (h.predictedTemperature == null) {
      return 'Sau ${h.horizon}$at: không có dự báo nhiệt độ.';
    }
    if (h.actualTemperature == null || h.temperatureError == null) {
      return 'Sau ${h.horizon}$at: dự báo '
          '${_temp1(h.predictedTemperature!, units)} · chưa có thực tế.';
    }
    return 'Sau ${h.horizon}$at: dự báo '
        '${_temp1(h.predictedTemperature!, units)} · thực tế '
        '${_temp1(h.actualTemperature!, units)} · lệch '
        '${units.tempDeltaText(h.temperatureError!)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = headline(data, units);
    final sub = [
      '${data.modeLabel}: ${ForecastFormat.moment(data.issuedAt)}.',
      if (data.verificationMode == 'archived') 'Nguồn dự báo: bản dự báo đã lưu lúc phát hành; không tính lại bằng mô hình hiện tại.',
      if (data.verificationMode == 'retrospective') 'Tính lại bằng mô hình hiện tại; không phải dự báo đã phát hành lúc đó.',
      if (data.selectionCutoff != null)
        'Mốc cuối huấn luyện/lựa chọn: ${ForecastFormat.moment(data.selectionCutoff!)}.',
      if (data.unavailableReason == 'issue_not_after_selection_cutoff') 'Thời điểm này chưa sau mốc huấn luyện/lựa chọn; không kiểm chứng hồi cứu.',
      if (data.unavailableReason == 'cutoff_unavailable')
        'Chưa xác định được mốc huấn luyện/lựa chọn của mô hình.',
      if (data.unavailableReason == 'invalid_archived_forecast')
        'Bản lưu không hợp lệ; không thay bằng dự báo tính lại.',
      'Đã ghi nhận: ${DataCopy.observedExplain}.',
    ].join(' ');
    final body = theme.textTheme.bodyMedium;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                data.verificationMode == 'unavailable'
                    ? 'Chưa có bản dự báo đã lưu để kiểm chứng.'
                    : head ?? 'Chưa có số liệu thực tế để so với dự báo AI.',
                key: const ValueKey('verify-summary'),
                style: TypeScale.headline.copyWith(
                  color: theme.textTheme.titleLarge?.color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (data.horizons.isNotEmpty &&
                data.verificationMode != 'unavailable') ...[
              const SizedBox(height: Space.s),
              for (final h in data.horizons)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    checkpoint(h, units),
                    style: body?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: Space.s),
            Text(sub, style: theme.textTheme.bodySmall),
            const SizedBox(height: Space.m),
            Text(
              'Đánh giá dài hạn tại ô lưới',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(AIEvaluationLine.text(data.evaluation, units), style: body),
          ],
        ),
      ),
    );
  }
}

/// Mo man kiem chung AI (cho cac the dung chung o lib/widgets/).
Future<void> openAIVerify(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AIVerifyScreen()));
