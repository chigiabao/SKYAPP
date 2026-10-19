import 'package:flutter_test/flutter_test.dart';

import 'package:sky_weather_app/models/place.dart';
import 'package:sky_weather_app/models/units.dart';
import 'package:sky_weather_app/models/weather.dart';
import 'package:sky_weather_app/screens/compare_screen.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/services/api_service.dart';
import 'package:sky_weather_app/services/route_service.dart';

// Du lieu gia CHI dung trong test.

final DateTime _now = DateTime.utc(2026, 10, 18, 14, 10);

MapCell _cell(String id, double t) => MapCell(
  cellId: id,
  lat: 10.77,
  lon: 106.7,
  locationIds: const [],
  temperature: t,
);

CompareSeries _series(String id, String name, {int? rainFromHour}) {
  final start = DateTime.utc(2026, 10, 18, 14);
  return CompareSeries(
    place: Place(
      id: id,
      name: name,
      kind: PlaceKind.phuong,
      lat: 10.7,
      lon: 106.7,
    ),
    label: null,
    style: CompareSeriesStyle.all.first,
    error: null,
    result: WeatherResult(
      WeatherData(
        current: CurrentWeather(
          locationName: name,
          temperature: id == 'a' ? 33 : 31,
          condition: WeatherCondition.cloudy,
          lastUpdated: _now,
        ),
        hourlyForecast: [
          for (var i = 0; i < 12; i++)
            HourlyForecast(
              time: start.add(Duration(hours: i)),
              temperature: 30,
              condition: WeatherCondition.cloudy,
              rainProbability: rainFromHour != null && i >= rainFromHour
                  ? 0.8
                  : 0.1,
            ),
        ],
        dailyForecast: const [],
      ),
      fromCache: false,
    ),
  );
}

void main() {
  group('Ban do: thang nhiet tuong doi', () {
    test('min -> mau mat nhat, max -> nong nhat, nhan la gia tri that', () {
      final cells = [_cell('a', 29.2), _cell('b', 31.8), _cell('c', 30.5)];
      final r = MapScale.tempRange(cells)!;
      expect(r, (29.2, 31.8));
      expect(MapScale.forTempIn(29.2, r.$1, r.$2), MapScale.tempColors.first);
      expect(MapScale.forTempIn(31.8, r.$1, r.$2), MapScale.tempColors.last);
      final legend = MapScale.legend(
        MapLayerKind.temperature,
        (c) => c.toStringAsFixed(1),
        const UnitPrefs(),
        r,
      );
      expect(legend.first.label, '29.2°');
      expect(legend.last.label, '31.8°');
      // Cac o khac nhau co mau khac nhau (khong con ca vung mot mau).
      final m = buildCellMarkers(
        cells,
        MapLayerKind.temperature,
        temp: (c) => '$c',
      );
      expect(m.map((x) => x.color).toSet(), hasLength(3));
    });

    test('chenh lech nho khong bi phong dai thanh hai dau thang', () {
      final c = MapScale.forTempIn(30.1, 30.0, 30.2);
      expect(c, isNot(MapScale.tempColors.last));
      expect(c, isNot(MapScale.tempColors.first));
    });
  });

  group('So sanh: noi bat + ket luan', () {
    test('noi mua som hon ~N gio', () {
      final s = [
        _series('a', 'Thủ Đức', rainFromHour: 2),
        _series('b', 'Bến Thành', rainFromHour: 3),
      ];
      expect(
        compareVerdict(s, _now, (c) => '${c.round()}'),
        startsWith('Thủ Đức mưa sớm hơn Bến Thành khoảng 1 giờ'),
      );
      final h = compareHighlights(s, _now);
      expect(h.hottestId, 'a');
    });

    test('khong mua: neu noi nong nhat', () {
      final s = [_series('a', 'Thủ Đức'), _series('b', 'Bến Thành')];
      expect(
        compareVerdict(s, _now, (c) => '${c.round()}'),
        contains('Thủ Đức nóng nhất (33°)'),
      );
      expect(compareHighlights(s, _now).rainiestId, isNull);
    });
  });

  test('nhan phuong tien: Xe may la mac dinh', () {
    expect(TripProfile.values.first, TripProfile.driving);
    expect(TripProfile.driving.label, 'Xe máy');
  });
}
