import AppKit

@MainActor
public final class TabSlots {
  public static let shared = TabSlots()
  public static let changed = Notification.Name("SolaraTabSlotsChanged")

  private var containers: [TabSlotKey: NSView] = [:]

  public init() {}

  public func set(_ key: TabSlotKey, container: NSView) {
    guard containers[key] !== container else { return }
    containers[key] = container
    post(key)
  }

  public func remove(_ key: TabSlotKey, container: NSView) {
    guard containers[key] === container else { return }
    containers[key] = nil
    post(key)
  }

  public func container(for key: TabSlotKey) -> NSView? { containers[key] }

  public var keys: Set<TabSlotKey> { Set(containers.keys) }

  public func keys(in windowId: String) -> Set<TabSlotKey> { Set(containers.keys.filter { $0.windowId == windowId }) }

  private func post(_ key: TabSlotKey) {
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["windowId": key.windowId])
  }
}
