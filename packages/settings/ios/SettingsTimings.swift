import Foundation
import QuartzCore

@MainActor
enum SettingsTimings {
  static var recording: Bool { ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1" }
  private static var marks: [[String: Any]] = []

  static func paneAppeared(_ pane: String) {
    guard recording else { return }
    let appeared = now
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      MainActor.assumeIsolated { marks.append(["pane": pane, "appeared": appeared, "committed": now]) }
    }
    CATransaction.commit()
  }

  static func takeJSON() -> String {
    let taken = marks
    marks = []
    guard let data = try? JSONSerialization.data(withJSONObject: taken) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  static var now: Double { Date().timeIntervalSince1970 * 1000 }
}
