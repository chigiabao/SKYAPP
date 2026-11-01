// Hoi quy cho cac sua loi cham diem (giai doan 1): ghi nguon trung thuc,
// trang thai "AI chưa sẵn sàng", ten/toa do dia diem dang xem, moc xem lai
// mau, chinh sach focus an toan va vung cham >= 48 px tren web/desktop.
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/share_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/sun_times.dart';
import 'package:sky_weather_app/ui/weather/widgets/hourly_strip.dart';
import 'package:sky_weather_app/utils/safe_focus_policy.dart';
import 'package:sky_weather_app/utils/theme.dart';
import 'package:sky_weather_app/widgets/ai_unavailable_card.dart';
import 'package:sky_weather_app/widgets/source_badge.dart';

final _now = DateTime.utc(2026, 10, 31, 6); // gio TP.HCM (sau moc mau)

const _vungTau = Place(
  id: 'vung-tau',
  name: 'Phường Vũng Tàu',
  kind: PlaceKind.phuong,
  lat: 10.35,
  lon: 107.08,
);

WeatherData _data({String? aiError, String? forecastError, DateTime? at}) =>
    WeatherData(
      current: CurrentWeather(
        temperature: 27,
        condition: WeatherCondition.cloudy,
        lastUpdated: at ?? _now,
      ),
      hourlyForecast: [
        for (var i = 0; i < 3; i++)
          HourlyForecast(
            time: (at ?? _now).add(Duration(hours: i)),
            temperature: 27,
            condition: WeatherCondition.cloudy,
            rainProbability: 0.5,
          ),
      ],
      dailyForecast: const [],
      aiError: aiError,
      forecastError: forecastError,
    );

class _Api extends ApiService {
  _Api(this.data);
  final WeatherData data;
  final requested = <DateTime?>[];

  @override
  Future<WeatherData> fetchWeatherDataFor(
    String locationId, {
    DateTime? at,
  }) async {
    requested.add(at);
    // Xem lai: tra du lieu dung thoi diem (backend ho tro `at`).
    return at == null ? data : _data(at: at);
  }
}

Map<String, dynamic> _bundle() => {
  'location_id': 'tsn',
  'current': {
    'timestamp': '2026-10-31T06:00:00+07:00',
    'temperature': 27.0,
    'weather_code': 3,
  },
  'hourly': const [],
  'daily': const [],
  'forecast_error': null,
  'ai_forecast': null,
  'ai_error': 'Chưa có dữ liệu đầu vào trong 3 giờ gần nhất để chạy AI riêng.',
};

Future<WeatherProvider> _provider(WeatherData data) async {
  final wp = WeatherProvider(
    apiService: _Api(data),
    clock: () => HcmTime.toInstant(_now),
  );
  await wp.fetchWeatherData();
  return wp;
}

Future<void> _pump(WidgetTester tester, WeatherProvider wp, Widget child) =>
    tester.pumpWidget(
      ChangeNotifierProvider<WeatherProvider>.value(
        value: wp,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: AppSceneScope(child: c!),
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Ghi nguon: du bao = AI cua nhom, Open-Meteo chi la dau vao', () {
    test('khong ghi cong du bao cho Open-Meteo', () {
      expect(kShareSignature, contains('AI của nhóm'));
      expect(kShareSignature, isNot(contains('Open-Meteo')));
      for (final s in [DataSource.forecast, DataSource.ai]) {
        expect(s.label, isNot(contains('Open-Meteo')));
        expect(s.note, isNot(contains('Open-Meteo')));
        expect(SourceLegend.short(s), isNot(contains('Open-Meteo')));
        expect(SourceLegend.explain(s), isNot(contains('Open-Meteo')));
      }
      // Du lieu "Thuc te" duoc ghi ro la dau vao, khong phai du bao.
      expect(DataSource.observed.note, contains('đã ghi nhận'));
      expect(DataSource.observed.note, contains('không phải số đo'));
      expect(DataSource.observed.note, contains('giờ đã qua'));
    });

    test('van ban chia se co ten dia diem that va chu ky AI', () {
      final text = weatherShareText(
        placeName: _vungTau.name,
        at: _now,
        tempText: '27°',
        condition: 'Nhiều mây',
      );
      expect(text, startsWith('Phường Vũng Tàu, '));
      expect(text, isNot(contains('TP. Hồ Chí Minh')));
      expect(text, endsWith('(dự báo AI của nhóm)'));
    });
  });

  group('AI chưa sẵn sàng', () {
    test('doc ai_error tu /weather/bundle va giu khi bo gio da qua', () async {
      final api = ApiService(
        client: MockClient(
          (req) async => req.url.path == '/weather/bundle'
              ? http.Response.bytes(utf8.encode(jsonEncode(_bundle())), 200)
              : http.Response('{}', 404),
        ),
        baseUrl: 'http://test',
        clock: () => HcmTime.toInstant(_now),
      );
      final data = await api.fetchWeatherData();
      expect(data.aiForecast, isNull);
      expect(data.aiError, contains('dữ liệu đầu vào'));
      expect(data.withoutPastItems(_now).aiError, data.aiError);
    });

    test('chi tiet backend -> cau giai thich co dinh', () {
      expect(
        aiUnavailableCause('Chưa có dữ liệu đầu vào trong 3 giờ gần nhất'),
        AIUnavailableCause.noInput,
      );
      expect(
        // Nguyen van backend/routers/weather_series.py (ca hai ve).
        aiUnavailableCause(
          'Dự báo AI chưa phủ đủ khoảng thời gian yêu cầu; '
          'cần dữ liệu đầu vào mới và model đã huấn luyện đúng phạm vi.',
        ),
        AIUnavailableCause.notCovered,
      );
      expect(
        aiUnavailableCause("Dự báo AI riêng chưa sẵn sàng: KeyError('x')"),
        AIUnavailableCause.model,
      );
      expect(
        aiUnavailableMessage("KeyError('x')"),
        isNot(contains('KeyError')),
      );
    });

    testWidgets('the giai thich ly do, co thu lai / moc mau / kiem chung', (
      tester,
    ) async {
      final wp = await _provider(
        _data(aiError: 'Chưa có dữ liệu đầu vào trong 3 giờ gần nhất.'),
      );
      addTearDown(wp.dispose);
      await _pump(
        tester,
        wp,
        AIUnavailableCard(
          detail: wp.weatherData!.aiError,
          shortRange: true,
          onVerify: () {},
        ),
      );
      await tester.pump();
      expect(find.text('AI 1–6 GIỜ CHƯA SẴN SÀNG'), findsOneWidget);
      expect(find.text('Chờ dữ liệu đầu vào mới để chạy AI.'), findsOneWidget);
      expect(find.text('Kiểm chứng AI'), findsNothing);
      expect(find.text('Xem mốc mẫu đã lưu'), findsNothing);
      await tester.tap(find.text('Chi tiết dữ liệu'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('chưa có dữ liệu đầu vào mới'),
        findsOneWidget,
      );
      expect(find.textContaining('không thay bằng số'), findsOneWidget);
      expect(find.textContaining('Dữ liệu đầu vào mới nhất:'), findsOneWidget);
      expect(find.textContaining('Nguồn đầu vào:'), findsOneWidget);
      for (final label in ['Thử lại', 'Xem mốc mẫu đã lưu', 'Kiểm chứng AI']) {
        final size = tester.getSize(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          ),
        );
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
      }
      await tester.ensureVisible(find.text('Xem mốc mẫu đã lưu'));
      await tester.tap(find.text('Xem mốc mẫu đã lưu'));
      await tester.pump();
      expect(wp.isReplay, isTrue);
      expect(wp.replayAt, WeatherProvider.replayPreset);
      // Dang xem lai -> khong con goi y bat xem lai.
      expect(find.text('Xem mốc mẫu đã lưu'), findsNothing);
    });

    test('moc mau 21/10/2026 21:00 co ban du bao AI da luu', () {
      expect(WeatherProvider.replayPreset, DateTime.utc(2026, 10, 21, 21));
      expect(
        WeatherProvider.replayPresetLabel,
        contains('Thứ 4, 21/10 · 21:00'),
      );
      expect(WeatherProvider.replayPresetLabel, contains('dự báo AI đã lưu'));
    });
  });

  group('Dia diem dang xem', () {
    test('ten va toa do that thay cho diem mac dinh', () async {
      final wp = await _provider(_data());
      addTearDown(wp.dispose);
      expect(wp.place.id, Place.defaultId);
      wp.placeFor = (id) => id == _vungTau.id ? _vungTau : null;
      wp.setLocation(_vungTau.id);
      expect(wp.place.name, 'Phường Vũng Tàu');
      expect(wp.place.lat, _vungTau.lat);
      // Chua biet dia diem -> ten chung, khong gan "TP. Hồ Chí Minh".
      wp.setLocation('unknown');
      expect(wp.place.name, isNot('TP. Hồ Chí Minh'));
    });

    test('gio mat troi theo toa do dia diem', () {
      final day = DateTime.utc(2026, 10, 21);
      final west = SunTimes.forDate(day, lat: 10.8, lon: 105.0);
      final east = SunTimes.forDate(day, lat: 10.8, lon: 107.5);
      // Dong hon ~2,5 do kinh -> mat troi moc som hon ~10 phut.
      expect(
        west.sunrise.difference(east.sunrise).inMinutes,
        inInclusiveRange(8, 12),
      );
      final hours = [
        for (var i = 0; i < 24; i++)
          HourlyForecast(
            time: day.add(Duration(hours: i)),
            temperature: 27,
            condition: WeatherCondition.cloudy,
          ),
      ];
      SunEntry sunrise(double lon) => buildHourlyTimeline(
        hours,
        nowHcm: day,
        lat: 10.8,
        lon: lon,
      ).whereType<SunEntry>().first;
      expect(sunrise(105.0).time.isAfter(sunrise(107.5).time), isTrue);
    });
  });

  group('Focus va vung cham', () {
    testWidgets(
      'cua so nhan focus truoc layout dau tien khong nem loi (banner xem lai)',
      (tester) async {
        // Nut ngoai Navigator (nhu "Thoát" cua banner xem lai) + route.
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => FocusTraversalGroup(
              policy: SafeReadingOrderTraversalPolicy(),
              child: Column(
                children: [
                  TextButton(onPressed: () {}, child: const Text('Thoát')),
                  Expanded(child: child!),
                ],
              ),
            ),
            home: Scaffold(
              body: TextButton(onPressed: () {}, child: const Text('x')),
            ),
          ),
          phase: EnginePhase.build,
        );
        tester.binding.handleViewFocusChanged(
          ViewFocusEvent(
            viewId: tester.view.viewId,
            state: ViewFocusState.focused,
            direction: ViewFocusDirection.forward,
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pump();
      },
    );

    testWidgets('theme giu nut >= 48 px ca tren desktop/web', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            appBar: AppBar(
              actions: [
                IconButton(
                  tooltip: 'Tải lại',
                  onPressed: () {},
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            body: TextButton(onPressed: () {}, child: const Text('Bỏ qua')),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(48),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
