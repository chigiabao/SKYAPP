// Fake HTTP delivery only; no real email, credentials or backend connection.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sky_weather_app/screens/account/password_reset_dialog.dart';
import 'package:sky_weather_app/services/account_service.dart';

const _requestPath = '/auth/password-reset/request';
const _confirmPath = '/auth/password-reset/confirm';
const _email = 'owner@example.com';
const _password = 'new-password-123';
const _token = 'fake-recovery-token';

http.Response _json(Object body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

AccountService _service(Future<http.Response> Function(http.Request) handler) =>
    AccountService(client: MockClient(handler), baseUrl: 'https://test');

Future<void> _open(
  WidgetTester tester,
  AccountService service, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPasswordResetDialog(
              context,
              email: _email,
              service: service,
            ),
            child: const Text('Open recovery'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open recovery'));
  await tester.pumpAndSettle();
}

Future<void> _request(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('reset-submit')));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String confirmation = _password,
}) async {
  for (final entry in {
    'reset-token': _token,
    'reset-password': _password,
    'reset-confirm-password': confirmation,
  }.entries) {
    final field = find.byKey(Key(entry.key));
    await tester.ensureVisible(field);
    await tester.enterText(field, entry.value);
  }
}

void main() {
  test('service uses HTTPS JSON POST without a session or deep link', () async {
    final calls = <http.Request>[];
    final service = _service((request) async {
      calls.add(request);
      return request.url.path == _requestPath
          ? _json({'message': 'Generic accepted response'}, 202)
          : http.Response('', 204);
    });
    addTearDown(service.close);
    await service.requestPasswordReset(' $_email ');
    await service.resetPassword(' $_email ', ' $_token ', _password);
    expect(calls.map((r) => r.url.path), [_requestPath, _confirmPath]);
    expect(
      calls.every((r) => r.method == 'POST' && !r.followRedirects),
      isTrue,
    );
    expect(calls.every((r) => !r.headers.containsKey('Authorization')), isTrue);
    expect(jsonDecode(calls[0].body), {'email': _email});
    expect(jsonDecode(calls[1].body), {
      'email': _email,
      'token': _token,
      'password': _password,
    });
    expect(calls[1].url.query, isEmpty);
  });

  test('recovery refuses plaintext transport before sending secrets', () async {
    var called = false;
    final service = AccountService(
      baseUrl: 'http://test',
      client: MockClient((request) async {
        called = true;
        return http.Response('', 204);
      }),
    );
    addTearDown(service.close);
    final insecure = isA<AccountException>().having(
      (e) => e.kind,
      'kind',
      AccountErrorKind.insecureTransport,
    );
    await expectLater(service.requestPasswordReset(_email), throwsA(insecure));
    await expectLater(
      service.resetPassword(_email, _token, _password),
      throwsA(insecure),
    );
    expect(called, isFalse);
  });

  test(
    'configured-unavailable message and invalid-code errors are preserved',
    () async {
      var status = 503;
      final service = _service(
        (_) async => _json({'detail': 'Recovery unavailable'}, status),
      );
      addTearDown(service.close);
      await expectLater(
        service.requestPasswordReset(_email),
        throwsA(
          isA<AccountException>()
              .having((e) => e.kind, 'kind', AccountErrorKind.server)
              .having((e) => e.message, 'message', 'Recovery unavailable'),
        ),
      );
      status = 422;
      await expectLater(
        service.resetPassword(_email, _token, _password),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.invalid,
          ),
        ),
      );
      status = 429;
      await expectLater(
        service.resetPassword(_email, _token, _password),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.locked,
          ),
        ),
      );
    },
  );

  testWidgets(
    'email then code and password, with explicit success and no auto-login',
    (tester) async {
      final paths = <String>[];
      final service = _service((request) async {
        paths.add(request.url.path);
        return request.url.path == _requestPath
            ? _json({'message': 'Generic response'}, 202)
            : http.Response('', 204);
      });
      addTearDown(service.close);
      await _open(tester, service);
      expect(find.byKey(const Key('reset-token')), findsNothing);
      await _request(tester);
      expect(find.byKey(const Key('reset-token')), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('reset-email')))
            .enabled,
        isFalse,
      );
      await _fill(tester);
      await _request(tester);
      expect(find.textContaining('Đã đổi mật khẩu'), findsOneWidget);
      expect(find.byKey(const Key('reset-password')), findsNothing);
      expect(paths, [_requestPath, _confirmPath]);
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordResetDialog), findsNothing);
    },
  );

  testWidgets(
    'loading disables resubmit, edit and cancellation without duplicate requests',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final service = _service((_) {
        calls++;
        return pending.future;
      });
      addTearDown(service.close);
      await _open(tester, service);
      await tester.tap(find.byKey(const Key('reset-submit')));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const Key('reset-submit')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('reset-email')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<CupertinoButton>(
              find.widgetWithText(CupertinoButton, 'Hủy'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      pending.complete(_json({'message': 'Generic response'}, 202));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const Key('reset-token')), findsOneWidget);
    },
  );

  testWidgets('SMTP unavailable stays on request step and can retry', (
    tester,
  ) async {
    var unavailable = true;
    final service = _service(
      (_) async => unavailable
          ? _json({'detail': 'Email recovery is unavailable'}, 503)
          : _json({'message': 'Generic response'}, 202),
    );
    addTearDown(service.close);
    await _open(tester, service);
    await _request(tester);
    expect(find.text('Email recovery is unavailable'), findsOneWidget);
    expect(find.byKey(const Key('reset-token')), findsNothing);
    unavailable = false;
    await _request(tester);
    expect(find.text('Email recovery is unavailable'), findsNothing);
    expect(find.byKey(const Key('reset-token')), findsOneWidget);
  });

  testWidgets('bad code keeps form data and error is a live region', (
    tester,
  ) async {
    final service = _service(
      (request) async => request.url.path == _requestPath
          ? _json({'message': 'Generic response'}, 202)
          : _json({'detail': 'Invalid or expired code'}, 422),
    );
    addTearDown(service.close);
    await _open(tester, service);
    await _request(tester);
    await _fill(tester);
    await _request(tester);
    expect(find.text('Invalid or expired code'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('reset-token')))
          .controller!
          .text,
      _token,
    );
    final errorRegion = find
        .ancestor(
          of: find.text('Invalid or expired code'),
          matching: find.byType(Semantics),
        )
        .first;
    expect(tester.widget<Semantics>(errorRegion).properties.liveRegion, isTrue);
    expect(find.textContaining('Đã đổi mật khẩu'), findsNothing);
  });

  testWidgets('invalid email and mismatched passwords are rejected locally', (
    tester,
  ) async {
    var calls = 0;
    final service = _service((_) async {
      calls++;
      return _json({'message': 'Generic response'}, 202);
    });
    addTearDown(service.close);
    await _open(tester, service);
    await tester.enterText(
      find.byKey(const Key('reset-email')),
      'not-an-email',
    );
    await _request(tester);
    expect(calls, 0);
    expect(find.text('Email không hợp lệ.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('reset-email')), _email);
    await _request(tester);
    await _fill(tester, confirmation: 'different-password');
    await _request(tester);
    expect(calls, 1);
    expect(find.text('Mật khẩu nhập lại không khớp.'), findsOneWidget);
  });

  testWidgets('change email or resend clears recovery secrets', (tester) async {
    final service = _service(
      (_) async => _json({'message': 'Generic response'}, 202),
    );
    addTearDown(service.close);
    await _open(tester, service);
    await _request(tester);
    await _fill(tester);
    await tester.tap(find.byKey(const Key('reset-change-email')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-token')), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('reset-email')))
          .enabled,
      isTrue,
    );
    await _request(tester);
    for (final key in [
      'reset-token',
      'reset-password',
      'reset-confirm-password',
    ]) {
      expect(
        tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text,
        isEmpty,
      );
    }
  });

  testWidgets('narrow dialog with large text scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _service(
      (request) async => request.url.path == _requestPath
          ? _json({'message': 'Generic response'}, 202)
          : http.Response('', 204),
    );
    addTearDown(service.close);
    await _open(tester, service, textScale: 2);
    await _request(tester);
    await _fill(tester);
    expect(tester.takeException(), isNull);
    await _request(tester);
    expect(find.textContaining('Đã đổi mật khẩu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
