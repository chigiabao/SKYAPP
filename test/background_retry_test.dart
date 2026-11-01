import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/activities.dart';
import 'package:sky_weather_app/services/app_settings_store.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/models/weather_alerts.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/background/background_check.dart';
import 'package:sky_weather_app/services/notification_service.dart';

final _now = DateTime.utc(2026, 10, 21, 14, 10);
DateTime _clock() => HcmTime.toInstant(_now);

WeatherData _weather({bool empty = false}) => WeatherData(
  current: CurrentWeather(
    temperature: 27,
    condition: WeatherCondition.cloudy,
    weatherCode: 3,
    lastUpdated: _now,
  ),
  hourlyForecast: [
    if (!empty)
      for (var i = 0; i < 48; i++)
        HourlyForecast(
          time: HcmTime.startOfHour(_now).add(Duration(hours: i)),
          temperature: 27,
          condition: WeatherCondition.cloudy,
          weatherCode: i == 2 || i == 3 ? 95 : 3,
          rainProbability: i == 2 || i == 3 ? 0.95 : 0.05,
          uvIndex: 2,
          windGusts: 15,
          usAqi: 40,
          source: DataSource.forecast,
        ),
  ],
  dailyForecast: const [],
);

class _WeatherApi extends ApiService {
  _WeatherApi(this.responses)
    : super(
        client: MockClient((_) async => throw StateError('Unexpected HTTP')),
      );

  final Map<String, Object> responses;
  final List<String> calls = [];

  @override
  Future<WeatherData> fetchWeatherDataFor(
    String locationId, {
    DateTime? at,
  }) async {
    expect(at, isNull);
    calls.add(locationId);
    final response = responses[locationId];
    if (response is WeatherData) return response;
    throw response ?? StateError('Unexpected location');
  }
}

class _Notifications extends NoopNotificationService {
  final List<int> shown = [];
  final List<int> scheduled = [];
  final showStarted = Completer<void>();
  Completer<void>? showGate;
  Object? initError;
  int inits = 0;
  int permissionRequests = 0;
  int cancels = 0;

  @override
  Future<bool> init() async {
    inits++;
    if (initError case final Object error) throw error;
    return true;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return false;
  }

  @override
  Future<void> show(int id, String title, String body) async {
    if (!showStarted.isCompleted) showStarted.complete();
    await showGate?.future;
    shown.add(id);
  }

  @override
  Future<void> schedule(
    int id,
    DateTime atHcm,
    String title,
    String body,
  ) async => scheduled.add(id);

  @override
  Future<void> cancelScheduled() async {
    cancels++;
    scheduled.clear();
  }
}

class _TrackedPlanner extends PlannerProvider {
  _TrackedPlanner(this.events, NotificationService notifications, this.failAt)
    : super(notifications: notifications, clock: _clock);

  final List<String> events;
  final String? failAt;

  @override
  Future<void> load() async {
    events.add('planner.load');
    if (failAt == 'planner.load') throw StateError('Load failed');
    await super.load();
  }

  @override
  Future<void> rescheduleReminders() async {
    if (failAt == 'reschedule') throw StateError('Schedule failed');
    await super.rescheduleReminders();
  }

  @override
  Future<void> flush() async {
    events.add('planner.flush');
    await super.flush();
    if (failAt == 'flush') throw StateError('Flush failed');
    events.add('planner.flushed');
  }

  @override
  void dispose() {
    events.add('planner.dispose');
    super.dispose();
  }
}

class _TrackedLocations extends LocationProvider {
  _TrackedLocations(WeatherRepository api, this.events, this.failAt)
    : super(apiService: api, clock: _clock);

  final List<String> events;
  final String? failAt;

  @override
  Future<void> loadLocal() async {
    events.add('locations.load');
    if (failAt == 'locations.load') throw StateError('Load failed');
    await super.loadLocal();
  }

  @override
  void dispose() {
    events.add('locations.dispose');
    super.dispose();
  }
}

Future<bool> _runTracked(
  ApiService api,
  _Notifications notifications,
  List<String> events, {
  String? failAt,
}) => runBackgroundCheckTask(
  api: api,
  notifications: notifications,
  clock: _clock,
  createPlanner: () => _TrackedPlanner(events, notifications, failAt),
  createLocations: (service) => _TrackedLocations(service, events, failAt),
);

Future<void> _savePlaces(List<SavedPlace> places) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    LocationProvider.savedKey,
    jsonEncode([for (final place in places) place.toJson()]),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Widget pushes are disabled; notifications and HTTP are always fakes.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({
      PlannerProvider.notifyKey: jsonEncode({'system': true}),
    });
  });
  tearDown(() async {
    await ApiConfig.setBaseUrl(null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final kind in ApiErrorKind.values) {
    test('task classifies $kind and disposes both providers', () async {
      final api = _WeatherApi({Place.defaultId: ApiException(kind)});
      final notifications = _Notifications();
      final events = <String>[];
      final retry = {
        ApiErrorKind.network,
        ApiErrorKind.timeout,
        ApiErrorKind.server,
      }.contains(kind);

      expect(await _runTracked(api, notifications, events), !retry);
      expect(api.calls, [Place.defaultId]);
      expect(notifications.shown, isEmpty);
      expect(notifications.permissionRequests, 0);
      expect(events, [
        'planner.load',
        'locations.load',
        'planner.flush',
        'planner.flushed',
        'locations.dispose',
        'planner.dispose',
      ]);
    });
  }

  for (final error in [
    TimeoutException('Timed out'),
    http.ClientException('Connection unavailable'),
  ]) {
    test('HTTP ${error.runtimeType} reaches the retry result', () async {
      final client = MockClient((_) async => throw error);
      addTearDown(client.close);
      expect(
        await runBackgroundCheckTask(
          api: ApiService(client: client),
          notifications: _Notifications(),
          clock: _clock,
        ),
        isFalse,
      );
    });
  }

  for (final response in [
    (503, '{}', false),
    (408, '{}', false),
    (429, '{}', false),
    (401, '{}', true),
    (403, '{}', true),
    (400, '{}', true),
    (422, '{}', true),
    (404, '{}', true),
    (200, 'invalid JSON', true),
    (200, '{}', true),
  ]) {
    test('HTTP ${response.$1} / ${response.$2}: task completion', () async {
      final client = MockClient(
        (_) async => http.Response(response.$2, response.$1),
      );
      addTearDown(client.close);
      expect(
        await runBackgroundCheckTask(
          api: ApiService(client: client),
          notifications: _Notifications(),
          clock: _clock,
        ),
        response.$3,
      );
    });
  }

  test('partial success persists alerts without retry duplicates', () async {
    await _savePlaces(const [
      SavedPlace(locationId: 'offline'),
      SavedPlace(locationId: 'good', label: PlaceLabel.work),
      SavedPlace(locationId: 'missing'),
      SavedPlace(locationId: 'later'),
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LocationProvider.gpsKey, 'offline');
    await prefs.setString(
      PlannerProvider.commuteKey,
      jsonEncode(const CommuteSettings(briefEnabled: true).toJson()),
    );
    await prefs.setString(
      PlannerProvider.activityKey,
      jsonEncode({
        'routines': [
          const ActivityRoutine(
            id: 'test-routine',
            activity: Activity.running,
            placeId: 'good',
            hour: 7,
          ).toJson(),
        ],
      }),
    );
    final api = _WeatherApi({
      'offline': ApiException(ApiErrorKind.network),
      'good': _weather(),
      'missing': ApiException(ApiErrorKind.notFound),
      'later': _weather(),
    });
    final notifications = _Notifications();
    final events = <String>[];

    expect(await _runTracked(api, notifications, events), isFalse);
    expect(api.calls, ['offline', 'good', 'missing', 'later']);
    final sent = notifications.shown.toSet();
    expect(sent, isNotEmpty);
    final ledger =
        jsonDecode(prefs.getString(PlannerProvider.ledgerKey)!) as List;
    expect(ledger, isNotEmpty);
    expect(prefs.getString(PlannerProvider.historyKey), isNotNull);
    expect(notifications.scheduled, contains(PlannerProvider.morningBriefId));
    expect(
      notifications.scheduled.any((id) => id != PlannerProvider.morningBriefId),
      isTrue,
    );
    expect(
      jsonDecode(prefs.getString(PlannerProvider.commuteKey)!),
      containsPair('workId', 'good'),
    );

    api.responses['offline'] = _weather();
    api.calls.clear();
    expect(await _runTracked(api, notifications, []), isTrue);
    expect(api.calls, ['offline', 'good', 'missing', 'later']);
    expect(notifications.shown.length, greaterThan(sent.length));
    expect(
      notifications.shown.skip(sent.length).toSet().intersection(sent),
      isEmpty,
    );
    expect(notifications.shown.toSet(), hasLength(notifications.shown.length));
    final total = notifications.shown.length;
    expect(await _runTracked(api, notifications, []), isTrue);
    expect(notifications.shown, hasLength(total));
    expect(notifications.permissionRequests, 0);
  });

  test('public check still returns the partial notification count', () async {
    await _savePlaces(const [
      SavedPlace(locationId: 'failed'),
      SavedPlace(locationId: 'good'),
    ]);
    final api = _WeatherApi({
      'failed': ApiException(ApiErrorKind.timeout),
      'good': _weather(),
    });
    final notifications = _Notifications();
    final count = await runBackgroundCheck(
      api: api,
      notifications: notifications,
      clock: _clock,
    );
    expect(count, greaterThan(0));
    expect(notifications.shown, hasLength(count));
    expect(
      await runBackgroundCheck(
        api: api,
        notifications: notifications,
        clock: _clock,
      ),
      0,
    );
    expect(notifications.shown, hasLength(count));
  });

  for (final replay in [false, true]) {
    test('retry respects ${replay ? 'replay' : 'notifications off'}', () async {
      final api = _WeatherApi({
        Place.defaultId: ApiException(ApiErrorKind.network),
      });
      final notifications = _Notifications();
      expect(await _runTracked(api, notifications, []), isFalse);
      final prefs = await SharedPreferences.getInstance();
      if (replay) {
        await prefs.setBool(AppSettingsStore.replayEnabledKey, true);
        await prefs.setString(
          AppSettingsStore.replayAtKey,
          '2026-10-10T12:00:00+07:00',
        );
      } else {
        await prefs.setString(
          PlannerProvider.notifyKey,
          jsonEncode({'system': false}),
        );
      }
      api.calls.clear();
      final events = <String>[];
      expect(await _runTracked(api, notifications, events), isTrue);
      expect(api.calls, isEmpty);
      expect(notifications.inits, 1);
      expect(notifications.permissionRequests, 0);
      expect(
        events,
        replay
            ? isEmpty
            : [
                'planner.load',
                'planner.flush',
                'planner.flushed',
                'planner.dispose',
              ],
      );
    });
  }

  test('empty hourly data is not retried or turned into an alert', () async {
    final notifications = _Notifications();
    expect(
      await _runTracked(
        _WeatherApi({Place.defaultId: _weather(empty: true)}),
        notifications,
        [],
      ),
      isTrue,
    );
    expect(notifications.shown, isEmpty);
  });

  for (final quiet in [false, true]) {
    test('retry preserves alert settings (quiet: $quiet)', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PlannerProvider.alertSettingsKey,
        jsonEncode(
          AlertSettings(
            quietEnabled: quiet,
            quietStart: 0,
            quietEnd: 23,
            enabled: {for (final type in AlertType.values) type: quiet},
          ).toJson(),
        ),
      );
      await _savePlaces(const [
        SavedPlace(locationId: 'failed'),
        SavedPlace(locationId: 'good'),
      ]);
      final notifications = _Notifications();
      expect(
        await _runTracked(
          _WeatherApi({
            'failed': ApiException(ApiErrorKind.server),
            'good': _weather(),
          }),
          notifications,
          [],
        ),
        isFalse,
      );
      expect(notifications.shown, isEmpty);
    });
  }

  for (final failAt in [
    'planner.load',
    'locations.load',
    'reschedule',
    'flush',
  ]) {
    test('$failAt failure still disposes all created providers', () async {
      final events = <String>[];
      expect(
        await _runTracked(
          _WeatherApi({Place.defaultId: _weather()}),
          _Notifications(),
          events,
          failAt: failAt,
        ),
        isTrue,
      );
      expect(events.where((event) => event == 'planner.dispose'), hasLength(1));
      expect(events, contains('planner.flush'));
      expect(events.last, 'planner.dispose');
      expect(
        events.where((event) => event == 'locations.dispose'),
        hasLength(failAt == 'planner.load' ? 0 : 1),
      );
    });
  }

  for (final failAt in ['reschedule', 'flush']) {
    test('$failAt failure cannot hide a pending fetch retry', () async {
      final events = <String>[];
      expect(
        await _runTracked(
          _WeatherApi({Place.defaultId: ApiException(ApiErrorKind.timeout)}),
          _Notifications(),
          events,
          failAt: failAt,
        ),
        isFalse,
      );
      expect(events.last, 'planner.dispose');
      expect(events, contains('locations.dispose'));
    });
  }

  test('notification init failure disposes the loaded planner', () async {
    final events = <String>[];
    final api = _WeatherApi({Place.defaultId: _weather()});
    final notifications = _Notifications()
      ..initError = StateError('Init failed');
    expect(await _runTracked(api, notifications, events), isTrue);
    expect(api.calls, isEmpty);
    expect(events, [
      'planner.load',
      'planner.flush',
      'planner.flushed',
      'planner.dispose',
    ]);
  });

  test('task waits for pending notifications before disposing', () async {
    final gate = Completer<void>();
    final notifications = _Notifications()..showGate = gate;
    final events = <String>[];
    var complete = false;
    final task =
        _runTracked(
          _WeatherApi({Place.defaultId: _weather()}),
          notifications,
          events,
        ).then((result) {
          complete = true;
          return result;
        });
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await task;
    });
    await notifications.showStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(complete, isFalse);
    expect(events, contains('planner.flush'));
    expect(events, isNot(contains('planner.dispose')));
    expect(events, isNot(contains('locations.dispose')));

    gate.complete();
    expect(await task, isTrue);
    expect(notifications.shown, isNotEmpty);
    expect(events.sublist(events.length - 3), [
      'planner.flushed',
      'locations.dispose',
      'planner.dispose',
    ]);
  });

  test('unexpected failures do not retry or log exception payloads', () async {
    final messages = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
    addTearDown(() => debugPrint = previousPrint);
    expect(
      await _runTracked(
        _WeatherApi({Place.defaultId: StateError('private-response-payload')}),
        _Notifications(),
        [],
      ),
      isTrue,
    );
    expect(messages, isNotEmpty);
    expect(messages.join('\n'), isNot(contains('private-response-payload')));
  });
}
