part of '../account_screen.dart';

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSheetNavBar(
          title: 'Xóa tài khoản?',
          cancelLabel: 'Hủy',
          doneLabel: 'Xóa',
          doneKey: const Key('confirm-delete-account'),
          onDone: _ok,
        ),
        Text(
          'Tài khoản và toàn bộ dữ liệu đồng bộ sẽ bị xóa vĩnh viễn. '
          'Dữ liệu trên máy này vẫn giữ nguyên. Nhập lại mật khẩu để xác nhận.',
          style: TypeScale.body.copyWith(color: Palette.white),
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
          style: TypeScale.body.copyWith(color: Palette.white),
          decoration: InputDecoration(
            labelText: 'Mật khẩu',
            errorText: _error,
            suffixIcon: IosBarButton(
              tooltip: _obscure ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
              icon: _obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: Space.l),
        IosButton.filled(
          destructive: true,
          expand: true,
          icon: CupertinoIcons.trash,
          label: 'Xóa vĩnh viễn',
          onPressed: _ok,
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
  'xoá_thế_nào': 'Xóa thế nào',
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
  return showIosSheet<void>(
    context,
    title: 'Chính sách quyền riêng tư',
    builder: (c) => FutureBuilder<Map<String, String>>(
      future: future,
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 96,
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        final offline = snap.hasError || snap.data == null;
        final p = offline ? _policyOffline : snap.data!;
        final ink = GlassInk.of(c);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (offline)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.m),
                child: Text(
                  'Không tải được bản đầy đủ từ máy chủ; đây là bản tóm tắt.',
                  style: TypeScale.footnote.copyWith(color: ink.secondary),
                ),
              ),
            for (final e in p.entries) ...[
              Semantics(
                header: true,
                child: Text(
                  _policyTitles[e.key] ?? e.key.replaceAll('_', ' '),
                  style: TypeScale.headline.copyWith(color: Palette.white),
                ),
              ),
              const SizedBox(height: Space.xs),
              Text(
                e.value,
                style: TypeScale.body.copyWith(color: Palette.white),
              ),
              const SizedBox(height: Space.m),
            ],
          ],
        );
      },
    ),
  );
}
