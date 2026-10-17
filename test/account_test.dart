// Tai khoan tuy chon + dong bo (nhom 9). Backend gia bang MockClient (khong
// goi mang that); du lieu trong test la du lieu gia.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/providers/account_provider.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/account_screen.dart';
import 'package:sky_weather_app/services/account_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/utils/theme.dart';

const _base = 'http://test';

http.Response _json(Object? body, [int code = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  code,
  headers: {'content-type': 'application/json'},
);

AuthSession _session({int? expiresAt}) => AuthSession(
  token: 'tok',
  email: 'a@b.vn',
  expiresAt: expiresAt ?? 4102444800, // 2100
);

/// Backend gia: mot tai lieu co version; ghi lai moi PUT.
class _FakeBackend {
  int version = 0;
  Map<String, dynamic>? data;
  final List<Map<String, dynamic>> puts = [];
  int gets = 0;

  /// PUT tiep theo tra 409 voi tai lieu nay (gia lap thiet bi khac).
  Map<String, dynamic>? conflictWith;
  bool offline = false;
  bool unauthorized = false;

  MockClient get client => MockClient((req) async {
    if (offline) throw http.ClientException('offline');
    if (unauthorized) return _json({'detail': 'het han'}, 401);
    expect(req.headers['Authorization'], 'Bearer tok');
    if (req.method == 'GET' && req.url.path == '/me/data') {
      gets++;
      return _json({'version': version, 'data': data, 'updated_at': 1});
    }
    if (req.method == 'PUT' && req.url.path == '/me/data') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      puts.add(body);
      final other = conflictWith;
      if (other != null) {
        conflictWith = null;
        version++;
        data = other;
        return _json({
          'detail': 'xung dot',
          'current': {'version': version, 'data': data, 'updated_at': 2},
        }, 409);
      }
      if (body['base_version'] != version) {
        return _json({
          'detail': 'xung dot',
          'current': {'version': version, 'data': data, 'updated_at': 2},
        }, 409);
      }
      version++;
      data = body['data'] as Map<String, dynamic>;
      return _json({'version': version, 'data': data, 'updated_at': 3});
    }
    return _json({'detail': 'not found'}, 404);
  });
}

class _Rig {
  _Rig(this.backend, {AuthSession? session})
    : store = MemoryTokenStore(session) {
    account = AccountProvider(
      service: AccountService(client: backend.client, baseUrl: _base),
      store: store,
      debounce: const Duration(milliseconds: 150),
      retryDelay: const Duration(milliseconds: 60),
    );
  }

  final _FakeBackend backend;
  final MemoryTokenStore store;
  final lp = LocationProvider();
  final wp = WeatherProvider(initialSettings: const AppSettings());
  final pp = PlannerProvider();
  final prefs = PreferencesProvider();
  late final AccountProvider account;

  Future<void> start() => account.attach(lp, wp, pp, prefs: prefs);
}

Future<void> _wait([int ms = 150]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Retries [check] until it passes (or rethrows after [timeoutMs]); fixed
/// sleeps were flaky when the whole suite loaded the machine.
Future<void> _eventually(void Function() check, {int timeoutMs = 5000}) async {
  final sw = Stopwatch()..start();
  while (true) {
    try {
      check();
      return;
    } catch (_) {
      if (sw.elapsedMilliseconds > timeoutMs) rethrow;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AccountService', () {
    test('login: gui email/mat khau, doc token', () async {
      late http.Request sent;
      final s = AccountService(
        baseUrl: _base,
        client: MockClient((req) async {
          sent = req;
          return _json({
            'token': 'abc',
            'token_type': 'bearer',
            'expires_at': 2000000000,
            'email': 'a@b.vn',
          });
        }),
      );
      final session = await s.login(' A@b.vn ', 'matkhau123');
      expect(sent.url.path, '/auth/login');
      expect(jsonDecode(sent.body), {
        'email': 'A@b.vn',
        'password': 'matkhau123',
      });
      expect(session.token, 'abc');
      expect(session.email, 'a@b.vn');
      expect(session.expiresAt, 2000000000);
    });

    test('401: sai mat khau khi dang nhap / token het han', () async {
      final s = AccountService(
        baseUrl: _base,
        client: MockClient(
          (req) async =>
              _json({'detail': 'Email hoặc mật khẩu không đúng.'}, 401),
        ),
      );
      await expectLater(
        s.login('a@b.vn', 'sai-mat-khau'),
        throwsA(
          isA<AccountException>()
              .having((e) => e.kind, 'kind', AccountErrorKind.badLogin)
              .having(
                (e) => e.message,
                'message',
                'Email hoặc mật khẩu không đúng.',
              ),
        ),
      );
      await expectLater(
        s.getData('tok'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('409 dang ky = email trung; 429 = khoa', () async {
      var code = 409;
      final s = AccountService(
        baseUrl: _base,
        client: MockClient((req) async => _json({'detail': 'x'}, code)),
      );
      await expectLater(
        s.register('a@b.vn', '12345678'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.emailTaken,
          ),
        ),
      );
      code = 429;
      await expectLater(
        s.login('a@b.vn', '12345678'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.kind,
            'kind',
            AccountErrorKind.locked,
          ),
        ),
      );
    });

    test('409 PUT -> SyncConflict kem ban hien tai', () async {
      final s = AccountService(
        baseUrl: _base,
        client: MockClient(
          (req) async => _json({
            'detail': 'xung dot',
            'current': {
              'version': 7,
              'data': {'saved_places': []},
              'updated_at': 5,
            },
          }, 409),
        ),
      );
      await expectLater(
        s.putData('tok', 3, {'saved_places': []}),
        throwsA(
          isA<SyncConflict>()
              .having((c) => c.current.version, 'version', 7)
              .having((c) => c.current.data, 'data', {'saved_places': []}),
        ),
      );
    });

    test(
      '422: location_id sai / loi Pydantic; GPS bi chan truoc khi gui',
      () async {
        var calls = 0;
        Object detail = {
          'message': 'Địa điểm không tồn tại.',
          'unknown_location_ids': ['xx'],
        };
        final s = AccountService(
          baseUrl: _base,
          client: MockClient((req) async {
            calls++;
            return _json({'detail': detail}, 422);
          }),
        );
        await expectLater(
          s.putData('tok', 0, {'saved_places': []}),
          throwsA(
            isA<AccountException>()
                .having((e) => e.kind, 'kind', AccountErrorKind.invalid)
                .having((e) => e.unknownLocationIds, 'ids', ['xx']),
          ),
        );
        detail = [
          {
            'loc': ['body'],
            'msg':
                'Value error, Chỉ đồng bộ thói quen khi người dùng đã đồng ý.',
          },
        ];
        await expectLater(
          s.putData('tok', 0, {'habits': {}}),
          throwsA(
            isA<AccountException>().having(
              (e) => e.message,
              'message',
              'Chỉ đồng bộ thói quen khi người dùng đã đồng ý.',
            ),
          ),
        );
        expect(calls, 2);
        await expectLater(
          s.putData('tok', 0, {
            'saved_places': [
              {'id': 'a', 'lat': 10.8},
            ],
          }),
          throwsA(isA<AccountException>()),
        );
        expect(calls, 2, reason: 'Toa do GPS khong duoc gui di');
      },
    );
  });

  group('AccountProvider', () {
    test('dang nhap: keo ve, day len; debounce gop nhieu thay doi', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      expect(b.gets, 1);
      expect(b.puts, hasLength(1), reason: 'May chu trong -> day ban dau');
      expect(rig.account.state, SyncState.idle);
      expect(rig.account.lastSyncedAt, isNotNull);

      rig.lp.addSaved('q1');
      rig.lp.addSaved('q3', label: PlaceLabel.home);
      rig.wp.setTemperatureUnit(false);
      await _wait(15);
      expect(b.puts, hasLength(1), reason: 'Chua het thoi gian debounce');
      await _eventually(() => expect(b.puts.length, greaterThanOrEqualTo(2)));
      await _wait();
      expect(b.puts, hasLength(2), reason: 'Ba thay doi -> mot lan PUT');
      final doc = b.puts.last['data'] as Map<String, dynamic>;
      expect(
        [for (final p in doc['saved_places'] as List) p['id']],
        ['tsn', 'q1', 'q3'],
      );
      expect((doc['saved_places'] as List)[2], {
        'id': 'q3',
        'label': 'home',
        'custom_name': null,
        'order': 2,
      });
      expect((doc['settings'] as Map)['units'], {'temperature': 'f'});
      expect(b.puts.last['base_version'], 1);
    });

    test('khong gui toa do GPS / id vi tri hien tai', () async {
      SharedPreferences.setMockInitialValues({
        LocationProvider.gpsKey: 'gps-ward',
      });
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      expect(rig.lp.currentLocationId, 'gps-ward');
      final body = jsonEncode(b.puts.single);
      expect(containsGpsKey(b.puts.single), isFalse);
      expect(body.contains('gps-ward'), isFalse);
    });

    test('thoi quen chi gui khi da dong y', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      final first = b.puts.single['data'] as Map;
      expect(first['habits_consent'], isFalse);
      expect(first['habits'], isNull);

      rig.pp.setHabitLearning(true);
      rig.pp.recordAppOpen();
      await _eventually(
        () => expect((b.puts.last['data'] as Map)['habits_consent'], isTrue),
      );
      final doc = b.puts.last['data'] as Map;
      expect(doc['habits_consent'], isTrue);
      expect((doc['habits'] as Map)['opens'], isNotEmpty);

      rig.pp.setHabitLearning(false);
      await _eventually(
        () => expect((b.puts.last['data'] as Map)['habits'], isNull),
      );
    });

    test('409: gop dia diem theo id roi gui lai mot lan', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      expect(b.version, 1);

      // Thiet bi khac luu truoc: co q9 + q1 (ten rieng), cai dat cu hon.
      b.conflictWith = {
        'saved_places': [
          {'id': 'q9', 'label': 'work', 'custom_name': null, 'order': 0},
          {'id': 'q1', 'label': 'none', 'custom_name': null, 'order': 1},
        ],
        'settings': {
          'theme': 'dark',
          'updated_at': 1,
          'places_updated_at': 1,
          'activities_updated_at': 0,
        },
        'activities': [],
        'habits_consent': false,
        'habits': null,
      };
      rig.lp.addSaved('q1', label: PlaceLabel.home);
      await _eventually(() => expect(b.puts.length, greaterThanOrEqualTo(3)));
      await _wait();

      expect(b.puts, hasLength(3), reason: 'PUT -> 409 -> gop -> PUT lai');
      expect(b.puts.last['base_version'], 2);
      final doc = b.puts.last['data'] as Map;
      // Ban tren may moi hon: dung truoc va thang khi trung id; q9 duoc giu.
      expect(
        [for (final p in doc['saved_places'] as List) p['id']],
        ['tsn', 'q1', 'q9'],
      );
      expect((doc['saved_places'] as List)[1]['label'], 'home');
      expect([for (final s in rig.lp.saved) s.locationId], ['tsn', 'q1', 'q9']);
      // Cai dat: ban tren may chua sua (updated_at 0 < 1) -> lay may chu.
      expect((doc['settings'] as Map)['theme'], 'dark');
      expect(rig.wp.themeMode, ThemeMode.dark);
      expect(rig.account.state, SyncState.idle);
      expect(b.version, 3);
    });

    test('mergeDocuments: bia mo dia diem da xoa, them lai thi giu', () {
      const day = 24 * 3600 * 1000;
      const now = 100 * day;
      Map<String, dynamic> doc(
        List<String> ids, {
        Map<String, int> deleted = const {},
        Map<String, int> added = const {},
        int placesAt = 0,
      }) => {
        'saved_places': [
          for (var i = 0; i < ids.length; i++) {'id': ids[i], 'order': i},
        ],
        'settings': {
          'places_updated_at': placesAt,
          'deleted_places': deleted,
          'places_added_at': added,
        },
        'activities': [],
        'habits_consent': false,
      };
      List<Object?> ids(Map<String, dynamic> d) => [
        for (final p in d['saved_places'] as List) p['id'],
      ];

      // Thiet bi khac (cu, moi sua sau) van con q9 -> khong song lai.
      final m = AccountProvider.mergeDocuments(
        doc(['tsn'], deleted: {'q9': now - day}, placesAt: now - day),
        doc(['tsn', 'q9'], placesAt: now),
        nowMs: now,
      );
      expect(ids(m), ['tsn']);
      expect((m['settings'] as Map)['deleted_places'], {'q9': now - day});

      // Them lai sau khi xoa -> giu, bia mo bi bo.
      final r = AccountProvider.mergeDocuments(
        doc(['tsn'], deleted: {'q9': now - day}),
        doc(['tsn', 'q9'], added: {'q9': now}, placesAt: now),
        nowMs: now,
      );
      expect(ids(r), ['tsn', 'q9']);
      expect((r['settings'] as Map)['deleted_places'], isEmpty);

      // Qua 30 ngay: bia mo het han.
      final old = AccountProvider.mergeDocuments(
        doc(['tsn'], deleted: {'q9': now - 31 * day}),
        doc(['tsn', 'q9'], placesAt: now),
        nowMs: now,
      );
      expect(ids(old), ['tsn', 'q9']);
    });

    test('409: dia diem da xoa khong song lai', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      rig.lp.addSaved('q9');
      await _eventually(
        () => expect([
          for (final p in (b.puts.last['data'] as Map)['saved_places'] as List)
            p['id'],
        ], contains('q9')),
      );
      rig.lp.removeSavedAt(
        rig.lp.saved.indexWhere((s) => s.locationId == 'q9'),
      );
      // Thiet bi khac luu truoc, van con q9.
      b.conflictWith = {
        'saved_places': [
          {'id': 'tsn', 'label': 'none', 'custom_name': null, 'order': 0},
          {'id': 'q9', 'label': 'none', 'custom_name': null, 'order': 1},
        ],
        'settings': {'updated_at': 1, 'places_updated_at': 1},
        'activities': [],
        'habits_consent': false,
        'habits': null,
      };
      await _eventually(
        () => expect(
          ((b.puts.last['data'] as Map)['settings'] as Map)['deleted_places'],
          contains('q9'),
        ),
      );
      final doc = b.puts.last['data'] as Map;
      expect([for (final p in doc['saved_places'] as List) p['id']], ['tsn']);
      expect((doc['settings'] as Map)['deleted_places'], contains('q9'));
      expect([for (final s in rig.lp.saved) s.locationId], ['tsn']);
    });

    test('dong bo cai dat ca nhan (don vi) va nguong theo dia diem', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      rig.prefs.setUnits(const UnitPrefs(wind: WindUnit.ms));
      rig.pp.setSettings(
        rig.pp.settings.withPlace(
          'tsn',
          const PlaceAlertOverride(enabled: false),
        ),
      );
      await _eventually(
        () => expect(
          (((b.puts.last['data'] as Map)['settings'] as Map)['alerts']
              as Map)['places'],
          isNotNull,
        ),
      );
      final s = (b.puts.last['data'] as Map)['settings'] as Map;
      expect(((s['preferences'] as Map)['units'] as Map)['wind'], 'ms');
      expect(((s['alerts'] as Map)['places'] as Map)['tsn'], isNotNull);

      // Thiet bi moi (may trong): ap ban tu may chu vao provider.
      SharedPreferences.setMockInitialValues({});
      final other = _Rig(b, session: _session());
      await other.start();
      expect(other.prefs.units.wind, WindUnit.ms);
      expect(other.pp.settings.placeOverride('tsn').enabled, isFalse);
    });

    test('mergeDocuments: cai dat theo updated_at moi hon', () {
      Map<String, dynamic> doc(String theme, int at) => {
        'saved_places': [],
        'settings': {'theme': theme, 'updated_at': at},
        'activities': [],
        'habits_consent': false,
      };
      expect(
        AccountProvider.mergeDocuments(
          doc('light', 5),
          doc('dark', 3),
        )['settings']['theme'],
        'light',
      );
      expect(
        AccountProvider.mergeDocuments(
          doc('light', 2),
          doc('dark', 3),
        )['settings']['theme'],
        'dark',
      );
    });

    test('401 -> dang xuat em, co thong bao', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      b.unauthorized = true;
      rig.lp.addSaved('q2');
      await _eventually(() => expect(rig.account.isLoggedIn, isFalse));
      expect(rig.store.session, isNull);
      expect(rig.account.notice, AccountProvider.expiredMessage);
      expect(rig.lp.isSaved('q2'), isTrue, reason: 'Du lieu tren may giu');
    });

    test('token het han luc mo app -> dang xuat, khong goi mang', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session(expiresAt: 1000));
      await rig.start();
      expect(rig.account.isLoggedIn, isFalse);
      expect(rig.account.notice, isNotNull);
      expect(b.gets, 0);
    });

    test('mat mang: xep hang roi day khi co mang lai', () async {
      final b = _FakeBackend();
      final rig = _Rig(b, session: _session());
      await rig.start();
      b.offline = true;
      rig.lp.addSaved('q5');
      await _eventually(() => expect(rig.account.state, SyncState.pending));
      expect(rig.account.hasPendingChanges, isTrue);
      b.offline = false;
      await _eventually(() => expect(rig.account.state, SyncState.idle));
      expect([
        for (final p in b.data!['saved_places'] as List) p['id'],
      ], contains('q5'));
    });
  });

  group('AccountScreen', () {
    Future<_Rig> pump(
      WidgetTester tester,
      _FakeBackend b, {
      AuthSession? session,
      JsonExporter? exporter,
    }) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rig = _Rig(b, session: session);
      await tester.runAsync(rig.start);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<WeatherProvider>.value(value: rig.wp),
            ChangeNotifierProvider<AccountProvider>.value(value: rig.account),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: AppSceneScope(child: child!),
            ),
            home: AccountScreen(
              exporter: exporter ?? (name, json) async => null,
            ),
          ),
        ),
      );
      await tester.pump();
      return rig;
    }

    testWidgets(
      'chua dang nhap: form, kiem tra hop le, xuat du lieu tren may',
      (tester) async {
        String? exported;
        await pump(
          tester,
          _FakeBackend(),
          exporter: (name, json) async {
            exported = json;
            return '/tmp/$name';
          },
        );
        expect(
          find.textContaining('Không cần tài khoản để dùng app'),
          findsOneWidget,
        );
        final pw = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const Key('account-password')),
            matching: find.byType(TextField),
          ),
        );
        expect(pw.obscureText, isTrue);
        expect(pw.autofillHints, [AutofillHints.password]);

        await tester.tap(find.byTooltip('Hiện mật khẩu'));
        await tester.pump();
        expect(find.byTooltip('Ẩn mật khẩu'), findsOneWidget);

        await tester.enterText(find.byKey(const Key('account-email')), 'abc');
        await tester.enterText(
          find.byKey(const Key('account-password')),
          '123',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Đăng nhập'));
        await tester.pump();
        expect(find.text('Email không hợp lệ.'), findsOneWidget);
        expect(
          find.text('Mật khẩu phải có từ 8 đến 128 ký tự.'),
          findsOneWidget,
        );

        await tester.tap(find.text('Xuất dữ liệu trên máy'));
        await tester.pump();
        expect(exported, isNotNull);
        expect(containsGpsKey(jsonDecode(exported!)), isFalse);
        expect(find.textContaining('Đã lưu tệp'), findsOneWidget);

        // Cham >= 48 dp.
        final size = tester.getSize(
          find.widgetWithText(OutlinedButton, 'Xuất dữ liệu trên máy'),
        );
        expect(size.height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets('da dang nhap: trang thai, nut, hop thoai xoa tai khoan', (
      tester,
    ) async {
      final b = _FakeBackend();
      await pump(tester, b, session: _session());
      expect(find.text('a@b.vn'), findsOneWidget);
      expect(find.textContaining('Đã đồng bộ lúc'), findsOneWidget);
      for (final t in [
        'Đồng bộ ngay',
        'Xuất dữ liệu',
        'Xoá dữ liệu đồng bộ',
        'Đăng xuất',
        'Xoá tài khoản',
      ]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      final danger = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Xoá tài khoản'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(
        danger.style?.backgroundColor?.resolve({}),
        const Color(0xFFB3261E),
      );

      await tester.tap(find.text('Xoá tài khoản'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-password')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete-account')));
      await tester.pump();
      expect(find.text('Nhập mật khẩu để xác nhận.'), findsOneWidget);
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-password')), findsNothing);
    });
  });
}
