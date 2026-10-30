public struct MemoryTrimSchedule: Sendable {
  public private(set) var tabCount: Int
  public private(set) var dueAt: Double?
  public private(set) var lastTrimAt: Double = 0
  public private(set) var postponements = 0

  public init(tabCount: Int) {
    self.tabCount = tabCount
  }

  public static func enabled(environment: [String: String]) -> Bool {
    !["off", "0", "false"].contains(environment["ARDIA_MEMORY_TRIM"] ?? "")
  }

  @discardableResult
  public mutating func tabsChanged(count: Int, now: Double) -> Bool {
    guard count != tabCount else { return false }
    tabCount = count
    dueAt = now + 5000
    postponements = 0
    return true
  }

  public mutating func fire(now: Double, inputIdleSeconds: Double?, quitting: Bool) -> Bool {
    guard let dueAt else { return false }
    self.dueAt = nil
    guard !quitting else { return false }
    let wait = lastTrimAt + 30000 - now
    if wait > 0 {
      self.dueAt = now + wait
      return false
    }
    guard now - dueAt < 50, (inputIdleSeconds ?? .infinity) >= 2 else {
      if postponements < 30 {
        postponements += 1
        self.dueAt = now + 1000
      }
      return false
    }
    lastTrimAt = now
    return true
  }
}
