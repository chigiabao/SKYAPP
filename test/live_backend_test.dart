// Kiem tra voi backend that (mac dinh BO QUA). Chay:
//   LIVE_BACKEND=http://localhost:8000 flutter test test/live_backend_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/services/api_service.dart';

void main() {
  final base = Platform.environment['LIVE_BACKEND'];
  final skip = base == null ? 'Set LIVE_BACKEND to run' : false;

  test('live backend parses current/hourly/daily/ai/health', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiService(baseUrl: base!);
    final data = await api.fetchWeatherData();
    final health = await api.fetchHealth();
    // ignore: avoid_print
    print(
      'current ${data.current.lastUpdated} ${data.current.temperature}°C '
      'src=${data.current.source?.name} gusts=${data.current.windGusts} | '
      'hourly ${data.hourlyForecast.length} first=${data.hourlyForecast.first.time} '
      'src=${SourceSummary.of(data.hourlyForecast.map((h) => h.source)).label} '
      'wind=${data.hourlyForecast.first.windSpeed}/${data.hourlyForecast.first.windGusts} | '
      'daily ${data.dailyForecast.length} '
      'src=${SourceSummary.of(data.dailyForecast.map((d) => d.source)).label} '
      'gustMax=${data.dailyForecast.first.windGusts} | ai ${data.aiForecast?.issuedAt} '
      'target1h=${data.aiForecast?.predictions.first.targetTime} | health ${health.status} '
      'latest=${health.latestTimestamp} age=${health.dataAgeHours}',
    );
    expect(data.hourlyForecast, isNotEmpty);
    expect(data.dailyForecast, isNotEmpty);
    expect(data.aiForecast, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ApiService.cacheKey), isNotNull);
  }, skip: skip);

  test('live replay at=2026-10-07 12:00 + ai-verify', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiService(baseUrl: base!);
    final at = DateTime.utc(2026, 10, 7, 12); // gio TP.HCM
    final data = await api.fetchWeatherData(at: at);
    final verify = await api.fetchAIVerification(at: at);
    // ignore: avoid_print
    print(
      'replay current ${data.current.lastUpdated} src=${data.current.source?.name} | '
      'hourly ${data.hourlyForecast.first.time}.. '
      '${SourceSummary.of(data.hourlyForecast.map((h) => h.source)).label} | '
      'daily ${[for (final d in data.dailyForecast) '${d.date.day}:${d.source?.name}:${d.precipitationMm}'].join(' ')} | '
      'verify ${verify.issuedAt} ${[for (final h in verify.horizons) '${h.horizon} ${h.predictedTemperature}/${h.actualTemperature} rain=${h.actualRain}'].join(', ')}',
    );
    expect(data.current.lastUpdated, at);
    expect(data.hourlyForecast.first.time, at);
    expect(verify.issuedAt, at);
    expect(verify.horizons, isNotEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ApiService.cacheKey), isNull); // khong ghi cache
  }, skip: skip);

  test('live ai-verify (now) tolerates null actuals', () async {
    final api = ApiService(baseUrl: base!);
    final v = await api.fetchAIVerification();
    // ignore: avoid_print
    print(
      'verify now ${v.issuedAt} actuals=${v.horizons.map((h) => h.hasActual).toList()}',
    );
    expect(v.horizons, isNotEmpty);
  }, skip: skip);

  test('live at before 2017-01-03 07:00 -> badRequest', () async {
    final api = ApiService(baseUrl: base!);
    await expectLater(
      api.fetchCurrentRaw(at: DateTime.utc(2016)),
      throwsA(
        isA<ApiException>().having(
          (e) => e.kind,
          'kind',
          ApiErrorKind.badRequest,
        ),
      ),
    );
  }, skip: skip);
}
