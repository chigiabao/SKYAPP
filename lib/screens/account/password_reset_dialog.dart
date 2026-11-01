import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/account_service.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/ios_controls.dart';
import '../../ui/weather/widgets/ios_sheet.dart';

Future<void> showPasswordResetDialog(
  BuildContext context, {
  String email = '',
  AccountService? service,
}) async {
  await showIosSheet<void>(
    context,
    form: true,
    scrollable: false,
    dismissible: false,
    builder: (_) => PasswordResetDialog(email: email, service: service),
  );
}

class PasswordResetDialog extends StatefulWidget {
  const PasswordResetDialog({super.key, this.email = '', this.service});

  final String email;
  final AccountService? service;

  @override
  State<PasswordResetDialog> createState() => _PasswordResetDialogState();
}

class _PasswordResetDialogState extends State<PasswordResetDialog> {
  final _form = GlobalKey<FormState>();
  final _token = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final _email = TextEditingController(text: widget.email);
  late final _service = widget.service ?? AccountService();
  bool _requested = false;
  bool _busy = false;
  bool _done = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    if (widget.service == null) _service.close();
    _email.dispose();
    _token.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_requested) {
        await _service.resetPassword(_email.text, _token.text, _password.text);
        if (!mounted) return;
        _token.clear();
        _password.clear();
        _confirm.clear();
        TextInput.finishAutofillContext(shouldSave: false);
        setState(() => _done = true);
      } else {
        await _service.requestPasswordReset(_email.text);
        if (mounted) setState(() => _requested = true);
      }
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Không thể khôi phục mật khẩu. Vui lòng thử lại.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _decoration(String label) =>
      InputDecoration(labelText: label, errorMaxLines: 3);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSheetNavBar(
          title: 'Khôi phục mật khẩu',
          cancelLabel: _done ? 'Đóng' : 'Hủy',
          cancelEnabled: !_busy,
          doneKey: const Key('reset-submit'),
          busy: _busy,
          doneLabel: _done
              ? 'Xong'
              : _requested
              ? 'Đổi mật khẩu'
              : 'Gửi mã',
          onDone: _done ? () => Navigator.pop(context) : _submit,
        ),
        Flexible(
          child: SingleChildScrollView(
            child: _done
                ? Semantics(
                    liveRegion: true,
                    child: const Text(
                      'Đã đổi mật khẩu và đăng xuất tất cả thiết bị. '
                      'Đăng nhập lại bằng mật khẩu mới.',
                    ),
                  )
                : Form(
                    key: _form,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            key: const Key('reset-email'),
                            controller: _email,
                            enabled: !_busy && !_requested,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: const [AutofillHints.email],
                            decoration: _decoration('Email'),
                            validator: (value) {
                              final email = (value ?? '').trim();
                              if (email.length > 254 ||
                                  !RegExp(r'^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$')
                                      .hasMatch(email)) {
                                return 'Email không hợp lệ.';
                              }
                              return null;
                            },
                            onFieldSubmitted: (_) => _submit(),
                          ),
                          if (_requested) ...[
                            const SizedBox(height: Space.m),
                            Semantics(
                              liveRegion: true,
                              child: const Text(
                                'Nếu email có tài khoản, mã sẽ được gửi. '
                                'Kiểm tra cả thư rác. Mã có hiệu lực 15 phút.',
                              ),
                            ),
                            const SizedBox(height: Space.m),
                            TextFormField(
                              key: const Key('reset-token'),
                              controller: _token,
                              enabled: !_busy,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.oneTimeCode],
                              textInputAction: TextInputAction.next,
                              decoration: _decoration('Mã khôi phục'),
                              validator: (value) =>
                                  (value ?? '').trim().isEmpty ||
                                      (value ?? '').trim().length > 128
                                  ? 'Nhập mã khôi phục trong email.'
                                  : null,
                            ),
                            const SizedBox(height: Space.m),
                            TextFormField(
                              key: const Key('reset-password'),
                              controller: _password,
                              enabled: !_busy,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.newPassword],
                              textInputAction: TextInputAction.next,
                              decoration: _decoration('Mật khẩu mới').copyWith(
                                suffixIcon: IconButton(
                                  tooltip: _obscure
                                      ? 'Hiện mật khẩu'
                                      : 'Ẩn mật khẩu',
                                  onPressed: _busy
                                      ? null
                                      : () => setState(
                                          () => _obscure = !_obscure,
                                        ),
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_rounded
                                        : Icons.visibility_off_rounded,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                final length = (value ?? '').runes.length;
                                return length < 8 || length > 128
                                    ? 'Mật khẩu phải có từ 8 đến 128 ký tự.'
                                    : null;
                              },
                            ),
                            const SizedBox(height: Space.m),
                            TextFormField(
                              key: const Key('reset-confirm-password'),
                              controller: _confirm,
                              enabled: !_busy,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.newPassword],
                              textInputAction: TextInputAction.done,
                              decoration: _decoration('Nhập lại mật khẩu mới'),
                              validator: (value) => value != _password.text
                                  ? 'Mật khẩu nhập lại không khớp.'
                                  : null,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: Space.m),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Palette.dangerOnGlass,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
        ),
        if (_requested && !_done)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: IosButton.plain(
              key: const Key('reset-change-email'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _requested = false;
                      _error = null;
                      _token.clear();
                      _password.clear();
                      _confirm.clear();
                      _form.currentState?.reset();
                    }),
              label: 'Đổi email / gửi lại',
            ),
          ),
      ],
    ),
  );
}
