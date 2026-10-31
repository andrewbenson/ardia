import Foundation

@MainActor
enum SettingsTimings {
  static var recording: Bool { ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" }
  private static var marks: [[String: Any]] = []
  private static var navigated: [String: Double] = [:]

  static func navigating(_ pane: String) {
    guard recording else { return }
    navigated[pane] = now
  }

  static func paneAppeared(_ pane: String) {
    guard recording else { return }
    let appeared = now
    DispatchQueue.main.async {
      MainActor.assumeIsolated { marks.append(["pane": pane, "navigated": navigated[pane] ?? 0, "appeared": appeared, "committed": now]) }
    }
  }

  static func takeJSON() -> String {
    let taken = marks
    marks = []
    guard let data = try? JSONSerialization.data(withJSONObject: taken) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  static var now: Double { Date().timeIntervalSince1970 * 1000 }
}
