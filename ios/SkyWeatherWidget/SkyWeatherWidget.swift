// Widget man hinh chinh iOS (WidgetKit, small + medium).
//
// Du lieu do app ghi qua home_widget (lib/services/home_widget_service.dart)
// vao UserDefaults cua App Group. Cac khoa: sw_place, sw_temp, sw_condition,
// sw_rain3h, sw_updated (epoch giay). Khong co App Group (vd. ban ky bang
// Apple ID mien phi khong tao group) -> hien placeholder.
import SwiftUI
import WidgetKit

private let kWidgetKind = "SkyWeatherWidget"
private let kDefaultAppGroup = "group.com.skyweather.app"

/// App Group dung duoc. AltStore/SideStore doi ten group (them team id) va ghi
/// ten moi vao khoa Info.plist `ALTAppGroups` (cua appex hoac cua app chua no).
private func resolveAppGroup() -> String? {
  var candidates: [String] = []
  // .../Runner.app/PlugIns/SkyWeatherWidget.appex -> .../Runner.app
  let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
  for bundle in [Bundle.main, Bundle(url: hostURL)].compactMap({ $0 }) {
    if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
      candidates += groups
    }
  }
  candidates.append(kDefaultAppGroup)
  return candidates.first {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
  }
}

struct WeatherEntry: TimelineEntry {
  let date: Date
  let place: String
  let temp: String
  let condition: String
  let rain: String
  let updated: Date?
  let hasData: Bool

  static func placeholder(_ date: Date = Date()) -> WeatherEntry {
    WeatherEntry(
      date: date, place: "Sky Weather", temp: "--°", condition: "Mở app để cập nhật",
      rain: "--", updated: nil, hasData: false)
  }

  static func load(_ date: Date = Date()) -> WeatherEntry {
    guard let group = resolveAppGroup(), let defaults = UserDefaults(suiteName: group),
      let temp = defaults.string(forKey: "sw_temp")
    else { return placeholder(date) }
    // "Mưa 3 giờ tới: 40%" -> "40%"
    let rainText = defaults.string(forKey: "sw_rain3h") ?? ""
    let rain = rainText.components(separatedBy: ": ").last ?? "--"
    let updated = (defaults.object(forKey: "sw_updated") as? NSNumber)
      .map { Date(timeIntervalSince1970: $0.doubleValue) }
    return WeatherEntry(
      date: date,
      place: defaults.string(forKey: "sw_place") ?? "Sky Weather",
      temp: temp,
      condition: defaults.string(forKey: "sw_condition") ?? "",
      rain: rain.isEmpty ? "--" : rain,
      updated: updated,
      hasData: true)
  }
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> WeatherEntry { WeatherEntry.placeholder() }

  func getSnapshot(in context: Context, completion: @escaping (WeatherEntry) -> Void) {
    completion(context.isPreview ? WeatherEntry.placeholder() : WeatherEntry.load())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WeatherEntry>) -> Void) {
    // App goi reloadTimelines khi co du lieu moi; doc lai moi gio cho chac.
    let next = Date().addingTimeInterval(3600)
    completion(Timeline(entries: [WeatherEntry.load()], policy: .after(next)))
  }
}

/// Trang thai (WeatherCondition.description o Dart) -> SF Symbol.
private func symbolName(for condition: String, hasData: Bool) -> String {
  guard hasData else { return "cloud.sun" }
  switch condition {
  case "Trời quang": return "sun.max.fill"
  case "Có mây": return "cloud.sun.fill"
  case "Nhiều mây": return "cloud.fill"
  case "Mưa phùn": return "cloud.drizzle.fill"
  case "Có mưa": return "cloud.rain.fill"
  case "Mưa rào": return "cloud.heavyrain.fill"
  case "Dông bão": return "cloud.bolt.rain.fill"
  case "Sương mù": return "cloud.fog.fill"
  case "Gió lớn": return "wind"
  default: return "cloud.fill"
  }
}

private func updatedText(_ date: Date?) -> String {
  guard let date = date else { return "Chưa cập nhật" }
  let f = DateFormatter()
  f.dateFormat = "HH:mm"
  f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
  return "Cập nhật \(f.string(from: date))"
}

private let kBackground = LinearGradient(
  colors: [Color(red: 0.16, green: 0.45, blue: 0.86), Color(red: 0.07, green: 0.22, blue: 0.52)],
  startPoint: .topLeading, endPoint: .bottomTrailing)

extension View {
  /// iOS 17+ bat buoc containerBackground; iOS 15-16 dung background thuong.
  @ViewBuilder
  func widgetBackground<B: View>(_ bg: B) -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) { bg }
    } else {
      padding().background(bg)
    }
  }
}

struct RainLabel: View {
  let rain: String
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "umbrella.fill")
      Text("3 giờ: \(rain)")
    }
    .font(.caption)
  }
}

struct SmallView: View {
  let entry: WeatherEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.place).font(.caption).bold().lineLimit(1)
      HStack(alignment: .center, spacing: 6) {
        Image(systemName: symbolName(for: entry.condition, hasData: entry.hasData))
          .renderingMode(.original)
          .font(.title2)
        Text(entry.temp).font(.system(size: 34, weight: .semibold)).minimumScaleFactor(0.6)
      }
      Text(entry.condition).font(.caption2).lineLimit(1)
      Spacer(minLength: 0)
      RainLabel(rain: entry.rain)
      Text(updatedText(entry.updated)).font(.system(size: 10)).opacity(0.75)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct MediumView: View {
  let entry: WeatherEntry
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.place).font(.subheadline).bold().lineLimit(1)
        Text(entry.temp).font(.system(size: 44, weight: .semibold)).minimumScaleFactor(0.6)
        Text(entry.condition).font(.caption).lineLimit(1)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 6) {
        Image(systemName: symbolName(for: entry.condition, hasData: entry.hasData))
          .renderingMode(.original)
          .font(.system(size: 40))
        RainLabel(rain: entry.rain)
        Text(updatedText(entry.updated)).font(.caption2).opacity(0.75)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SkyWeatherWidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: WeatherEntry

  var body: some View {
    Group {
      if family == .systemMedium {
        MediumView(entry: entry)
      } else {
        SmallView(entry: entry)
      }
    }
    .foregroundColor(.white)
    .widgetBackground(kBackground)
  }
}

@main
struct SkyWeatherWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kWidgetKind, provider: Provider()) { entry in
      SkyWeatherWidgetView(entry: entry)
    }
    .configurationDisplayName("Sky Weather")
    .description("Nhiệt độ, trạng thái và khả năng mưa 3 giờ tới.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
