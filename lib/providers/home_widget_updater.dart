import '../models/units.dart';
import '../models/weather.dart';
import '../services/home_widget_service.dart';
import 'location_provider.dart';
import 'weather_provider.dart';

/// Nghe [WeatherProvider]: khi du lieu TRUC TIEP (khong cache, khong xem lai)
/// cua trang dau tien tai xong thi day len widget.
class HomeWidgetUpdater {
  /// [units]: don vi nguoi dung (°C/°F), doc moi lan day.
  HomeWidgetUpdater(
    this._wp,
    this._lp, {
    this._push = pushHomeWidget,
    UnitPrefs Function()? units,
  }) : _units = units ?? (() => const UnitPrefs()) {
    _wp.addListener(_onChanged);
  }

  final WeatherProvider _wp;
  final LocationProvider _lp;
  final Future<void> Function(HomeWidgetData) _push;
  final UnitPrefs Function() _units;
  WeatherData? _lastData;
  HomeWidgetData? _last;

  void _onChanged() {
    final data = _wp.weatherData;
    if (data == null || _wp.isReplay || _wp.isFromCache) return;
    if (identical(data, _lastData)) return;
    final first = _lp.pages.first.locationId;
    if (_wp.locationId != first) return;
    _lastData = data;
    final d = HomeWidgetData.from(
      placeName: _lp.placeById(first).name,
      data: data,
      nowHcm: _wp.nowHcm,
      formatTempValue: _units().tempNumber,
    );
    if (d == _last) return;
    _last = d;
    _push(d);
  }

  void dispose() => _wp.removeListener(_onChanged);
}
