import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/account_provider.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/account_service.dart';

const _a = 'https://server-a.example';
const _b = 'https://server-b.example';
const _session = AuthSession(
  token: 'test-token-a',
  email: 'a@example.test',
  expiresAt: 4102444800,
  serverUrl: _a,
);

http.Response _json(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig(this.client, {TokenStore? store}) {
    account = AccountProvider(
      service: AccountService(client: client),
      store: store ?? MemoryTokenStore(_session),
      debounce: const Duration(milliseconds: 10),
      retryDelay: const Duration(milliseconds: 10),
    );
    addTearDown(() {
      account.dispose();
      locations.dispose();
      weather.dispose();
      planner.dispose();
      prefs.dispose();
      client.close();
    });
  }

  final MockClient client;
  final locations = LocationProvider();
  final weather = WeatherProvider(initialSettings: const AppSettings());
  final planner = PlannerProvider();
  final prefs = PreferencesProvider();
  late final AccountProvider account;

  Future<void> start() =>
      account.attach(locations, weather, planner, prefs: prefs);
}

class _DelayedStore extends MemoryTokenStore {
  final writing = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> write(AuthSession s) async {
    writing.complete();
    await release.future;
    await super.write(s);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiConfig.setBaseUrl(_a);
  });
  tearDown(() => ApiConfig.setBaseUrl(null));

  test(
    'HTTP authentication and token requests are rejected before sending',
    () async {
      var sent = 0;
      final client = MockClient((_) async {
        sent++;
        return _json({});
      });
      addTearDown(client.close);
      final api = AccountService(
        client: client,
        baseUrl: 'http://server.example',
      );
      final insecure = throwsA(
        isA<AccountException>().having(
          (e) => e.kind,
          'kind',
          AccountErrorKind.insecureTransport,
        ),
      );
      await expectLater(api.login('a@example.test', 'test-password'), insecure);
      await expectLater(
        api.register('a@example.test', 'test-password'),
        insecure,
      );
      await expectLater(api.getData('test-token'), insecure);
      expect(sent, 0);
    },
  );

  test('authenticated requests do not follow redirects', () async {
    final client = MockClient((r) async {
      expect(r.followRedirects, isFalse);
      return http.Response('', 307, headers: {'location': _b});
    });
    addTearDown(client.close);
    await expectLater(
      AccountService(client: client).getData('test-token'),
      throwsA(isA<AccountException>()),
    );
  });

  test('service refuses an old token after switching the endpoint', () async {
    var sent = 0;
    final client = MockClient((_) async {
      sent++;
      return _json({});
    });
    addTearDown(client.close);
    final api = AccountService(client: client)..bindSession(_session);
    await ApiConfig.setBaseUrl(_b);
    await expectLater(
      api.getData(_session.token),
      throwsA(
        isA<AccountException>().having(
          (e) => e.kind,
          'kind',
          AccountErrorKind.unauthorized,
        ),
      ),
    );
    expect(sent, 0);
  });

  for (final stored in [
    const AuthSession(
      token: 'legacy',
      email: 'a@example.test',
      expiresAt: 4102444800,
    ),
    const AuthSession(
      token: 'other-server',
      email: 'a@example.test',
      expiresAt: 4102444800,
      serverUrl: _b,
    ),
  ]) {
    test(
      'unbound or mismatched stored sessions require login: ${stored.token}',
      () async {
        var sent = 0;
        final client = MockClient((_) async {
          sent++;
          return _json({});
        });
        final store = MemoryTokenStore(stored);
        final account = AccountProvider(
          service: AccountService(client: client),
          store: store,
        );
        final locations = LocationProvider();
        final weather = WeatherProvider(initialSettings: const AppSettings());
        final planner = PlannerProvider();
        addTearDown(() {
          account.dispose();
          locations.dispose();
          weather.dispose();
          planner.dispose();
          client.close();
        });
        await account.attach(locations, weather, planner);
        expect(account.isLoggedIn, isFalse);
        expect(store.session, isNull);
        expect(sent, 0);
      },
    );
  }

  test(
    'server change cancels queued sync and discards in-flight response',
    () async {
      Completer<http.Response>? delayed;
      final sent = <http.Request>[];
      final client = MockClient((r) async {
        sent.add(r);
        if (delayed != null && r.method == 'GET') return delayed.future;
        return _json({'version': 1, 'data': null, 'updated_at': 1});
      });
      final store = MemoryTokenStore(_session);
      final account = AccountProvider(
        service: AccountService(client: client),
        store: store,
      );
      final locations = LocationProvider();
      final weather = WeatherProvider(initialSettings: const AppSettings());
      final planner = PlannerProvider();
      final prefs = PreferencesProvider();
      addTearDown(() {
        account.dispose();
        locations.dispose();
        weather.dispose();
        planner.dispose();
        prefs.dispose();
        client.close();
      });
      await account.attach(locations, weather, planner, prefs: prefs);
      delayed = Completer<http.Response>();
      final pending = account.syncNow();
      await Future<void>.delayed(Duration.zero);
      await ApiConfig.setBaseUrl(_b);
      expect(account.isLoggedIn, isFalse);
      delayed.complete(
        _json({
          'version': 99,
          'updated_at': 1,
          'data': {
            'saved_places': [],
            'activities': [],
            'settings': {
              'units': {'temperature': 'f'},
              'updated_at': 9999999999999,
            },
          },
        }),
      );
      await pending;
      await account.syncNow();
      expect(sent.every((r) => r.url.origin == _a), isTrue);
      expect(prefs.units.isCelsius, isTrue);
      expect(store.session, isNull);
      expect(account.hasPendingChanges, isFalse);
    },
  );

  test('session stores the endpoint used for authentication', () async {
    final client = MockClient(
      (_) async => _json({
        'token': 'new-test-token',
        'email': 'a@example.test',
        'expires_at': 4102444800,
      }),
    );
    addTearDown(client.close);
    final session = await AccountService(client: client)
        .login('a@example.test', 'test-password');
    expect(session.serverUrl, _a);
    expect(AuthSession.tryFromJson(session.toJson())!.serverUrl, _a);
  });

  test('login response is rejected after switching away and back', () async {
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    final client = MockClient((_) {
      sent.complete();
      return response.future;
    });
    addTearDown(client.close);
    final api = AccountService(client: client);
    final login = api.login('a@example.test', 'test-password');
    await sent.future;
    await ApiConfig.setBaseUrl(_b);
    await ApiConfig.setBaseUrl(_a);
    final rejected = expectLater(
      login,
      throwsA(
        isA<AccountException>().having(
          (e) => e.kind,
          'kind',
          AccountErrorKind.unauthorized,
        ),
      ),
    );
    response.complete(
      _json({
        'token': 'late-token',
        'email': 'a@example.test',
        'expires_at': 4102444800,
      }),
    );
    await rejected;
  });

  test(
    'server change clears a session whose secure-store write was pending',
    () async {
      final store = _DelayedStore();
      final rig = _Rig(
        MockClient((request) async {
          expect(request.url.path, '/auth/login');
          return _json({
            'token': 'late-token',
            'email': 'a@example.test',
            'expires_at': 4102444800,
          });
        }),
        store: store,
      );
      await rig.start();
      final login = rig.account.signIn('a@example.test', 'test-password');
      await store.writing.future;
      await ApiConfig.setBaseUrl(_b);
      store.release.complete();
      expect(await login, AccountProvider.serverChangedMessage);
      await Future<void>.delayed(Duration.zero);
      expect(rig.account.isLoggedIn, isFalse);
      expect(store.session, isNull);
    },
  );

  test(
    'logout clears local access before remote revocation finishes',
    () async {
      final response = Completer<http.Response>();
      final logoutResponse = Completer<http.Response>();
      final getSent = Completer<void>();
      var delayGet = false;
      var puts = 0;
      final rig = _Rig(
        MockClient((request) async {
          if (request.url.path == '/auth/logout') return logoutResponse.future;
          if (delayGet && request.method == 'GET') {
            getSent.complete();
            return response.future;
          }
          if (request.method == 'PUT') puts++;
          return _json({'version': 1, 'data': null, 'updated_at': 1});
        }),
      );
      await rig.start();
      final originalPuts = puts;
      delayGet = true;
      final sync = rig.account.syncNow();
      await getSent.future;
      final logout = rig.account.signOut();
      expect(rig.account.isLoggedIn, isFalse);
      response.complete(
        _json({
          'version': 99,
          'updated_at': 1,
          'data': {
            'settings': {
              'units': {'temperature': 'f'},
              'updated_at': 9999999999999,
            },
          },
        }),
      );
      await sync;
      expect(rig.prefs.units.isCelsius, isTrue);
      expect(puts, originalPuts);
      logoutResponse.complete(_json({}));
      await logout;
      expect(rig.account.isLoggedIn, isFalse);
    },
  );

  test(
    'deleting synced data invalidates an older pull before it can push',
    () async {
      final response = Completer<http.Response>();
      final getSent = Completer<void>();
      var delayGet = false;
      var puts = 0;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            delayGet = false;
            return _json({});
          }
          if (delayGet && request.method == 'GET') {
            getSent.complete();
            return response.future;
          }
          if (request.method == 'PUT') puts++;
          return _json({'version': 1, 'data': null, 'updated_at': 1});
        }),
      );
      await rig.start();
      final originalPuts = puts;
      delayGet = true;
      final sync = rig.account.syncNow();
      await getSent.future;
      expect(await rig.account.deleteSyncedData(), isNull);
      response.complete(_json({'version': 1, 'data': null, 'updated_at': 1}));
      await sync;
      expect(rig.account.isLoggedIn, isTrue);
      expect(rig.account.hasPendingChanges, isFalse);
      expect(puts, originalPuts);
      expect(rig.account.busy, isFalse);
      expect(rig.account.state, SyncState.idle);
    },
  );

  test(
    'a server tombstone is not uploaded on startup or an unchanged refresh',
    () async {
      var puts = 0;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'PUT') {
            puts++;
            expect(jsonDecode(request.body)['base_version'], 2);
            return _json({'version': 3, 'data': null});
          }
          return _json({'version': 2, 'data': null});
        }),
      );
      await rig.start();
      await rig.account.syncNow();
      expect(puts, 0);
      expect(rig.account.hasPendingChanges, isFalse);
      rig.prefs.setTemperatureUnit(false);
      await rig.account.syncNow();
      expect(
        puts,
        1,
        reason: 'A new local edit may resume syncing after deletion',
      );
    },
  );

  test(
    'sync revision and pending state from another account are not restored',
    () async {
      SharedPreferences.setMockInitialValues({
        AccountProvider.metaKey: jsonEncode({
          'server_url': _a,
          'account_email': 'other@example.test',
          'version': 2,
          'pending': true,
          'last_synced': 1000,
        }),
      });
      var puts = 0;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'PUT') puts++;
          return _json({'version': 2, 'data': null});
        }),
      );
      await rig.start();
      expect(puts, 0);
      expect(rig.account.hasPendingChanges, isFalse);
    },
  );

  test(
    'a tombstone conflict never retries an old document over the deletion',
    () async {
      var puts = 0;
      var version = 1;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'PUT') {
            puts++;
            version = 2;
            return _json({
              'current': {'version': version, 'data': null},
            }, 409);
          }
          return _json({'version': version, 'data': null});
        }),
      );
      await rig.start();
      rig.prefs.setTemperatureUnit(false);
      await rig.account.syncNow();
      await rig.account.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(puts, 1);
      expect(rig.account.hasPendingChanges, isFalse);
      expect(rig.account.state, SyncState.idle);
    },
  );

  for (final accountDeletion in [true, false]) {
    test(
      'failed deletion restores a queued sync: account=$accountDeletion',
      () async {
        var version = 0;
        Map<String, dynamic>? data;
        final synced = Completer<void>();
        final rig = _Rig(
          MockClient((request) async {
            if (request.method == 'DELETE') {
              return _json({
                'detail': 'Delete rejected',
              }, accountDeletion ? 403 : 503);
            }
            if (request.method == 'PUT') {
              version++;
              data = jsonDecode(request.body)['data'] as Map<String, dynamic>;
              if (version > 1 && !synced.isCompleted) synced.complete();
            }
            return _json({'version': version, 'data': data});
          }),
        );
        await rig.start();
        rig.prefs.setTemperatureUnit(false);
        final error = await (accountDeletion
            ? rig.account.deleteAccount('wrong-password')
            : rig.account.deleteSyncedData());
        expect(error, isNotNull);
        await synced.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(rig.account.isLoggedIn, isTrue);
        expect(rig.account.hasPendingChanges, isFalse);
        expect(rig.account.state, SyncState.idle);
      },
    );
  }

  test(
    'a new edit syncs even if the revision read after deletion failed',
    () async {
      var deleted = false;
      var failRead = false;
      var puts = 0;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            deleted = true;
            failRead = true;
            return _json({});
          }
          if (failRead && request.method == 'GET') {
            failRead = false;
            throw http.ClientException('offline after successful deletion');
          }
          if (request.method == 'PUT') puts++;
          return _json({'version': deleted ? 2 : 1, 'data': null});
        }),
      );
      await rig.start();
      expect(await rig.account.deleteSyncedData(), isNull);
      rig.prefs.setTemperatureUnit(false);
      await rig.account.syncNow();
      expect(puts, 1);
      expect(rig.account.hasPendingChanges, isFalse);
    },
  );

  test(
    'an edit made during a failed deletion still retries after busy ends',
    () async {
      final deletion = Completer<http.Response>();
      final started = Completer<void>();
      final synced = Completer<void>();
      var version = 0;
      Map<String, dynamic>? data;
      final rig = _Rig(
        MockClient((request) async {
          if (request.method == 'DELETE') {
            started.complete();
            return deletion.future;
          }
          if (request.method == 'PUT') {
            version++;
            data = jsonDecode(request.body)['data'] as Map<String, dynamic>;
            if (version > 1 && !synced.isCompleted) synced.complete();
          }
          return _json({'version': version, 'data': data});
        }),
      );
      await rig.start();
      final pendingDelete = rig.account.deleteAccount('wrong-password');
      await started.future;
      rig.prefs.setTemperatureUnit(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      deletion.complete(_json({'detail': 'Wrong password'}, 403));
      expect(await pendingDelete, isNotNull);
      await synced.future.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect(rig.account.state, SyncState.idle);
      expect(rig.account.hasPendingChanges, isFalse);
    },
  );

  test(
    'URL validation excludes embedded credentials, spaces and invalid ports',
    () {
      for (final bad in [
        'https://user:secret@server.example',
        'https://a b.example',
        'https://server.example:99999',
      ]) {
        expect(ApiConfig.normalizeBaseUrl(bad), isNull, reason: bad);
      }
    },
  );
}
