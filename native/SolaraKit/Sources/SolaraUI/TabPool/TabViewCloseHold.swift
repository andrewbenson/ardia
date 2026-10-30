public struct TabViewCloseHold: Sendable {
  public let absentTabIds: Set<String>

  public init(tabIds: Set<String>, presentTabIds: Set<String>) {
    absentTabIds = tabIds.subtracting(presentTabIds)
  }

  public func restored(presentTabIds: Set<String>, freshTabIds: Set<String>, unloadedTabIds: Set<String>) -> Bool {
    let returned = absentTabIds.intersection(presentTabIds)
    return !returned.isEmpty && returned.isSubset(of: freshTabIds.union(unloadedTabIds))
  }
}
