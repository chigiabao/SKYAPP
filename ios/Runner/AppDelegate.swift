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
    // flutter_local_notifications: hien thong bao ca khi app dang mo.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // workmanager + UIScene: handler BGTaskScheduler phai dang ky truoc khi
    // didFinishLaunching tra ve.
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: AppDelegate.backgroundTask)
    WorkmanagerPlugin.registerLaunchHandlers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Engine phu (tac vu nen / action thong bao) cung can plugin.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      AppDelegate.registerPlugins(registry)
    }
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      AppDelegate.registerPlugins(registry)
    }
    AppDelegate.registerPlugins(engineBridge.pluginRegistry)
  }

  private static func registerPlugins(_ registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
    if let registrar = registry.registrar(forPlugin: "AppGroupChannel") {
      AppGroupChannel.register(with: registrar)
    }
  }
}

/// Kenh `sky_weather/app_group` (lib/services/home_widget_service.dart): tra ve
/// App Group dung duoc de chia du lieu voi widget, hoac nil neu ban ky khong co
/// App Group. AltStore/SideStore doi ten group va ghi vao Info.plist `ALTAppGroups`.
class AppGroupChannel: NSObject, FlutterPlugin {
  static let defaultGroup = "group.com.skyweather.app"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "sky_weather/app_group", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AppGroupChannel(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "appGroupId" else {
      result(FlutterMethodNotImplemented)
      return
    }
    var candidates = (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
    candidates.append(AppGroupChannel.defaultGroup)
    result(candidates.first {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    })
  }
}
