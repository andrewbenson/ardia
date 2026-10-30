import SolaraModel

extension Session {
  static let commandOnlySlices: Set<String> = ["find", "selection", "selectionAnchors", "windowUi"]

  public func setAppDark(_ dark: Bool) {
    guard state.ui.appDark != dark else { return }
    update { $0.ui.appDark = dark }
  }

  public func setFind(_ tabId: String, _ patch: TabUpdate) {
    guard state.tabs.contains(tabId) else { return }
    var find = state.find[tabId] ?? FindState()
    for (key, value) in patch.set { find.json[key] = value }
    for key in patch.unset { find.json.removeValue(forKey: key) }
    update { $0.find[tabId] = find }
  }

  public func setSelection(_ windowId: String, _ ids: [String]) {
    let view = Set(state.viewTabIds(windowId))
    var seen = Set<String>()
    let picked = ids.filter { view.contains($0) && seen.insert($0).inserted }
    guard picked != (state.selection[windowId]?.ids ?? []) else { return }
    update { $0.selection[windowId] = picked.isEmpty ? nil : TabSelection(picked) }
  }

  public func setSelectionAnchor(_ windowId: String, _ tabId: String) {
    guard state.windows.contains(windowId), state.selectionAnchors[windowId]?.tabId != tabId else { return }
    update { $0.selectionAnchors[windowId] = SelectionAnchor(tabId) }
  }

  public func clickTab(_ windowId: String, _ tabId: String, _ mods: JSONObject) {
    let meta = mods["metaKey"]?.truthy ?? false
    let shift = mods["shiftKey"]?.truthy ?? false
    let alt = mods["altKey"]?.truthy ?? false
    let intoGroup = alt && shift && !meta && state.settings.bool("optShiftClickOpensInGroup")
    let picked = intoGroup ? nil : clickedSelection(windowId, tabId, meta: meta, shift: shift)
    if intoGroup { openInActiveGroup(windowId, tabId) }
    if let anchor = picked.map({ $0.anchor }) ?? .some(tabId), !anchor.isEmpty { setSelectionAnchor(windowId, anchor) }
    setSelection(windowId, picked?.ids ?? [])
    if picked == nil { activate(tabId) }
  }

  func clickedSelection(_ windowId: String, _ tabId: String, meta: Bool, shift: Bool) -> (ids: [String], anchor: String?)? {
    let s = state
    let active = s.activeTabId(windowId)
    if meta {
      let current = s.selection[windowId]?.ids ?? []
      let base = !current.isEmpty ? current : active.map { [$0] } ?? []
      let next = base.contains(tabId) ? base.filter { $0 != tabId } : base + [tabId]
      return (next.count > 1 ? next : [], tabId)
    }
    guard shift else { return nil }
    let anchor = s.selectionAnchors[windowId]?.tabId
    let view = s.viewTabIds(windowId)
    guard let from = view.firstIndex(of: anchor ?? active ?? tabId), let to = view.firstIndex(of: tabId) else { return nil }
    return (Array(view[min(from, to)...max(from, to)]), anchor)
  }

  func openInActiveGroup(_ windowId: String, _ tabId: String) {
    let s = state
    guard let active = s.activeTabId(windowId), active != tabId, s.tabs[tabId]?.pinned != true, s.tabs[active]?.pinned != true else { return }
    if let group = groupOf(s, active) {
      addTabsToGroup(group.id, [tabId])
    } else {
      _ = groupTabs([active, tabId], pinned: true, name: nil)
    }
  }

  public func openPanel(_ windowId: String, _ initialText: String, _ newTab: JSONValue?) {
    guard state.windows.contains(windowId) else { return }
    var panel: JSONObject = ["open": true, "initialText": .string(initialText)]
    if let newTab { panel["newTab"] = newTab }
    var entry = state.windowUi[windowId] ?? WindowUi()
    guard entry.json["panel"] != .object(panel) else { return }
    entry.json["panel"] = .object(panel)
    update { $0.windowUi[windowId] = entry }
  }

  public func closePanel(_ windowId: String) {
    var next = state
    next.closePanel(windowId)
    if next.windowUi != state.windowUi { set(next) }
  }

  public func setDownloadsOpen(_ windowId: String, _ open: Bool) {
    var next = state
    next.setDownloadsOpen(windowId, open)
    if next.windowUi != state.windowUi { set(next) }
  }
}
