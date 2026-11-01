import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../providers/location_provider.dart';
import '../../providers/weather_provider.dart';
import '../../services/server_health.dart';
import '../../ui/weather/design_tokens.dart';
import 'settings_common.dart';
import '../../ui/weather/widgets/ios_controls.dart';
import '../../ui/weather/widgets/ios_toast.dart';
import '../../utils/haptics.dart';

// ---------------------------------------------------------------------------
// Nang cao - May chu du lieu (URL backend luc chay)
// ---------------------------------------------------------------------------

class SettingsServerSection extends StatefulWidget {
  const SettingsServerSection({super.key});

  @override
  State<SettingsServerSection> createState() => _ServerSectionState();
}

class _ServerSectionState extends State<SettingsServerSection> {
  late final TextEditingController _ctrl = TextEditingController(
    text: ApiConfig.baseUrl,
  );
  String? _error;
  ServerHealth? _health;
  bool _checking = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Tai lai du lieu sau khi doi may chu.
  void _reload() {
    context.read<WeatherProvider>().reloadServer();
    try {
      context.read<LocationProvider>().refreshRemote();
    } on ProviderNotFoundException {
      // Man hinh don le (test): khong co danh sach dia diem.
    }
  }

  Future<void> _save() async {
    final ok = await ApiConfig.setBaseUrl(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _error = ok ? null : 'Địa chỉ không hợp lệ. Dùng http:// hoặc https://';
      _health = null;
    });
    if (!ok) return;
    _ctrl.text = ApiConfig.baseUrl;
    _reload();
    AppHaptics.success();
    showIosToast(
      context,
      'Đã lưu máy chủ ${ApiConfig.baseUrl}',
      tone: IosToastTone.success,
    );
  }

  Future<void> _reset() async {
    await ApiConfig.setBaseUrl(null);
    if (!mounted) return;
    setState(() {
      _ctrl.text = ApiConfig.baseUrl;
      _error = null;
      _health = null;
    });
    _reload();
  }

  Future<void> _check() async {
    final url = ApiConfig.normalizeBaseUrl(_ctrl.text);
    if (url == null) {
      setState(
        () => _error = 'Địa chỉ không hợp lệ. Dùng http:// hoặc https://',
      );
      return;
    }
    setState(() {
      _error = null;
      _checking = true;
      _health = null;
    });
    final h = await checkServerHealth(url);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _health = h;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = ApiConfig.baseUrlOverride != null;
    final h = _health;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Máy chủ dữ liệu',
                style: TypeScale.bodyLarge.copyWith(
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),
            ),
            const SizedBox(height: Space.xs),
            SettingsNote(
              custom
                  ? 'Đang dùng địa chỉ tự đặt. Mặc định: '
                        '${ApiConfig.defaultBaseUrl}'
                  : 'Đang dùng địa chỉ mặc định của bản cài.',
            ),
            const SizedBox(height: Space.l),
            IosTextField(
              label: 'Địa chỉ máy chủ (URL)',
              controller: _ctrl,
              placeholder: 'http://192.168.1.10:8000',
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              errorText: _error,
            ),
            const SizedBox(height: Space.s),
            Wrap(
              spacing: Space.s,
              runSpacing: Space.xs,
              children: [
                SettingsAction(
                  onPressed: _save,
                  icon: CupertinoIcons.tray_arrow_down,
                  label: 'Lưu và tải lại',
                ),
                SettingsAction(
                  onPressed: _checking ? null : _check,
                  icon: CupertinoIcons.wifi,
                  label: 'Kiểm tra kết nối',
                ),
                SettingsAction(
                  onPressed: custom ? _reset : null,
                  icon: CupertinoIcons.arrow_counterclockwise,
                  label: 'Khôi phục mặc định',
                ),
              ],
            ),
            if (_checking)
              Padding(
                padding: const EdgeInsets.only(top: Space.s),
                child: Semantics(
                  liveRegion: true,
                  label: 'Đang kiểm tra kết nối',
                  child: const ExcludeSemantics(
                    child: Row(
                      children: [
                        CupertinoActivityIndicator(radius: 8),
                        SizedBox(width: Space.s),
                        Text('Đang kiểm tra kết nối…'),
                      ],
                    ),
                  ),
                ),
              ),
            if (h != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.s),
                child: Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        h.ok
                            ? CupertinoIcons.checkmark_circle
                            : CupertinoIcons.exclamationmark_triangle,
                        color: h.ok
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                        size: IconSizes.inline,
                      ),
                      const SizedBox(width: Space.s),
                      Expanded(
                        child: Text(
                          h.message,
                          style: TypeScale.bodySmall.copyWith(
                            color: h.ok
                                ? theme.textTheme.bodySmall?.color
                                : theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
