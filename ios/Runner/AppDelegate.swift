import Flutter
import UIKit
import UserNotifications
// Can cho FlutterLocalNotificationsPlugin / WorkmanagerPlugin.setPluginRegistrantCallback.
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Trung voi kBackgroundTask (lib/services/background_check.dart) va
  /// BGTaskSchedulerPermittedIdentifiers trong Info.plist.
  private static let backgroundTask = "sky_weather_hourly_check"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background-only launches may never initialize the implicit UI engine.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // flutter_local_notifications: hien thong bao ca khi app dang mo.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // workmanager + UIScene: handler BGTaskScheduler phai dang ky truoc khi
    // didFinishLaunching tra ve.
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: AppDelegate.backgroundTask)
    WorkmanagerPlugin.registerLaunchHandlers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
