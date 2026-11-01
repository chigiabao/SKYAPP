import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../config/api_config.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import '../providers/preferences_provider.dart';
import '../services/api_service.dart';
import '../services/app_settings_store.dart';
import '../services/home_widget_service.dart';
import '../services/notification_service.dart';

/// Kiem tra dinh ky o nen (workmanager; Android khoang moi gio, iOS do
/// BGAppRefreshTask tu quyet thoi diem - co the vai gio/lan): tai du lieu cac dia diem (vi tri hien tai + da luu),
/// chay luat canh bao, gui thong bao (chong trung + gio yen lang cua
/// [PlannerProvider.record]) va hen lai nhac hoat dong.
///
/// iOS: id nay phai trung BGTaskSchedulerPermittedIdentifiers (Info.plist)
/// va AppDelegate.backgroundTask.
const String kBackgroundTask = 'sky_weather_hourly_check';

/// Android, iOS; web / desktop / test khong co workmanager.
bool get _supported => NotificationService.isSupportedPlatform;

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) => runBackgroundCheckTask());
}

bool _needsRetry(Object error) => error is ApiException && error.isTransient;

/// Workmanager callback body, callable without registering a platform task.
/// false requests Android backoff/retry; iOS still controls its next run.
/// Provider factories transfer ownership to this run (also used by tests).
Future<bool> runBackgroundCheckTask({
  NotificationService? notifications,
  WeatherRepository? api,
  DateTime Function()? clock,
  PlannerProvider Function()? createPlanner,
  LocationProvider Function(WeatherRepository)? createLocations,
}) async {
  try {
    final result = await _runBackgroundCheck(
      notifications: notifications,
      api: api,
      clock: clock,
      createPlanner: createPlanner,
      createLocations: createLocations,
    );
    return !result.retry;
  } catch (e) {
    debugPrint('backgroundCheck: ${e.runtimeType}');
    return !_needsRetry(e);
  }
}

/// Mot lan kiem tra. Tra ve so thong bao moi. Khong lam gi khi thong bao he
/// thong dang tat hoac app dang o che do xem lai.
Future<int> runBackgroundCheck({
  NotificationService? notifications,
  WeatherRepository? api,
  DateTime Function()? clock,
}) async => (await _runBackgroundCheck(
  notifications: notifications,
  api: api,
  clock: clock,
)).sent;

Future<({int sent, bool retry})> _runBackgroundCheck({
  NotificationService? notifications,
  WeatherRepository? api,
  DateTime Function()? clock,
  PlannerProvider Function()? createPlanner,
  LocationProvider Function(WeatherRepository)? createLocations,
}) async {
  // Isolate nen co the song lau: doc lai ban ghi moi nhat cua app.
  try {
    await (await SharedPreferences.getInstance()).reload();
  } catch (e) {
    debugPrint('backgroundCheck reload: ${e.runtimeType}');
  }
  // Background isolates do not run main(), and an existing isolate can retain an old URL.
  await ApiConfig.loadBaseUrl();
  final app = await AppSettingsStore.load();
  if (app.replayEnabled) return (sent: 0, retry: false);
  SharedPreferences? stored;
  try {
    stored = await SharedPreferences.getInstance();
  } catch (_) {}
  final units = PreferencesProvider.unitsFromPrefs(stored);
  final notify = notifications ?? NotificationService.platform();
  final planner =
      createPlanner?.call() ??
      PlannerProvider(notifications: notify, clock: clock);
  LocationProvider? locations;
  WeatherRepository? owned;
  var sent = 0;
  var retry = false;
  try {
    await planner.load();
    if (!planner.notifySettings.system) return (sent: 0, retry: false);
    await notify.init();
    final service = api ?? (owned = ApiService(clock: clock));
    final lp =
        createLocations?.call(service) ??
        LocationProvider(apiService: service, clock: clock);
    locations = lp;
    await lp.loadLocal();
    // Nha / Noi lam cho thong bao buoi sang (noi dung hen lai ben duoi).
    planner.syncCommutePlaces(lp);
    final now = HcmTime.now(clock);
    final firstId = lp.pages.first.locationId;
    for (final id in <String>{for (final p in lp.pages) p.locationId}) {
      try {
        final data = await service.fetchWeatherDataFor(id);
        if (id == firstId) {
          await pushHomeWidget(
            HomeWidgetData.from(
              placeName: lp.placeById(id).name,
              data: data,
              nowHcm: now,
              formatTempValue: units.tempNumber,
            ),
          );
        }
        sent += (await planner.record(
          id,
          lp.placeById(id).name,
          data.hourlyForecast,
          now,
        )).length;
      } catch (e) {
        retry = retry || _needsRetry(e);
        debugPrint('backgroundCheck location: ${e.runtimeType}');
      }
    }
    // Hen lai nhac + thong bao buoi sang voi du lieu vua tai (chay truoc gio
    // gui -> noi dung moi thay noi dung cu cung id).
    try {
      await planner.rescheduleReminders();
    } catch (e) {
      retry = retry || _needsRetry(e);
      debugPrint('backgroundCheck reminders: ${e.runtimeType}');
    }
  } finally {
    // Drain writes/notifications before disposing, including early exits.
    try {
      await planner.flush();
    } catch (e) {
      retry = retry || _needsRetry(e);
      debugPrint('backgroundCheck flush: ${e.runtimeType}');
    } finally {
      try {
        locations?.dispose();
      } finally {
        owned?.close();
        planner.dispose();
      }
    }
  }
  return (sent: sent, retry: retry);
}

/// Dang ky / huy tac vu nen (Android, iOS; noi khac khong lam gi).
Future<void> setBackgroundCheck(bool enabled) async {
  if (!_supported) return;
  final wm = Workmanager();
  await wm.initialize(backgroundDispatcher);
  if (enabled) {
    await wm.registerPeriodicTask(
      kBackgroundTask,
      kBackgroundTask,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } else {
    await wm.cancelByUniqueName(kBackgroundTask);
  }
}
