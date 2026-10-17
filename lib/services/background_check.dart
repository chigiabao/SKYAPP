import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../models/app_settings.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/planner_provider.dart';
import 'api_service.dart';
import 'notification_service.dart';

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
  Workmanager().executeTask((task, input) async {
    try {
      await runBackgroundCheck();
    } catch (e) {
      debugPrint('backgroundCheck: $e');
    }
    return true;
  });
}

/// Mot lan kiem tra. Tra ve so thong bao moi. Khong lam gi khi thong bao he
/// thong dang tat hoac app dang o che do xem lai.
Future<int> runBackgroundCheck({
  NotificationService? notifications,
  ApiService? api,
  DateTime Function()? clock,
}) async {
  // Isolate nen co the song lau: doc lai ban ghi moi nhat cua app.
  try {
    await (await SharedPreferences.getInstance()).reload();
  } catch (e) {
    debugPrint('backgroundCheck reload: $e');
  }
  final app = await AppSettings.load();
  if (app.replayEnabled) return 0;
  final notify = notifications ?? NotificationService.platform();
  final planner = PlannerProvider(notifications: notify, clock: clock);
  await planner.load();
  if (!planner.notifySettings.system) return 0;
  await notify.init();
  final service = api ?? ApiService(clock: clock);
  final lp = LocationProvider(apiService: service, clock: clock);
  await lp.loadLocal();
  final now = HcmTime.now(clock);
  var sent = 0;
  for (final id in <String>{for (final p in lp.pages) p.locationId}) {
    try {
      final data = await service.fetchWeatherDataFor(id);
      sent += (await planner.record(
        id,
        lp.placeById(id).name,
        data.hourlyForecast,
        now,
      )).length;
    } catch (e) {
      debugPrint('backgroundCheck $id: $e');
    }
  }
  await planner.rescheduleReminders();
  await planner.flush();
  return sent;
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
