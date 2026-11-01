import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/weather_provider.dart';
import '../services/feedback_service.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/app_segmented_control.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/ios_toast.dart';
import '../utils/haptics.dart';

/// Man Phan hoi (nhom 10): bao loi, gop y, bao du bao sai.
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

  /// Lan gui dang chay: dong client sau khi gui xong, khong cat ngang.
  Future<void>? _submitting;
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
    if (widget.service == null) {
      final pending = _submitting;
      if (pending == null) {
        _service.close();
      } else {
        pending.whenComplete(_service.close).ignore();
      }
    }
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
    try {
      final submit = _submitting = _service.submit(_draft);
      await submit;
      if (!mounted) return;
      AppHaptics.success();
      showIosToast(
        context,
        'Đã gửi phản hồi. Cảm ơn bạn!',
        tone: IosToastTone.success,
      );
      Navigator.of(context).maybePop();
    } on FeedbackException catch (e) {
      if (!mounted) return;
      // Loi hien mot lan, ngay tren nut Gui. Chi loi mang them thong bao
      // ngan co nut "Thử lại" (khong lap lai nguyen van loi).
      setState(() => _error = e.message);
      AppHaptics.error();
      if (e.kind == FeedbackErrorKind.network) {
        showIosToast(
          context,
          'Chưa gửi được phản hồi.',
          tone: IosToastTone.error,
          actionLabel: e.draftSaved ? 'Thử lại' : null,
          onAction: e.draftSaved
              ? () {
                  if (mounted && _canSend) _send();
                }
              : null,
        );
      }
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
    final ink = GlassInk.of(context);
    final snap = _snapshot;
    return IosPageScaffold(
      title: 'Phản hồi',
      children: [
        Text('Loại phản hồi', style: theme.textTheme.titleSmall),
        const SizedBox(height: Space.s),
        AppSegmentedControl<FeedbackKind>(
          segments: [
            for (final k in FeedbackKind.values)
              AppSegment(value: k, label: k.label),
          ],
          selected: _kind,
          onChanged: (k) => setState(() => _kind = k),
        ),
        if (_wrong) ...[
          const SizedBox(height: Space.l),
          Text('Ở chỗ bạn đang mưa không?', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.s),
          AppSegmentedControl<bool>(
            segments: const [
              AppSegment(value: true, label: 'Có'),
              AppSegment(value: false, label: 'Không'),
            ],
            selected: _raining,
            onChanged: (v) => setState(() => _raining = v),
            onDeselect: () => setState(() => _raining = null),
          ),
          const SizedBox(height: Space.l),
          Text('Cảm giác nhiệt', style: theme.textTheme.titleSmall),
          const SizedBox(height: Space.s),
          AppSegmentedControl<TemperatureFeel>(
            segments: [
              for (final f in TemperatureFeel.values)
                AppSegment(value: f, label: f.label),
            ],
            selected: _feel,
            onChanged: (f) => setState(() => _feel = f),
            onDeselect: () => setState(() => _feel = null),
          ),
        ],
        const SizedBox(height: Space.l),
        IosTextField(
          key: const ValueKey('feedback-message'),
          label: 'Nội dung',
          controller: _message,
          maxLength: kFeedbackMaxLength,
          minLines: 4,
          maxLines: 8,
          placeholder: _wrong
              ? 'Mô tả ngắn điều bạn thấy (không bắt buộc)'
              : 'Mô tả lỗi hoặc góp ý của bạn',
        ),
        Padding(
          padding: const EdgeInsets.only(top: Space.xs, bottom: Space.s),
          child: Text(
            '${_message.text.characters.length}/$kFeedbackMaxLength',
            textAlign: TextAlign.end,
            style: TypeScale.footnote.copyWith(
              color: ink.secondary,
              fontFeatures: TypeScale.tabular,
            ),
          ),
        ),
        if (_restored)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: Text('Đã khôi phục bản nháp chưa gửi.', style: small),
          ),
        // Nhom inset kieu iOS tren kinh (khong dung Card Material).
        DecoratedBox(
          key: const ValueKey('feedback-disclaimer'),
          decoration: iosFieldDecoration(),
          child: Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        CupertinoIcons.info,
                        size: IconSizes.inline,
                        color: ink.secondary,
                      ),
                    ),
                    const SizedBox(width: Space.s),
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
                const SizedBox(height: Space.s),
                Text(
                  'Gửi kèm: ${snap == null ? 'không có dự báo' : 'dự báo đang hiển thị (giờ, nhiệt độ, khả năng mưa, nguồn)'}'
                  '${_locationId == null ? '' : ', mã địa điểm'}, '
                  'phiên bản app $kAppVersion, nền tảng. '
                  'Không gửi tọa độ GPS.',
                  style: small,
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Space.l),
          Text(
            _error!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: Space.l),
        FilledButton.icon(
          onPressed: _canSend ? _send : null,
          // Tat: vien ro (>= 3:1 tren nen kinh) + chu mo, khac han nut trang
          // dang bat.
          style: FilledButton.styleFrom(
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: Palette.secondary,
            side: _canSend || _sending
                ? BorderSide.none
                : const BorderSide(color: Palette.fieldBorder),
          ),
          icon: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CupertinoActivityIndicator(radius: 9),
                )
              : const Icon(Icons.send_rounded),
          label: Text(_error != null ? 'Thử lại' : 'Gửi'),
        ),
        if (!_canSend && !_sending)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              _wrong
                  ? 'Chọn một câu trả lời hoặc nhập nội dung để gửi.'
                  : 'Nhập nội dung để gửi.',
              style: small,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}
