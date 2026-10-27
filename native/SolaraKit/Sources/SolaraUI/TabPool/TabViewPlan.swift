import Foundation

public struct TabSlotKey: Hashable, Sendable, Comparable {
  public var windowId: String
  public var tabId: String

  public init(windowId: String, tabId: String) {
    self.windowId = windowId
    self.tabId = tabId
  }

  public static func < (a: TabSlotKey, b: TabSlotKey) -> Bool { (a.windowId, a.tabId) < (b.windowId, b.tabId) }
}

public enum TabViewPlace: Equatable, Sendable {
  case slot(TabSlotKey)
  case parked
}

public struct TabViewWanted: Equatable, Sendable {
  public var tabId: String
  public var windowId: String
  public var warm: Bool

  public init(tabId: String, windowId: String, warm: Bool = false) {
    self.tabId = tabId
    self.windowId = windowId
    self.warm = warm
  }
}

public enum TabViewOp: Equatable, Sendable {
  case drop(String)
  case park(String)
  case create(String)
  case attach(String, TabSlotKey)
  case visible(String, Bool)
}

public enum TabViewPlan {
  public static func plan(wanted: [TabViewWanted], slots: Set<TabSlotKey>, current: [String: TabViewPlace], visible: [String: Bool]) -> [TabViewOp] {
    var ops: [TabViewOp] = []
    let wantedById = Dictionary(wanted.map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
    for tabId in current.keys.sorted() where wantedById[tabId] == nil { ops.append(.drop(tabId)) }
    var target: [String: TabViewPlace] = [:]
    for w in wantedById.values {
      let key = TabSlotKey(windowId: w.windowId, tabId: w.tabId)
      target[w.tabId] = slots.contains(key) ? .slot(key) : .parked
    }
    let ids = target.keys.sorted()
    for tabId in ids where target[tabId] == .parked && current[tabId] != .parked {
      ops.append(current[tabId] == nil ? .create(tabId) : .park(tabId))
    }
    for tabId in ids {
      guard case .slot(let key) = target[tabId], current[tabId] != target[tabId] else { continue }
      if current[tabId] == nil { ops.append(.create(tabId)) }
      ops.append(.attach(tabId, key))
    }
    for tabId in ids {
      let shown = target[tabId] != .parked || wantedById[tabId]?.warm == true
      if visible[tabId] != shown { ops.append(.visible(tabId, shown)) }
    }
    return ops
  }

  public static func apply(_ ops: [TabViewOp], to current: [String: TabViewPlace], visible: [String: Bool]) -> (current: [String: TabViewPlace], visible: [String: Bool]) {
    var places = current, shown = visible
    for op in ops {
      switch op {
      case .drop(let id): places[id] = nil; shown[id] = nil
      case .park(let id): places[id] = .parked
      case .create(let id): places[id] = .parked
      case .attach(let id, let key): places[id] = .slot(key)
      case .visible(let id, let on): shown[id] = on
      }
    }
    return (places, shown)
  }
}
