import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testBackgroundRefreshConfiguration() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertEqual(
      info["BGTaskSchedulerPermittedIdentifiers"] as? [String],
      ["sky_weather_hourly_check"]
    )
    let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
    XCTAssertEqual(Set(modes), Set(["fetch", "location"]))
  }

  func testTransportAllowsLocalNetworkingWithoutGlobalBypass() throws {
    let transport = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
    )
    XCTAssertEqual(transport["NSAllowsLocalNetworking"] as? Bool, true)
    XCTAssertNotEqual(transport["NSAllowsArbitraryLoads"] as? Bool, true)
    XCTAssertFalse(
      (Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String ?? "").isEmpty
    )
  }

  func testSceneDelegateConfiguration() throws {
    let manifest = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
    )
    let configurations = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: Any])
    let scenes = try XCTUnwrap(configurations["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])
    let scene = try XCTUnwrap(scenes.first)
    let delegateName = try XCTUnwrap(scene["UISceneDelegateClassName"] as? String)
    XCTAssertNotNil(NSClassFromString(delegateName))
  }

}
