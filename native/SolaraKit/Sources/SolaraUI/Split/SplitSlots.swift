import AppKit

@MainActor
public final class SplitSlots {
  public static let shared = SplitSlots()
  public static let changed = Notification.Name("SolaraSplitSlotsChanged")

  private var panes: [String: [String: CGRect]] = [:]

  public func panes(_ windowId: String) -> [String: CGRect] { panes[windowId] ?? [:] }

  func publish(_ windowId: String, _ next: [String: CGRect]) {
    guard panes[windowId] != next else { return }
    panes[windowId] = next.isEmpty ? nil : next
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": windowId])
  }
}
