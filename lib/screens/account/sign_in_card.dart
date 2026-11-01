part of '../account_screen.dart';

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
      AppHaptics.success();
      showIosToast(
        context,
        _register ? 'Đã tạo tài khoản và đồng bộ.' : 'Đã đăng nhập.',
        tone: IosToastTone.success,
      );
    } else {
      AppHaptics.error();
      setState(() => _error = err);
    }
  }

  InputDecoration _deco(BuildContext context, String label, {Widget? suffix}) {
    final ink = GlassInk.of(context);
    OutlineInputBorder b(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.field),
      borderSide: BorderSide(color: c),
    );
    final err = Theme.of(context).colorScheme.error;
    return InputDecoration(
      labelText: label,
      labelStyle: TypeScale.body.copyWith(color: ink.secondary),
      floatingLabelStyle: TypeScale.body.copyWith(color: Palette.white),
      filled: true,
      fillColor: Palette.subtleFill,
      enabledBorder: b(Palette.fieldBorder),
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
    return IosListSection.padded(
      header: _register ? 'Tạo tài khoản' : 'Đăng nhập',
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSegmentedControl<bool>(
                segments: const [
                  AppSegment(value: false, label: 'Đăng nhập'),
                  AppSegment(value: true, label: 'Đăng ký'),
                ],
                selected: _register,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        _register = v;
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
                  foregroundColor: Palette.onWhite,
                  minimumSize: const Size.fromHeight(Touch.min),
                ),
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CupertinoActivityIndicator(
                          radius: 10,
                          color: Palette.onWhite,
                        ),
                      )
                    : Text(_register ? 'Tạo tài khoản' : 'Đăng nhập'),
              ),
              if (!_register) ...[
                const SizedBox(height: Space.s),
                TextButton(
                  key: const Key('account-forgot-password'),
                  onPressed: busy
                      ? null
                      : () => showPasswordResetDialog(
                          context,
                          email: _email.text.trim(),
                        ),
                  style: TextButton.styleFrom(
                    foregroundColor: Palette.white,
                    minimumSize: const Size.fromHeight(Touch.min),
                  ),
                  child: const Text('Quên mật khẩu?'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Da dang nhap
