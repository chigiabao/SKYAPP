import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/config/api_config.dart';
import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';

import 'support/fake_weather_repository.dart';

// Synthetic provider fixtures; no network or real weather cache.
WeatherData _data(DateTime at, [double temperature = 27]) => WeatherData(
  current: CurrentWeather(
    temperature: temperature,
    condition: WeatherCondition.cloudy,
    lastUpdated: at,
  ),
  hourlyForecast: const [],
  dailyForecast: const [],
);

/// Lop gia dung chung; [load] nhan `at` (xem lai).
FakeWeatherRepository _api(Future<WeatherData> Function(DateTime? at) load) =>
    FakeWeatherRepository(onFetch: (_, at) => load(at));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ApiConfig.setBaseUrl(null));

  test(
    'refresh throttles attempts and retries after the freshness window',
    () async {
      var now = DateTime.utc(2026, 10, 21, 12);
      var offline = false;
      final api = _api((_) async {
        if (offline) throw ApiException(ApiErrorKind.network);
        return _data(now);
      });
      final provider = WeatherProvider(
        apiService: api,
        initialSettings: const AppSettings(),
        clock: () => now,
        retryDelays: const [],
      );
      addTearDown(provider.dispose);
      await provider.initialize();
      await provider.refreshIfNeeded();
      expect(api.fetches.length, 1);
      now = now.add(WeatherProvider.freshFor);
      offline = true;
      await provider.refreshIfNeeded();
      expect(api.fetches.length, 2);
      expect(provider.currentWeather, isNotNull);
      await provider.refreshIfNeeded();
      expect(api.fetches.length, 2);
      now = now.add(WeatherProvider.freshFor);
      offline = false;
      await provider.refreshIfNeeded();
      expect(api.fetches.length, 3);
      expect(provider.error, isNull);
    },
  );

  test('automatic refresh never changes replay data to live data', () async {
    final at = DateTime.utc(2026, 10, 19, 12);
    final api = _api((requestedAt) async {
      expect(requestedAt, at);
      return _data(at);
    });
    final provider = WeatherProvider(
      apiService: api,
      initialSettings: AppSettings(replayEnabled: true, replayAt: at),
    );
    addTearDown(provider.dispose);
    await provider.initialize();
    await provider.refreshIfNeeded();
    expect(api.fetches.length, 1);
    expect(provider.isReplay, isTrue);
  });

  test(
    'server change replaces an in-flight load and discards its response',
    () async {
      await ApiConfig.setBaseUrl('https://a.example');
      final at = DateTime.utc(2026, 10, 21, 12);
      final old = Completer<WeatherData>();
      final oldStarted = Completer<void>();
      final freshStarted = Completer<void>();
      final api = _api((_) {
        if (ApiConfig.baseUrl == 'https://a.example') {
          oldStarted.complete();
          return old.future;
        }
        freshStarted.complete();
        return Future.value(_data(at, 31));
      });
      final provider = WeatherProvider(
        apiService: api,
        initialSettings: const AppSettings(),
      );
      addTearDown(provider.dispose);
      provider.attachLifecycle();
      final loading = provider.initialize();
      await oldStarted.future;
      await ApiConfig.setBaseUrl('https://b.example');
      await freshStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(provider.currentWeather?.temperature, 31);
      old.complete(_data(at, 11));
      await loading;
      expect(provider.currentWeather?.temperature, 31);
      expect(api.fetches.length, 2);
      expect(provider.isLoading, isFalse);
    },
  );

  testWidgets('resume refreshes stale data and disposal removes the listener', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 21, 12);
    final api = _api((_) async => _data(now));
    final provider = WeatherProvider(
      apiService: api,
      initialSettings: const AppSettings(),
      clock: () => now,
    );
    provider.attachLifecycle();
    void pause() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }

    void resume() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    try {
      await provider.initialize();
      pause();
      now = now.add(const Duration(hours: 4));
      resume();
      await tester.pump();
      expect(api.fetches.length, 2);
    } finally {
      provider.dispose();
    }
    pause();
    resume();
    await tester.pump();
    expect(api.fetches.length, 2);
  });
}
