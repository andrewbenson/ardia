import SolaraModel

extension TabViewWanted {
  public static func from(_ state: BrowserState, windows: Set<String>, isInternal: (Tab) -> Bool, frozen: (String) -> Bool) -> [TabViewWanted] {
    var out: [String: TabViewWanted] = [:]
    for windowId in windows.sorted() {
      guard let window = state.windows[windowId] else { continue }
      let active = window.activeTabIds[window.profileId]
      let split = active.flatMap { id in state.splits.values.first { $0.windowId == windowId && $0.tabIds.contains(id) } }
      let warm = Set(window.activeTabIds.keys.filter { $0 != window.profileId }.compactMap { window.activeTabIds[$0] })
      for id in window.tabIds {
        guard let tab = state.tabs[id], ((tab.navigation != nil || tab.adoptId != nil) && !isInternal(tab)) else { continue }
        let shown: Shown
        if let split, split.tabIds.contains(id) { shown = .pane } else if id == active { shown = .card } else { shown = .none }
        out[id] = TabViewWanted(tabId: id, windowId: windowId, shown: shown, warm: warm.contains(id), frozen: frozen(id))
      }
      if let peek = state.peeks[windowId], let tab = state.tabs[peek.tabId], ((tab.navigation != nil || tab.adoptId != nil) && !isInternal(tab)) {
        out[peek.tabId] = TabViewWanted(tabId: peek.tabId, windowId: windowId, shown: .peek, frozen: frozen(peek.tabId))
      }
    }
    return out.keys.sorted().map { out[$0]! }
  }
}
