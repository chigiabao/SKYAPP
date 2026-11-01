import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/services/api_service.dart';

// tool/run_backend_contract.py starts FastAPI with an isolated synthetic DB.
void main() {
  final base = Platform.environment['CONTRACT_BACKEND'];
  final skip = base == null ? 'Run tool/run_backend_contract.py' : false;
  late ApiService api;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final client = http.Client();
    addTearDown(client.close);
    api = ApiService(baseUrl: base, client: client);
  });

  test('FastAPI bundle parses through the real Flutter service', () async {
    final at = DateTime.utc(2023, 6, 20, 12);
    final data = await api.fetchWeatherData(at: at);
    expect(data.current.lastUpdated, at);
    expect(data.current.temperature, 30.3);
    expect(data.current.source, DataSource.observed);
    expect(data.hourlyForecast, hasLength(48));
    expect(data.hourlyForecast.first.time, at);
    expect(data.hourlyForecast.first.source, DataSource.observed);
    // The fixture ends on June 24; the API must preserve partial coverage.
    expect(data.dailyForecast, hasLength(5));
    expect(data.dailyForecast.last.date, DateTime.utc(2023, 6, 24));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(ApiService.cacheKey), isNull);
  }, skip: skip);

  test('FastAPI validation errors retain status and retry semantics', () async {
    await expectLater(
      api.fetchCurrentRaw(at: DateTime.utc(2016)),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'HTTP status', 400)
            .having((error) => error.kind, 'kind', ApiErrorKind.badRequest)
            .having((error) => error.isTransient, 'retry', isFalse),
      ),
    );
  }, skip: skip);

  test(
    'FastAPI verification preserves archived or unavailable status',
    () async {
      final verification = await api.fetchAIVerification(
        at: DateTime.utc(2023, 6, 20, 12),
      );
      expect(verification.verificationMode, 'unavailable');
      expect(verification.unavailableReason, 'no_archived_forecast');
      expect(verification.horizons, isEmpty);
    },
    skip: skip,
  );
}
