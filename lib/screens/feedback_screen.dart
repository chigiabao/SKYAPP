import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../services/feedback_service.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';

/// Man Gop y (nhom 10): bao loi, gop y, bao du bao sai.
///
/// Tu dinh kem forecast_snapshot nho (dia diem, gio, nhiet do, kha nang mua,
/// nguon), phien ban app va nen tang. KHONG gui toa do GPS.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    this.initialKind,
    this.locationId,
    this.snapshot,
    this.service,
  });

  /// Vd. [FeedbackKind.wrongForecast] tu nut "Báo dự báo sai".
  final FeedbackKind? initialKind;

  /// null -> lay tu WeatherProvider (neu co).
  final String? locationId;
  final Map<String, Object?>? snapshot;
  final FeedbackService? service;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late final FeedbackService _service = widget.service ?? FeedbackService();
  final _message = TextEditingController();
  late FeedbackKind _kind = widget.initialKind ?? FeedbackKind.bug;
  bool? _raining;
  TemperatureFeel? _feel;
  bool _sending = false;
  bool _restored = false;
  String? _error;

  String? _locationId;
  Map<String, Object?>? _snapshot;

  @override
  void initState() {
    super.initState();
    _locationId = widget.locationId;
    _snapshot = widget.snapshot;
    if (_locationId == null || _snapshot == null) {
      WeatherProvider? p;
      try {
        p = context.read<WeatherProvider>();
      } catch (_) {}
      if (p != null) {
        _locationId ??= p.locationId;
        _snapshot ??= forecastSnapshot(
          locationId: _locationId,
          nowHcm: p.nowHcm,
          hours: p.hourlyForecast,
          current: p.currentWeather,
        );
      }
    }
    _message.addListener(() => setState(() {}));
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    final d = await _service.loadDraft();
    if (!mounted || d == null) return;
    if (widget.initialKind != null && d.kind != widget.initialKind) return;
    setState(() {
      _kind = d.kind;
      _message.text = d.message;
      _raining = d.raining;
      _feel = d.feel;
      _restored = true;
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  bool get _wrong => _kind == FeedbackKind.wrongForecast;

  bool get _canSend =>
      !_sending &&
      (_message.text.trim().isNotEmpty ||
          (_wrong && (_raining != null || _feel != null)));

  FeedbackDraft get _draft => FeedbackDraft(
    kind: _kind,
    message: _message.text,
    locationId: _locationId,
    raining: _wrong ? _raining : null,
    feel: _wrong ? _feel : null,
    snapshot: _snapshot,
  );

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.submit(_draft);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Đã gửi phản hồi. Cảm ơn bạn!')),
      );
      Navigator.of(context).maybePop();
    } on FeedbackException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: e.draftSaved
              ? SnackBarAction(label: 'Thử lại', onPressed: _send)
              : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final snap = _snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('Góp ý')),
      body: ListView(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        children: [
          Text('Loại phản hồi', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSizes.paddingS),
          Wrap(
            spacing: AppSizes.paddingS,
            runSpacing: AppSizes.paddingS,
            children: [
              for (final k in FeedbackKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          if (_wrong) ...[
            const SizedBox(height: AppSizes.paddingM),
            Text(
              'Ở chỗ bạn đang mưa không?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSizes.paddingS),
            Wrap(
              spacing: AppSizes.paddingS,
              children: [
                for (final (v, l) in const [(true, 'Có'), (false, 'Không')])
                  ChoiceChip(
                    label: Text(l),
                    selected: _raining == v,
                    onSelected: (s) => setState(() => _raining = s ? v : null),
                  ),
              ],
            ),
            const SizedBox(height: AppSizes.paddingM),
            Text('Cảm giác nhiệt', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSizes.paddingS),
            Wrap(
              spacing: AppSizes.paddingS,
              children: [
                for (final f in TemperatureFeel.values)
                  ChoiceChip(
                    label: Text(f.label),
                    selected: _feel == f,
                    onSelected: (s) => setState(() => _feel = s ? f : null),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSizes.paddingM),
          TextField(
            key: const ValueKey('feedback-message'),
            controller: _message,
            maxLength: kFeedbackMaxLength,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: 'Nội dung',
              hintText: _wrong
                  ? 'Mô tả ngắn điều bạn thấy (không bắt buộc)'
                  : 'Mô tả lỗi hoặc góp ý của bạn',
              border: const OutlineInputBorder(),
            ),
          ),
          if (_restored)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSizes.paddingS),
              child: Text('Đã khôi phục bản nháp chưa gửi.', style: small),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSizes.paddingM),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, size: 18),
                      const SizedBox(width: AppSizes.paddingS),
                      Expanded(
                        child: Text(
                          kFeedbackDisclaimer,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSizes.paddingS),
                  Text(
                    'Gửi kèm: ${snap == null ? 'không có dự báo' : 'dự báo đang hiển thị (giờ, nhiệt độ, khả năng mưa, nguồn)'}'
                    '${_locationId == null ? '' : ', mã địa điểm'}, '
                    'phiên bản app $kAppVersion, nền tảng. '
                    'Không gửi toạ độ GPS.',
                    style: small,
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSizes.paddingM),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSizes.paddingM),
          FilledButton.icon(
            onPressed: _canSend ? _send : null,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded),
            label: Text(_error != null ? 'Thử lại' : 'Gửi'),
          ),
        ],
      ),
    );
  }
}
