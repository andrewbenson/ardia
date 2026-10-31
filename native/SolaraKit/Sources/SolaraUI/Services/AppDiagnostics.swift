import Foundation
import SolaraModel
import SolaraStore

public struct AppFacts: Equatable, Sendable {
  public var appName = ""
  public var appVersion = ""
  public var appBuild = ""
  public var configuration = ""
  public var osVersion = ""
  public var osBuild = ""
  public var arch = ""
  public var model = ""
  public var memoryGB: Double = 0
  public var bundleId = ""
  public var locale = ""
  public var feedbackURL: String?
  public var feedbackEmail: String?

  public init() {}

  public init(_ info: [String: Any]) {
    appName = info["appName"] as? String ?? ""
    appVersion = info["appVersion"] as? String ?? ""
    appBuild = info["appBuild"] as? String ?? ""
    configuration = info["configuration"] as? String ?? ""
    osVersion = info["osVersion"] as? String ?? ""
    osBuild = info["osBuild"] as? String ?? ""
    arch = info["arch"] as? String ?? ""
    model = info["model"] as? String ?? ""
    memoryGB = info["memoryGB"] as? Double ?? 0
    bundleId = info["bundleId"] as? String ?? ""
    locale = info["locale"] as? String ?? ""
    feedbackURL = info["feedbackURL"] as? String
    feedbackEmail = info["feedbackEmail"] as? String
  }
}

public struct UpdaterFacts: Equatable, Sendable {
  public var available = false
  public var configured = false
  public var automaticChecks = false
  public var feedURL: String?

  public init(available: Bool = false, configured: Bool = false, automaticChecks: Bool = false, feedURL: String? = nil) {
    self.available = available
    self.configured = configured
    self.automaticChecks = automaticChecks
    self.feedURL = feedURL
  }

  public init(_ state: [String: Any]) {
    available = state["available"] as? Bool ?? false
    configured = state["configured"] as? Bool ?? false
    automaticChecks = state["automaticChecks"] as? Bool ?? false
    feedURL = state["feedURL"] as? String
  }
}

public enum FeedbackTarget: Equatable, Sendable {
  case page(String)
  case mail(draft: String, body: String)
}

public enum AppDiagnostics {
  public static func report(
    app: AppFacts, engine: [String: Any], updates: UpdaterFacts?, state: BrowserState?, storeStatus: AppIntegrationStoreStatus = .ready
  ) -> String {
    report(app: app, chromiumVersion: engine["chromiumVersion"] as? String ?? "", updates: updates, state: state, storeStatus: storeStatus)
  }

  public static func report(
    app: AppFacts, chromiumVersion: String, updates: UpdaterFacts?, state: BrowserState?, storeStatus: AppIntegrationStoreStatus = .ready
  ) -> String {
    let updateLine: String
    if let updates, updates.available {
      updateLine = updates.configured
        ? "Updates: automatic checks \(updates.automaticChecks ? "on" : "off"), feed \(updates.feedURL ?? "none")"
        : "Updates: not set up for this build"
    } else {
      updateLine = "Updates: not built in"
    }
    var lines = [
      "\(app.appName) \(app.appVersion) (\(app.appBuild)) — \(app.configuration)",
      "Engine: ArdiaCore, Chromium \(chromiumVersion)",
      "macOS \(app.osVersion) (\(app.osBuild)), \(app.arch), \(app.model), \(Int(app.memoryGB.rounded(.toNearestOrAwayFromZero))) GB",
      "Bundle: \(app.bundleId), locale \(app.locale)",
    ]
    if let reason = storeStatus.unavailableReason {
      lines.append("store: not open")
      lines.append(reason)
    } else if let state {
      let regular = state.windowOrder.filter { state.windows[$0]?.incognito != true }.count
      let incognito = state.windowOrder.count - regular
      lines.append("Windows: \(regular) (+\(incognito) incognito), tabs: \(state.tabs.count), profiles: \(state.profileOrder.count)")
    }
    lines.append(updateLine)
    return lines.joined(separator: "\n")
  }

  public static func feedbackBody(_ report: String) -> String {
    "What happened?\n\n\nWhat did you expect?\n\n\n---\n\(report)"
  }

  public static func feedback(report: String, app: AppFacts) -> FeedbackTarget {
    let body = feedbackBody(report)
    if let page = app.feedbackURL, page.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil {
      guard let marker = page.range(of: "%s") else { return .page(page) }
      return .page(page.replacingCharacters(in: marker, with: encodeURIComponent(body)))
    }
    let email = app.feedbackEmail ?? ""
    let to = email.isEmpty || email.utf16.contains { JS.isWhitespace($0) || $0 == 0x3F || $0 == 0x26 } ? "" : email
    let draft = "mailto:\(to)?subject=\(encodeURIComponent("\(app.appName) Feedback"))&body=\(encodeURIComponent(body))"
    return .mail(draft: draft, body: body)
  }

  private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)

  public static func encodeURIComponent(_ text: String) -> String {
    var out = ""
    for byte in text.utf8 {
      if unreserved.contains(byte) {
        out.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }
}

public struct HandoffActivity: Equatable, Sendable {
  public var windowId: String
  public var url: String?
  public var title: String?
}

public struct HandoffTracker: Sendable {
  private var last: [String: String] = [:]

  public init() {}

  public mutating func changes(_ state: BrowserState) -> [HandoffActivity] {
    var out: [HandoffActivity] = []
    for id in state.windowOrder {
      guard let window = state.windows[id] else { continue }
      let tab = state.activeTabId(id).flatMap { state.tabs[$0] }
      let url = !window.incognito ? tab.map(\.url).flatMap { $0.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil ? $0 : nil } : nil
      let title = tab.map { $0.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? $0.title } ?? ""
      let key = "\(url ?? "null")\n\(title)"
      if last[id]?.jsEquals(key) == true { continue }
      last[id] = key
      out.append(HandoffActivity(windowId: id, url: url, title: title.isEmpty ? nil : title))
    }
    for id in last.keys where state.windows[id] == nil { last[id] = nil }
    return out
  }
}
