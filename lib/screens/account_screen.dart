import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/hcm_time.dart';
import '../providers/account_provider.dart';
import '../services/account_service.dart';
import '../services/download/download_file.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';

/// Luu / chia se file JSON; tra ve duong dan da luu (null tren web = tai
/// xuong qua trinh duyet).
typedef JsonExporter = Future<String?> Function(String fileName, String json);

/// Mobile / desktop: ghi vao thu muc tai lieu cua app (path_provider) roi mo
/// bang chia se. Web: tai file JSON xuong (Blob + the a, khong Web Share).
Future<String?> defaultJsonExporter(String fileName, String json) async {
  final bytes = Uint8List.fromList(utf8.encode(json));
  if (kIsWeb) {
    downloadBytes(bytes, fileName, 'application/json');
    return null;
  }
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: fileName,
      ),
    );
  } catch (e) {
    // Desktop co the khong co bang chia se: file da luu.
    debugPrint('share: $e');
  }
  return file.path;
}

final RegExp _emailRe = RegExp(r'^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$');

/// Mau nut nguy hiem: nen do, chu trang (tuong phan ~6.5:1).
const Color _danger = Color(0xFFB3261E);

/// "Tài khoản và đồng bộ" (tuy chon): dang nhap / dang ky, trang thai dong
/// bo, xuat / xoa du lieu, xoa tai khoan, chinh sach quyen rieng tu.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, this.exporter = defaultJsonExporter});

  final JsonExporter exporter;

  @override
  Widget build(BuildContext context) => GlassPage(
    child: Builder(builder: (context) => _AccountBody(exporter: exporter)),
  );
}

class _AccountBody extends StatelessWidget {
  const _AccountBody({required this.exporter});

  final JsonExporter exporter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = GlassInk.of(context);
    final account = context.watch<AccountProvider>();
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;
    final notice = account.notice;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Tài khoản và đồng bộ',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
        children: [
          GlassCard(
            title: 'Tài khoản tuỳ chọn',
            icon: Icons.info_outline_rounded,
            child: Text(
              'Không cần tài khoản để dùng app. Tài khoản chỉ để đồng bộ địa '
              'điểm đã lưu, cài đặt và lịch hoạt động giữa các thiết bị. '
              'Không bao giờ gửi toạ độ GPS; thói quen chỉ được đồng bộ khi '
              'bạn đã đồng ý học thói quen.',
              style: TypeScale.body.copyWith(color: Palette.white),
            ),
          ),
          if (notice != null) ...[
            const SizedBox(height: Space.cardGap),
            _NoticeCard(text: notice, onClose: account.clearNotice),
          ],
          const SizedBox(height: Space.cardGap),
          if (account.isLoggedIn)
            _SignedInCard(exporter: exporter)
          else if (account.isReady)
            const _SignInCard()
          else
            const GlassCard(child: Center(child: CircularProgressIndicator())),
          const SizedBox(height: Space.cardGap),
          GlassCard(
            title: 'Dữ liệu trên máy',
            icon: Icons.phone_android_rounded,
            footer:
                'Tệp JSON gồm địa điểm đã lưu, cài đặt, hoạt động và thói quen '
                'trên thiết bị này. Không có toạ độ GPS.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ActionButton(
                  icon: Icons.download_rounded,
                  label: 'Xuất dữ liệu trên máy',
                  onPressed: () => exportJson(
                    context,
                    exporter,
                    'sky-weather-du-lieu-tren-may.json',
                    () async => account.exportLocalData(),
                  ),
                ),
                const SizedBox(height: Space.s),
                _ActionButton(
                  icon: Icons.privacy_tip_outlined,
                  label: 'Chính sách quyền riêng tư',
                  onPressed: () => showPrivacyDialog(context, account),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.l),
          Text(
            'Tài khoản không hoạt động 2 năm sẽ bị xoá cùng toàn bộ dữ liệu.',
            textAlign: TextAlign.center,
            style: TypeScale.small.copyWith(color: ink.secondary),
          ),
        ],
      ),
    );
  }
}

/// Xuat [load] ra tep [fileName] qua [exporter] + bao ket qua.
Future<void> exportJson(
  BuildContext context,
  JsonExporter exporter,
  String fileName,
  Future<String> Function() load,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final path = await exporter(fileName, await load());
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          path == null ? 'Đã tải tệp $fileName.' : 'Đã lưu tệp tại $path',
        ),
      ),
    );
  } on AccountException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    debugPrint('export: $e');
    messenger.showSnackBar(
      const SnackBar(content: Text('Không xuất được dữ liệu.')),
    );
  }
}

// ---------------------------------------------------------------------------

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text, required this.onClose});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: GlassCard(
        child: Row(
          children: [
            Icon(Icons.info_rounded, color: GlassInk.of(context).warning),
            const SizedBox(width: Space.s),
            Expanded(
              child: Text(
                text,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
            ),
            GlassIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Đóng thông báo',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Nut vien >= 48 dp, rong het the.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: Palette.white,
      minimumSize: const Size.fromHeight(Touch.min),
      alignment: Alignment.centerLeft,
    ),
  );
}

// ---------------------------------------------------------------------------
// Dang nhap / dang ky

class _SignInCard extends StatefulWidget {
  const _SignInCard();

  @override
  State<_SignInCard> createState() => _SignInCardState();
}

class _SignInCardState extends State<_SignInCard> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _error = null);
    final err = await context.read<AccountProvider>().signIn(
      _email.text.trim(),
      _password.text,
      register: _register,
    );
    if (!mounted) return;
    if (err == null) {
      TextInput.finishAutofillContext();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _register ? 'Đã tạo tài khoản và đồng bộ.' : 'Đã đăng nhập.',
          ),
        ),
      );
    } else {
      setState(() => _error = err);
    }
  }

  InputDecoration _deco(BuildContext context, String label, {Widget? suffix}) {
    final ink = GlassInk.of(context);
    OutlineInputBorder b(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.tile / 2),
      borderSide: BorderSide(color: c),
    );
    final err = Theme.of(context).colorScheme.error;
    return InputDecoration(
      labelText: label,
      labelStyle: TypeScale.body.copyWith(color: ink.secondary),
      floatingLabelStyle: TypeScale.body.copyWith(color: Palette.white),
      filled: true,
      fillColor: Palette.subtleFill,
      enabledBorder: b(const Color(0x80FFFFFF)),
      focusedBorder: b(Palette.white),
      errorBorder: b(err),
      focusedErrorBorder: b(err),
      errorStyle: TypeScale.small.copyWith(color: err),
      errorMaxLines: 3,
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.select<AccountProvider, bool>((a) => a.busy);
    final err = Theme.of(context).colorScheme.error;
    return GlassCard(
      title: _register ? 'Tạo tài khoản' : 'Đăng nhập',
      icon: Icons.person_outline_rounded,
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Đăng nhập')),
                  ButtonSegment(value: true, label: Text('Đăng ký')),
                ],
                selected: {_register},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(0, Touch.min)),
                ),
                onSelectionChanged: busy
                    ? null
                    : (v) => setState(() {
                        _register = v.first;
                        _error = null;
                      }),
              ),
              const SizedBox(height: Space.l),
              TextFormField(
                key: const Key('account-email'),
                controller: _email,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.email],
                style: TypeScale.body.copyWith(color: Palette.white),
                decoration: _deco(context, 'Email'),
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return 'Nhập email.';
                  if (s.length > 254 || !_emailRe.hasMatch(s)) {
                    return 'Email không hợp lệ.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: Space.m),
              TextFormField(
                key: const Key('account-password'),
                controller: _password,
                enabled: !busy,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                autofillHints: [
                  _register
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                onFieldSubmitted: (_) => _submit(),
                style: TypeScale.body.copyWith(color: Palette.white),
                decoration: _deco(
                  context,
                  'Mật khẩu',
                  suffix: IconButton(
                    tooltip: _obscure ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                    constraints: const BoxConstraints(
                      minWidth: Touch.min,
                      minHeight: Touch.min,
                    ),
                    color: Palette.white,
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) {
                  final n = (v ?? '').length;
                  if (n == 0) return 'Nhập mật khẩu.';
                  if (n < 8 || n > 128) {
                    return 'Mật khẩu phải có từ 8 đến 128 ký tự.';
                  }
                  return null;
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.m),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TypeScale.body.copyWith(color: err),
                  ),
                ),
              ],
              const SizedBox(height: Space.l),
              FilledButton(
                onPressed: busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.white,
                  foregroundColor: const Color(0xFF0B1F33),
                  minimumSize: const Size.fromHeight(Touch.min),
                ),
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF0B1F33),
                        ),
                      )
                    : Text(_register ? 'Tạo tài khoản' : 'Đăng nhập'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Da dang nhap

class _SignedInCard extends StatelessWidget {
  const _SignedInCard({required this.exporter});

  final JsonExporter exporter;

  static String _time(DateTime t) {
    final h = HcmTime.fromInstant(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(h.hour)}:${two(h.minute)} ${two(h.day)}/${two(h.month)}';
  }

  @override
  Widget build(BuildContext context) {
    final a = context.watch<AccountProvider>();
    final ink = GlassInk.of(context);
    final last = a.lastSyncedAt;
    final (IconData icon, Color color, String status) = switch (a.state) {
      SyncState.syncing => (Icons.sync_rounded, Palette.white, 'Đang đồng bộ…'),
      SyncState.pending => (
        Icons.cloud_off_rounded,
        ink.warning,
        'Chưa có mạng — thay đổi sẽ được đồng bộ sau.',
      ),
      SyncState.error => (
        Icons.error_outline_rounded,
        Theme.of(context).colorScheme.error,
        'Lỗi đồng bộ: ${a.lastError ?? ''}',
      ),
      SyncState.idle => (
        Icons.cloud_done_rounded,
        Palette.white,
        last == null ? 'Chưa đồng bộ' : 'Đã đồng bộ lúc ${_time(last)}',
      ),
    };

    return GlassCard(
      title: 'Tài khoản',
      icon: Icons.account_circle_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            a.email ?? '',
            style: TypeScale.label.copyWith(color: Palette.white),
          ),
          const SizedBox(height: Space.m),
          Semantics(
            liveRegion: true,
            label:
                'Trạng thái đồng bộ: $status'
                '${last != null && a.state != SyncState.idle ? '. Lần cuối ${_time(last)}' : ''}',
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: IconSizes.md),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status,
                        style: TypeScale.body.copyWith(color: color),
                      ),
                      if (last != null && a.state != SyncState.idle)
                        Text(
                          'Lần cuối: ${_time(last)}',
                          style: TypeScale.small.copyWith(color: ink.secondary),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.m),
          _ActionButton(
            icon: Icons.sync_rounded,
            label: 'Đồng bộ ngay',
            onPressed: a.state == SyncState.syncing || a.busy
                ? null
                : a.syncNow,
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.file_download_outlined,
            label: 'Xuất dữ liệu',
            onPressed: a.busy
                ? null
                : () => exportJson(
                    context,
                    exporter,
                    'sky-weather-export.json',
                    a.exportServerData,
                  ),
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.cloud_off_outlined,
            label: 'Xoá dữ liệu đồng bộ',
            onPressed: a.busy ? null : () => _deleteData(context, a),
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.logout_rounded,
            label: 'Đăng xuất',
            onPressed: a.busy ? null : () => _signOut(context, a),
          ),
          const SizedBox(height: Space.l),
          FilledButton.icon(
            onPressed: a.busy ? null : () => _deleteAccount(context, a),
            icon: const Icon(Icons.delete_forever_rounded),
            label: const Text('Xoá tài khoản'),
            style: FilledButton.styleFrom(
              backgroundColor: _danger,
              foregroundColor: Palette.white,
              minimumSize: const Size.fromHeight(Touch.min),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _signOut(BuildContext context, AccountProvider a) async {
    final messenger = ScaffoldMessenger.of(context);
    await a.signOut();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Đã đăng xuất. Dữ liệu trên máy vẫn giữ nguyên.'),
      ),
    );
  }

  Future<void> _deleteData(BuildContext context, AccountProvider a) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AppThemeScope.wrapDialog(
        context,
        AlertDialog(
          title: const Text('Xoá dữ liệu đồng bộ?'),
          content: const Text(
            'Dữ liệu đã đồng bộ trên máy chủ sẽ bị xoá. Tài khoản và dữ liệu '
            'trên máy này vẫn giữ nguyên; thay đổi sau này sẽ được đồng bộ '
            'lại (đăng xuất nếu không muốn đồng bộ).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Huỷ'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              style: FilledButton.styleFrom(
                backgroundColor: _danger,
                foregroundColor: Palette.white,
                minimumSize: const Size(Touch.min, Touch.min),
              ),
              child: const Text('Xoá'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final err = await a.deleteSyncedData();
    messenger.showSnackBar(
      SnackBar(content: Text(err ?? 'Đã xoá dữ liệu đồng bộ trên máy chủ.')),
    );
  }

  Future<void> _deleteAccount(BuildContext context, AccountProvider a) async {
    final messenger = ScaffoldMessenger.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (c) =>
          AppThemeScope.wrapDialog(context, const _DeleteAccountDialog()),
    );
    if (password == null) return;
    final err = await a.deleteAccount(password);
    messenger.showSnackBar(
      SnackBar(
        content: Text(err ?? 'Đã xoá tài khoản và toàn bộ dữ liệu đồng bộ.'),
      ),
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _c = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    if (_c.text.isEmpty) {
      setState(() => _error = 'Nhập mật khẩu để xác nhận.');
      return;
    }
    Navigator.pop(context, _c.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Xoá tài khoản?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Tài khoản và toàn bộ dữ liệu đồng bộ sẽ bị xoá vĩnh viễn. '
            'Dữ liệu trên máy này vẫn giữ nguyên. Nhập lại mật khẩu để xác nhận.',
          ),
          const SizedBox(height: Space.l),
          TextField(
            key: const Key('delete-password'),
            controller: _c,
            obscureText: _obscure,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _ok(),
            decoration: InputDecoration(
              labelText: 'Mật khẩu',
              errorText: _error,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            minimumSize: const Size(Touch.min, Touch.min),
          ),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          key: const Key('confirm-delete-account'),
          onPressed: _ok,
          style: FilledButton.styleFrom(
            backgroundColor: _danger,
            foregroundColor: Palette.white,
            minimumSize: const Size(Touch.min, Touch.min),
          ),
          child: const Text('Xoá vĩnh viễn'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chinh sach quyen rieng tu

const Map<String, String> _policyTitles = {
  'lưu_gì': 'Lưu những gì',
  'bao_lâu': 'Lưu bao lâu',
  'xoá_thế_nào': 'Xoá thế nào',
  'không_cần_tài_khoản': 'Không cần tài khoản',
};

/// Ban du phong khi khong goi duoc GET /privacy.
const Map<String, String> _policyOffline = {
  'không_cần_tài_khoản':
      'Ứng dụng dùng đầy đủ mà không cần đăng nhập; tài khoản chỉ để đồng bộ '
      'giữa các thiết bị.',
  'lưu_gì':
      'Email, bản băm mật khẩu và dữ liệu đồng bộ (địa điểm đã lưu, cài đặt, '
      'hoạt động; thói quen chỉ khi bạn đồng ý). Không lưu vị trí GPS.',
};

Future<void> showPrivacyDialog(BuildContext context, AccountProvider a) {
  final future = a.privacyPolicy();
  return showDialog<void>(
    context: context,
    builder: (c) => AppThemeScope.wrapDialog(
      context,
      AlertDialog(
        title: const Text('Chính sách quyền riêng tư'),
        content: SizedBox(
          width: 480,
          child: FutureBuilder<Map<String, String>>(
            future: future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 96,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final offline = snap.hasError || snap.data == null;
              final p = offline ? _policyOffline : snap.data!;
              final t = Theme.of(c).textTheme;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (offline)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.m),
                        child: Text(
                          'Không tải được bản đầy đủ từ máy chủ; đây là bản tóm tắt.',
                          style: t.bodySmall,
                        ),
                      ),
                    for (final e in p.entries) ...[
                      Semantics(
                        header: true,
                        child: Text(
                          _policyTitles[e.key] ?? e.key.replaceAll('_', ' '),
                          style: t.titleSmall,
                        ),
                      ),
                      const SizedBox(height: Space.xs),
                      Text(e.value, style: t.bodyMedium),
                      const SizedBox(height: Space.m),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            style: TextButton.styleFrom(
              minimumSize: const Size(Touch.min, Touch.min),
            ),
            child: const Text('Đóng'),
          ),
        ],
      ),
    ),
  );
}
