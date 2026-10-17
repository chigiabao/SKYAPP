/// Thong bao ngan khi dang di (nhom 6): kenh rieng co / khong co am thanh.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';

abstract class TripNotifier {
  /// Xin quyen thong bao (goi khi bat dau chuyen di).
  Future<bool> requestPermission();

  /// Hien thong bao; [sound] = am thanh mac dinh cua he thong.
  Future<void> notify(int id, String title, String body, {required bool sound});

  /// Android, iOS co thong bao he thong; web / desktop thi khong.
  static TripNotifier platform() => NotificationService.isSupportedPlatform
      ? LocalTripNotifier()
      : const NoopTripNotifier();
}

class NoopTripNotifier implements TripNotifier {
  const NoopTripNotifier();

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> notify(
    int id,
    String title,
    String body, {
    required bool sound,
  }) async {}
}

/// flutter_local_notifications; khoi tao qua [LocalNotificationService].
class LocalTripNotifier implements TripNotifier {
  LocalTripNotifier({NotificationService? base})
    : _base = base ?? LocalNotificationService();

  final NotificationService _base;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static NotificationDetails detailsFor({required bool sound}) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? 'sky_weather_trip' : 'sky_weather_trip_silent',
          sound ? 'Chuyến đi' : 'Chuyến đi (im lặng)',
          channelDescription: 'Mưa lớn, dông trên đường đang đi',
          importance: Importance.high,
          priority: Priority.high,
          playSound: sound,
          enableVibration: sound,
          category: AndroidNotificationCategory.navigation,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: sound,
        ),
      );

  @override
  Future<bool> requestPermission() => _base.requestPermission();

  @override
  Future<void> notify(
    int id,
    String title,
    String body, {
    required bool sound,
  }) async {
    if (!await _base.init()) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: detailsFor(sound: sound),
      );
    } catch (e) {
      debugPrint('TripNotifier.notify: $e');
    }
  }
}
