import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../models/app_settings.dart';
import '../models/place.dart';
import '../models/weather.dart';
import '../services/api_service.dart';

class WeatherProvider extends ChangeNotifier {
  final ApiService _apiService;
  final DateTime Function() _clock;

  /// [initialSettings]: doc truoc runApp (xem main.dart). Neu null,
  /// [initialize] se tu doc SharedPreferences.
  /// [clock]: thoi diem that hien tai (thay duoc khi test).
  WeatherProvider({
    ApiService? apiService,
    AppSettings? initialSettings,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _apiService = apiService ?? ApiService(clock: clock),
       _settingsLoaded = initialSettings != null,
       _themeMode = initialSettings?.themeMode ?? ThemeMode.system,
       _isCelsius = initialSettings?.isCelsius ?? true,
       _replayEnabled = initialSettings?.replayEnabled ?? false,
       _replayAt = initialSettings?.replayAt;

  /// Moc som nhat backend chap nhan (gio TP.HCM; backend: >= 2017-01-03
  /// 07:00+07:00).
  static final DateTime replayMin = DateTime.utc(2017, 1, 3, 7);

  /// Moc mau: dot mua lon 07/10/2026 12:00.
  static final DateTime replayPreset = DateTime.utc(2026, 10, 7, 12);

  // State
  WeatherData? _weatherData;
  bool _isLoading = false;
  String? _error;
  ApiErrorKind? _errorKind;
  bool _settingsLoaded;
  ThemeMode _themeMode;
  bool _isCelsius;
  bool _isFromCache = false;
  DateTime? _cachedAt;
  bool _replayEnabled;
  DateTime? _replayAt;
  String? _notice;

  /// Dia diem dang xem (`location_id`).
  String _locationId = Place.defaultId;

  /// Du lieu da tai cua cac dia diem khac (doi trang hien ngay, roi tai lai).
  final Map<String, _Snapshot> _snapshots = {};

  /// Tang moi lan tai; ket qua cua lan tai cu hon bi bo qua (vd. vua bat/tat
  /// che do xem lai khi request truoc chua xong).
  int _requestId = 0;

  // Getters
  WeatherData? get weatherData => _weatherData;

  /// Id dia diem dang xem.
  String get locationId => _locationId;

  /// Doi dia diem dang xem: hien du lieu da co cua diem do (neu co) roi tai
  /// lai. Ket qua dang tai cua diem cu bi bo qua.
  void setLocation(String id, {bool fetch = true}) {
    if (id == _locationId) return;
    if (_weatherData != null) {
      _snapshots[_locationId] = _Snapshot(
        _weatherData!,
        _isFromCache,
        _cachedAt,
      );
    }
    _locationId = id;
    final s = _snapshots[id];
    _weatherData = s?.data;
    _isFromCache = s?.fromCache ?? false;
    _cachedAt = s?.cachedAt;
    _error = null;
    _errorKind = null;
    _requestId++;
    _isLoading = false;
    notifyListeners();
    if (fetch) fetchWeatherData();
  }

  /// Du lieu cua dia diem [id] (so sanh): mang truoc; loi -> du lieu da tai
  /// hoac cache (chi che do truc tiep). Nem ApiException neu khong co gi.
  Future<WeatherResult> fetchWeatherFor(String id) async {
    final at = isReplay ? _replayAt : null;
    try {
      return WeatherResult(
        await _apiService.fetchWeatherDataFor(id, at: at),
        fromCache: false,
      );
    } on ApiException {
      if (id == _locationId && _weatherData != null) {
        return WeatherResult(
          _weatherData!,
          fromCache: _isFromCache,
          savedAt: _cachedAt,
        );
      }
      final s = _snapshots[id];
      if (s != null) {
        return WeatherResult(
          s.data,
          fromCache: s.fromCache,
          savedAt: s.cachedAt,
        );
      }
      if (at == null) {
        final cached = await _apiService.loadCachedResultFor(id);
        if (cached != null) return cached;
      }
      rethrow;
    }
  }

  bool get isLoading => _isLoading;

  /// Thong bao loi tieng Viet de hien thi (null = khong loi).
  String? get error => _error;

  /// Loai loi lan tai gan nhat (null = khong loi).
  ApiErrorKind? get errorKind => _errorKind;
  ThemeMode get themeMode => _themeMode;
  bool get isCelsius => _isCelsius;

  /// Dang hien thi du lieu cache offline.
  bool get isFromCache => _isFromCache;

  /// Thoi diem luu cache dang hien thi (gio TP.HCM); null neu du lieu tu mang.
  DateTime? get cachedAt => _cachedAt;

  /// Giao dien toi dang ap dung (che do "Theo hệ thống" dua vao do sang
  /// cua he dieu hanh).
  bool get isDarkMode {
    switch (_themeMode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return PlatformDispatcher.instance.platformBrightness ==
            Brightness.dark;
    }
  }

  /// Gio TP.HCM "hien tai" cua app (cung quy uoc voi cac DateTime trong
  /// model). Che do xem lai: chinh la thoi diem xem lai.
  DateTime get nowHcm => isReplay ? _replayAt! : realNowHcm;

  /// Gio TP.HCM that (bo qua che do xem lai).
  DateTime get realNowHcm => HcmTime.now(_clock);

  /// Che do xem lai dang bat.
  bool get isReplay => _replayEnabled && _replayAt != null;

  /// Thoi diem xem lai da chon (ke ca khi dang tat); gio TP.HCM.
  DateTime? get replayAt => _replayAt;

  /// Thong bao mot lan (vd. may chu chua ho tro xem lai); null = khong co.
  String? get notice => _notice;

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Lam tron xuong dau gio va gioi han trong [replayMin, gio hien tai].
  DateTime clampReplay(DateTime at) {
    final t = HcmTime.startOfHour(at);
    final max = HcmTime.startOfHour(realNowHcm);
    if (t.isBefore(replayMin)) return replayMin;
    if (t.isAfter(max)) return max;
    return t;
  }

  // Convenience getters
  CurrentWeather? get currentWeather => _weatherData?.current;
  List<HourlyForecast> get hourlyForecast => _weatherData?.hourlyForecast ?? [];
  List<DailyForecast> get dailyForecast => _weatherData?.dailyForecast ?? [];
  AIForecast? get aiForecast => _weatherData?.aiForecast;

  /// Muc 7 ngay ung voi ngay "hien tai" cua app ([nowHcm]); null neu khong co.
  DailyForecast? get todayForecast {
    final today = HcmTime.startOfDay(nowHcm);
    for (final d in dailyForecast) {
      if (HcmTime.startOfDay(d.date) == today) return d;
    }
    return null;
  }

  // Initialize provider
  Future<void> initialize() async {
    if (!_settingsLoaded) {
      final settings = await AppSettings.load();
      _themeMode = settings.themeMode;
      _isCelsius = settings.isCelsius;
      _replayEnabled = settings.replayEnabled;
      _replayAt = settings.replayAt;
      _settingsLoaded = true;
      notifyListeners();
    }
    await fetchWeatherData();
  }

  Future<void> _savePreferences() => AppSettings(
    themeMode: _themeMode,
    isCelsius: _isCelsius,
    replayEnabled: _replayEnabled,
    replayAt: _replayAt,
  ).save();

  // --- Che do xem lai ---

  /// Bat che do xem lai tai [at] (lam tron dau gio, gioi han hop le) va tai
  /// lai du lieu. Du lieu truc tiep dang hien bi bo de khong tron hai nguon.
  Future<void> startReplay(DateTime at) async {
    _replayAt = clampReplay(at);
    _replayEnabled = true;
    _notice = null;
    _resetData();
    _savePreferences();
    await fetchWeatherData();
  }

  /// Tat che do xem lai, quay ve du lieu truc tiep ngay.
  Future<void> exitReplay() async {
    if (!_replayEnabled) return;
    _replayEnabled = false;
    _resetData();
    _savePreferences();
    await fetchWeatherData();
  }

  /// Cong tac trong Cai dat: bat lai thoi diem cu (hoac moc mau).
  Future<void> setReplayEnabled(bool enabled) =>
      enabled ? startReplay(_replayAt ?? replayPreset) : exitReplay();

  void _resetData() {
    _snapshots.clear();
    _weatherData = null;
    _isFromCache = false;
    _cachedAt = null;
    _error = null;
    _errorKind = null;
  }

  /// Backend cu bo qua `at` va tra du lieu hien tai: phat hien qua moc
  /// "hien tai" lech xa thoi diem xem lai.
  static bool _honorsReplay(WeatherData data, DateTime at) =>
      data.current.lastUpdated.difference(at).abs() <= ApiConfig.staleThreshold;

  /// May chu khong ho tro xem lai: tat che do, bao than thien, ve du lieu
  /// truc tiep.
  Future<void> _replayUnsupported() async {
    _replayEnabled = false;
    _resetData();
    _savePreferences();
    _notice =
        'Máy chủ chưa hỗ trợ xem lại thời điểm này. '
        'Đã quay về dữ liệu hiện tại.';
    await fetchWeatherData();
  }

  /// GET /weather/ai-verify cho thoi diem "hien tai" cua app (xem lai: dung
  /// thoi diem xem lai). Nem ApiException.
  Future<AIVerification> fetchAIVerification() => _apiService
      .fetchAIVerificationFor(_locationId, at: isReplay ? _replayAt : null);

  /// Tai du lieu: mang truoc; loi thi giu du lieu dang co, neu chua co gi
  /// thi dung cache (chi o che do truc tiep). Dung chung cho lan dau va
  /// keo-de-lam-moi. Che do xem lai: moi request gui `at`, khong ghi cache.
  Future<void> fetchWeatherData() async {
    final token = ++_requestId;
    final at = isReplay ? _replayAt : null;
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _apiService.fetchWeatherDataFor(_locationId, at: at);
      if (token != _requestId) return;
      if (at != null && !_honorsReplay(data, at)) {
        debugPrint('WeatherProvider: backend ignored at=$at');
        await _replayUnsupported();
        return;
      }
      _weatherData = data;
      _isFromCache = false;
      _cachedAt = null;
      _error = null;
      _errorKind = null;
    } catch (error) {
      if (token != _requestId) return;
      if (error is! ApiException) {
        debugPrint('WeatherProvider: unexpected error: $error');
      }
      final e = error is ApiException
          ? error
          : ApiException(ApiErrorKind.invalidData);
      if (at != null && e.kind == ApiErrorKind.badRequest) {
        await _replayUnsupported();
        return;
      }
      _errorKind = e.kind;
      if (at != null) {
        // Xem lai: khong dung cache (cache la du lieu truc tiep)
      } else if (_weatherData == null) {
        final cached = await _apiService.loadCachedResultFor(_locationId);
        if (cached != null) {
          _weatherData = cached.data;
          _isFromCache = true;
          _cachedAt = cached.savedAt;
        }
      } else if (_isFromCache) {
        // Cache dang hien thi co the da qua them vai gio
        _weatherData = _weatherData!.withoutPastItems(nowHcm);
      }
      _error = _weatherData == null
          ? '${e.message} Vui lòng thử lại.'
          : at != null
          ? '${e.message} Đang hiển thị dữ liệu xem lại đã tải trước đó.'
          : '${e.message} Đang hiển thị dữ liệu đã lưu.';
    } finally {
      if (token == _requestId) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Giu ten cu cho UI; cung mot duong xu ly voi [fetchWeatherData].
  Future<void> refreshWeatherData() => fetchWeatherData();

  /// Du lieu "hien tai" cu hon ApiConfig.staleThreshold, hoac dang dung cache.
  /// So sanh theo gio TP.HCM nen khong phu thuoc mui gio thiet bi.
  bool get isStale {
    final current = currentWeather;
    if (current == null) return false;
    if (_isFromCache) return true;
    return nowHcm.difference(current.lastUpdated) > ApiConfig.staleThreshold;
  }

  /// Chon che do giao dien: sang / toi / theo he thong.
  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _savePreferences();
    notifyListeners();
  }

  // Toggle dark mode (chuyen sang che do co dinh nguoc voi hien tai)
  void toggleDarkMode() =>
      setThemeMode(isDarkMode ? ThemeMode.light : ThemeMode.dark);

  // Set dark mode explicitly
  void setDarkMode(bool value) =>
      setThemeMode(value ? ThemeMode.dark : ThemeMode.light);

  // Toggle temperature unit
  void toggleTemperatureUnit() {
    _isCelsius = !_isCelsius;
    _savePreferences();
    notifyListeners();
  }

  // Set temperature unit explicitly
  void setTemperatureUnit(bool celsius) {
    _isCelsius = celsius;
    _savePreferences();
    notifyListeners();
  }

  // Format temperature with unit
  String formatTemperature(double celsius) {
    final temp = _isCelsius ? celsius : (celsius * 9 / 5) + 32;
    final unit = _isCelsius ? '°C' : '°F';
    return '${temp.round()}$unit';
  }

  // Format temperature value only
  String formatTempValue(double celsius) {
    final temp = _isCelsius ? celsius : (celsius * 9 / 5) + 32;
    return '${temp.round()}';
  }

  // Get temperature unit symbol
  String get tempUnit => _isCelsius ? '°C' : '°F';
}

/// Du lieu da tai cua mot dia diem.
class _Snapshot {
  const _Snapshot(this.data, this.fromCache, this.cachedAt);

  final WeatherData data;
  final bool fromCache;
  final DateTime? cachedAt;
}
