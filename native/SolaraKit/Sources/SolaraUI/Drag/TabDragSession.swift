import AppKit

public enum TabDropAim: Equatable, Sendable {
  case split(tabId: String, side: SplitSide)
  case insert(beforeId: String?)
  case page
  case newWindow
}

public enum TabDropPriority: Int, Comparable, Sendable {
  case split = 0
  case insert = 1
  case page = 2

  public static func < (a: TabDropPriority, b: TabDropPriority) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
public protocol TabDropZone: AnyObject {
  func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim?
  func clear()
  func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool
}

@MainActor
public final class TabDragSession {
  public static private(set) var current: TabDragSession?

  public let tabIds: [String]
  public let sourceWindow: String
  public private(set) var pointer: CGPoint = .zero
  public private(set) var overWindow: String?
  public private(set) var aim: TabDropAim?

  private struct Registered {
    weak var zone: TabDropZone?
    let windowId: String
    let priority: TabDropPriority
  }

  private static var zones: [Registered] = []
  private var aimed: TabDropZone?

  init(tabIds: [String], sourceWindow: String) {
    self.tabIds = tabIds
    self.sourceWindow = sourceWindow
  }

  public static func register(_ zone: TabDropZone, windowId: String, priority: TabDropPriority) {
    zones.removeAll { $0.zone == nil || $0.zone === zone }
    zones.append(Registered(zone: zone, windowId: windowId, priority: priority))
  }

  public static func unregister(_ zone: TabDropZone) {
    zones.removeAll { $0.zone == nil || $0.zone === zone }
  }

  @discardableResult
  public static func begin(tabIds: [String], from windowId: String) -> TabDragSession {
    current?.cancel()
    let session = TabDragSession(tabIds: tabIds, sourceWindow: windowId)
    current = session
    return session
  }

  public func away(for windowId: String) -> Bool { overWindow != windowId }

  public func move(screenPoint: CGPoint) {
    guard Self.current === self else { return }
    pointer = screenPoint
    let window = Self.window(at: screenPoint)
    overWindow = window.map { $0.0 }
    var next: (zone: TabDropZone, aim: TabDropAim)?
    if let (windowId, nsWindow) = window {
      let local = Self.windowPoint(screenPoint, in: nsWindow)
      let candidates = Self.zones.filter { $0.windowId == windowId && $0.zone != nil }.sorted { $0.priority < $1.priority }
      for entry in candidates {
        guard let zone = entry.zone, let found = zone.aim(self, at: local) else { continue }
        next = (zone, found)
        break
      }
    }
    if let aimed, aimed !== next?.zone { aimed.clear() }
    aimed = next?.zone
    aim = next?.aim ?? (window == nil ? .newWindow : nil)
  }

  public func end() -> Bool {
    guard Self.current === self else { return false }
    Self.current = nil
    defer { clearAll() }
    guard let aim else { return false }
    if let aimed { return aimed.drop(self, aim) }
    return false
  }

  public func cancel() {
    guard Self.current === self else { return }
    Self.current = nil
    clearAll()
  }

  private func clearAll() {
    aimed?.clear()
    aimed = nil
    aim = nil
  }

  public static var windowIdOf: (NSWindow) -> String? = { _ in nil }

  private static func window(at screenPoint: CGPoint) -> (String, NSWindow)? {
    var number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
    while number > 0 {
      if let nsWindow = NSApp.window(withWindowNumber: number), let id = windowIdOf(nsWindow) { return (id, nsWindow) }
      number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: number)
    }
    return nil
  }

  private static func windowPoint(_ screenPoint: CGPoint, in window: NSWindow) -> CGPoint {
    let p = window.convertPoint(fromScreen: screenPoint)
    let height = window.contentView?.bounds.height ?? window.frame.height
    return CGPoint(x: p.x, y: height - p.y)
  }
}
