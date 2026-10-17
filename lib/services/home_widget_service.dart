/// Widget man hinh chinh (nhom 8, package home_widget).
///
/// - Android: `WeatherWidgetProvider` (AppWidgetProvider + XML layout) doc
///   cac khoa [HomeWidgetData.toMap] tu SharedPreferences cua home_widget.
/// - iOS: WidgetKit extension `SkyWeatherWidget` (ios/SkyWeatherWidget) doc
///   cung cac khoa + `sw_updated` tu UserDefaults cua App Group. Ban ky khong
///   co App Group (vd. Apple ID mien phi qua 3uTools) -> bo qua, widget hien
///   placeholder.
/// - Web / desktop: khong lam gi.
///
/// Cap nhat: moi khi app tai xong du lieu truc tiep cua trang dau tien
/// ([HomeWidgetUpdater]) va moi lan tac vu nen workmanager chay.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import 'share_service.dart' show rainNext3h;

/// Ten day du cua AppWidgetProvider (namespace Android cua app).
const String kAndroidWidgetProvider =
    'com.example.sky_weather_app.WeatherWidgetProvider';

/// `kind` cua widget iOS (SkyWeatherWidget.swift).
const String kIosWidgetKind = 'SkyWeatherWidget';

/// AppGroupChannel trong ios/Runner/AppDelegate.swift.
const MethodChannel _appGroupChannel = MethodChannel('sky_weather/app_group');

/// iOS: dat App Group thuc te cho home_widget; false neu khong co App Group.
Future<bool> _iosAppGroupReady() async {
  final id = await _appGroupChannel.invokeMethod<String>('appGroupId');
  if (id == null) return false;
  await HomeWidget.setAppGroupId(id);
  return true;
}

/// Noi dung widget (da dinh dang san).
@immutable
class HomeWidgetData {
  const HomeWidgetData({
    required this.placeName,
    required this.temperature,
    required this.condition,
    this.rainPercent3h,
  });

  final String placeName;
  final String temperature; // "31°"
  final String condition;
  final int? rainPercent3h;

  /// Khoa doc o phia Android (WeatherWidgetProvider.kt).
  Map<String, String> toMap() => {
    'sw_place': placeName,
    'sw_temp': temperature,
    'sw_condition': condition,
    'sw_rain3h': rainPercent3h == null
        ? 'Mưa 3 giờ tới: --'
        : 'Mưa 3 giờ tới: $rainPercent3h%',
  };

  /// Tu du lieu thoi tiet; [formatTempValue] doi °C sang don vi nguoi dung.
  factory HomeWidgetData.from({
    required String placeName,
    required WeatherData data,
    required DateTime nowHcm,
    required String Function(double celsius) formatTempValue,
  }) => HomeWidgetData(
    placeName: placeName,
    temperature: '${formatTempValue(data.current.temperature)}°',
    condition: data.current.condition.description,
    rainPercent3h: rainNext3h(data.hourlyForecast, nowHcm),
  );

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetData && mapEquals(other.toMap(), toMap());

  @override
  int get hashCode => Object.hashAll(toMap().values);
}

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Luu du lieu + yeu cau ve lai widget. Khong bao gio nem loi.
Future<void> pushHomeWidget(HomeWidgetData d) async {
  if (kIsWeb || !(_android || _ios)) return;
  try {
    if (_ios && !await _iosAppGroupReady()) return;
    for (final e in d.toMap().entries) {
      await HomeWidget.saveWidgetData<String>(e.key, e.value);
    }
    if (_ios) {
      await HomeWidget.saveWidgetData<int>(
        'sw_updated',
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      await HomeWidget.updateWidget(iOSName: kIosWidgetKind);
    }
    if (_android) {
      await HomeWidget.updateWidget(
        qualifiedAndroidName: kAndroidWidgetProvider,
      );
    }
  } catch (e) {
    debugPrint('homeWidget: $e');
  }
}

/// Nghe [WeatherProvider]: khi du lieu TRUC TIEP (khong cache, khong xem lai)
/// cua trang dau tien tai xong thi day len widget.
class HomeWidgetUpdater {
  HomeWidgetUpdater(
    this._wp,
    this._lp, {
    this._push = pushHomeWidget,
  }) {
    _wp.addListener(_onChanged);
  }

  final WeatherProvider _wp;
  final LocationProvider _lp;
  final Future<void> Function(HomeWidgetData) _push;
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
      formatTempValue: _wp.formatTempValue,
    );
    if (d == _last) return;
    _last = d;
    _push(d);
  }

  void dispose() => _wp.removeListener(_onChanged);
}
