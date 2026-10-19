import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Thong bao he thong, boc sau interface de test bang fake va de web / test
/// / desktop khong crash (dung [NoopNotificationService]).
///
/// Moi thoi diem la "gio dong ho TP.HCM" (xem HcmTime).
abstract class NotificationService {
  /// Khoi tao plugin; false neu khong ho tro.
  Future<bool> init();

  /// Xin quyen POST_NOTIFICATIONS (Android 13+) / alert-sound-badge (iOS).
  /// true = da cho phep.
  Future<bool> requestPermission();

  /// Hien ngay.
  Future<void> show(int id, String title, String body);

  /// Hen luc [atHcm] (gio TP.HCM, mui Asia/Ho_Chi_Minh).
  Future<void> schedule(int id, DateTime atHcm, String title, String body);

  /// Huy moi thong bao da hen (chi nhac hoat dong duoc hen).
  Future<void> cancelScheduled();

  /// Thong bao he thong that tren nen tang hien tai (Android, iOS; khong
  /// web); con lai -> [NoopNotificationService].
  static NotificationService platform() => isSupportedPlatform
      ? LocalNotificationService()
      : const NoopNotificationService();

  /// Nen tang co thong bao cuc bo that (Android, iOS).
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

/// Khong lam gi (web, desktop, test).
class NoopNotificationService implements NotificationService {
  const NoopNotificationService();

  @override
  Future<bool> init() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> show(int id, String title, String body) async {}

  @override
  Future<void> schedule(
    int id,
    DateTime atHcm,
    String title,
    String body,
  ) async {}

  @override
  Future<void> cancelScheduled() async {}
}

/// flutter_local_notifications (Android, iOS). Loi plugin chi ghi log.
class LocalNotificationService implements NotificationService {
  LocalNotificationService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool? _ready;
  tz.Location? _hcm;

  static const String _alertChannel = 'sky_weather_alerts';
  static const String _reminderChannel = 'sky_weather_reminders';

  static const NotificationDetails _alertDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _alertChannel,
      'Cảnh báo thời tiết',
      channelDescription: 'Mưa, dông, nắng nóng, gió, UV, AQI',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(''),
    ),
    iOS: DarwinNotificationDetails(),
  );

  static const NotificationDetails _reminderDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _reminderChannel,
      'Nhắc hoạt động và tóm tắt buổi sáng',
      channelDescription:
          'Nhắc trước giờ hoạt động, tóm tắt mưa buổi sáng cho Nhà và Nơi làm',
      styleInformation: BigTextStyleInformation(''),
    ),
    iOS: DarwinNotificationDetails(),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool> init() async {
    if (_ready != null) return _ready!;
    try {
      tzdata.initializeTimeZones();
      _hcm = tz.getLocation('Asia/Ho_Chi_Minh');
      _ready =
          await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings(
                '@drawable/ic_stat_weather',
              ),
              // Khong xin quyen luc khoi tao; chi xin khi nguoi dung bat
              // thong bao (requestPermission).
              iOS: DarwinInitializationSettings(
                requestAlertPermission: false,
                requestSoundPermission: false,
                requestBadgePermission: false,
              ),
            ),
          ) ??
          false;
    } catch (e) {
      debugPrint('NotificationService.init: $e');
      _ready = false;
    }
    return _ready!;
  }

  @override
  Future<bool> requestPermission() async {
    if (!await init()) return false;
    try {
      final ios = _ios;
      if (ios != null) {
        final granted = await ios.requestPermissions(
          alert: true,
          sound: true,
          badge: true,
        );
        return granted ?? (await ios.checkPermissions())?.isEnabled ?? false;
      }
      final android = _android;
      if (android == null) return false;
      final granted = await android.requestNotificationsPermission();
      return granted ?? await android.areNotificationsEnabled() ?? false;
    } catch (e) {
      debugPrint('NotificationService.requestPermission: $e');
      return false;
    }
  }

  @override
  Future<void> show(int id, String title, String body) async {
    if (!await init()) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: _alertDetails,
      );
    } catch (e) {
      debugPrint('NotificationService.show: $e');
    }
  }

  @override
  Future<void> schedule(
    int id,
    DateTime atHcm,
    String title,
    String body,
  ) async {
    if (!await init() || _hcm == null) return;
    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime(
          _hcm!,
          atHcm.year,
          atHcm.month,
          atHcm.day,
          atHcm.hour,
          atHcm.minute,
        ),
        notificationDetails: _reminderDetails,
        // Khong can quyen bao thuc chinh xac; co the lech vai phut.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
      );
    } catch (e) {
      debugPrint('NotificationService.schedule: $e');
    }
  }

  @override
  Future<void> cancelScheduled() async {
    if (!await init()) return;
    try {
      await _plugin.cancelAllPendingNotifications();
    } catch (e) {
      debugPrint('NotificationService.cancelScheduled: $e');
    }
  }
}
