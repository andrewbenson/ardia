import SolaraModel

func homeOf(_ snap: TabSnapshot) -> String { truthy(snap.pinnedUrl) ? snap.pinnedUrl! : snap.url }

extension Session {
  struct AtPin {
    var url: String?
    var title: String?
    var favicon: String??
  }

  func atPin(_ s: BrowserState, _ t: Tab, _ profileId: String) -> AtPin {
    guard let home = t.pinnedUrl, !home.isEmpty, !t.url.isEmpty, !samePage(t.url, home) else { return AtPin() }
    let entry = historyHint(s, profileId, home)
    return AtPin(url: home, title: entry?.title ?? t.title, favicon: .some(entry?.favicon ?? t.favicon))
  }

  func parkWindowPins(_ parked: Table<ParkedPins>, _ w: BrowserWindow, _ s: BrowserState, otherWindows: Bool = true, history: Bool = true) -> Table<ParkedPins> {
    if w.incognito { return parked }
    let own = s.groups.values.filter { $0.pinned && $0.windowId == w.id }
    let ownIds = Set(own.map(\.id))
    var groupOf: [String: TabGroup] = [:]
    for g in own.map({ ($0, Groups.depthOf(s.groups, $0.id)) }).stableSorted(by: { $0.1 < $1.1 }).map(\.0) {
      for id in g.tabIds { groupOf[id] = g }
    }
    var next = parked
    let profiles = OrderedSet(w.tabIds.compactMap { s.tabs[$0]?.profileId })
    func shownElsewhere(_ profileId: String) -> Bool {
      otherWindows && s.windows.values.contains { o in o.id != w.id && !o.incognito && !o.isSmall && o.tabIds.contains { s.tabs[$0]?.profileId == profileId } }
    }
    for profileId in profiles {
      if shownElsewhere(profileId) { continue }
      let mine = w.tabIds.compactMap { s.tabs[$0] }.filter { $0.profileId == profileId }
      if !mine.contains(where: { $0.pinned || groupOf[$0.id] != nil }) { continue }
      let old = next[profileId] ?? ParkedPins(tabs: [], groups: [], splits: nil)
      let ids = Set(old.tabs.map(\.id))
      var homes = old.tabs.filter { $0.groupId == nil }.map { homeOf($0.snapshot) }
      var groups = old.groups
      var tiles: [ParkedTab] = []
      var rest: [ParkedTab] = []
      var paneIds = OrderedDict<String, String>()
      let splitPanes = Set(s.splits.values.filter { $0.windowId == w.id }.flatMap(\.tabIds))
      func pending(_ t: Tab, _ moved: Bool) -> String? {
        !moved && !Ids.isIncognitoProfile(t.profileId) ? pendingRestore(t) : nil
      }
      func parked(_ t: Tab, _ back: AtPin, groupId: String?) -> ParkedTab {
        var snap = snapshotTab(t)
        if let url = back.url { snap.url = url }
        if let title = back.title { snap.title = title }
        if let favicon = back.favicon { snap.favicon = favicon }
        return ParkedTab(snapshot: snap, id: t.pinKeyOrId, groupId: groupId, restoreFrom: pending(t, back.url != nil))
      }
      for t in mine {
        if t.pinned ? t.pinnedAsRow == true : groupOf[t.id] != nil { paneIds[t.id] = t.pinKeyOrId }
        if ids.contains(t.pinKeyOrId) { continue }
        let g = t.pinned ? nil : groupOf[t.id]
        if t.pinned {
          let tile = parked(t, history ? atPin(s, t, profileId) : atPin(BrowserState(), t, profileId), groupId: nil)
          if !splitPanes.contains(t.id) && homes.contains(where: { samePage($0, homeOf(tile.snapshot)) }) {
            paneIds[t.id] = nil
            continue
          }
          homes.append(homeOf(tile.snapshot))
          if t.pinnedAsRow == true { rest.append(tile) } else { tiles.append(tile) }
        } else if let g {
          let chain = Groups.ancestorIds(s.groups, g.id).filter { ownIds.contains($0) }.reversed().map { s.groups[$0]! } + [g]
          for (i, x) in chain.enumerated() {
            if groups.contains(where: { $0.id == x.pinKeyOrId }) { continue }
            let parent = i > 0 ? chain[i - 1] : nil
            var parked = ParkedGroup(id: x.pinKeyOrId, name: x.name, icon: x.icon, color: x.color, collapsed: x.collapsed, parentId: parent?.pinKeyOrId)
            parked.absent = x.absent.intersection(lookKeys)
            groups.append(parked)
          }
          rest.append(parked(t, history ? atPin(s, t, profileId) : atPin(BrowserState(), t, profileId), groupId: g.pinKeyOrId))
        }
      }
      func isTileEntry(_ p: ParkedTab) -> Bool { p.groupId == nil && p.snapshot.pinnedAsRow != true }
      var splits = old.splits ?? []
      for v in s.splits.values {
        if v.windowId != w.id || !v.tabIds.allSatisfy({ paneIds[$0] != nil }) { continue }
        let parkedIds = v.tabIds.map { paneIds[$0]! }
        if splits.contains(where: { $0.ids.contains { parkedIds.contains($0) } }) { continue }
        splits.append(ParkedSplit(ids: parkedIds, orientation: v.orientation, sizes: v.sizes, stack: v.stack))
      }
      let tabs = old.tabs.filter(isTileEntry) + tiles + old.tabs.filter { !isTileEntry($0) } + rest
      next[profileId] = ParkedPins(tabs: tabs, groups: groups, splits: splits.isEmpty ? nil : splits)
    }
    return next
  }

  func adoptParkedPins(_ s: BrowserState, _ windowId: String, _ profileId: String) -> BrowserState {
    guard let park = s.parkedPins[profileId], let w = s.windows[windowId], !w.incognito, s.profiles[profileId] != nil else { return s }
    var tabs = s.tabs
    tabs.touch()
    let homes = w.tabIds.compactMap { tabs[$0] }.filter { $0.pinned && $0.profileId == profileId }.map(homeOf)
    var keyOf: [String: String] = [:]
    var tabOf: [String: String] = [:]
    var added: [String] = []
    let splitPanes = Set((park.splits ?? []).flatMap(\.ids))
    for p in park.tabs {
      let snap = p.snapshot
      let home = homeOf(snap)
      if p.groupId == nil && !splitPanes.contains(p.id) && homes.contains(where: { samePage($0, home) }) { continue }
      var patch = TabPatch(snap)
      patch.profileId = profileId
      patch.pinned = p.groupId == nil
      patch.pinnedUrl = .some(home.isEmpty ? nil : home)
      var tab = makeTab(windowId, profileId, snap.url, patch)
      let taken = tabs[p.id] != nil
      if taken {
        tab.id = newId("tab")
        tab.pinKey = p.id
      } else {
        tab.id = p.id
      }
      tab.navigation = nil
      tab.unloaded = true
      if let from = p.restoreFrom, !from.isEmpty, !taken { tab.wakeAdoptId = restoreId(from) }
      tabs[tab.id] = tab
      added.append(tab.id)
      tabOf[p.id] = tab.id
      if let groupId = p.groupId { keyOf[tab.id] = groupId }
    }
    var parentOf: [String: String?] = [:]
    for g in park.groups { parentOf[g.id] = g.parentId }
    func within(_ key: String?, _ target: String) -> Bool {
      var seen = Set<String>()
      var k = key
      while let current = k, !seen.contains(current) {
        if current == target { return true }
        seen.insert(current)
        k = parentOf[current] ?? nil
      }
      return false
    }
    var groups = s.groups
    groups.touch()
    var idOf: [String: String] = [:]
    for g in park.groups {
      let tabIds = added.filter { within(keyOf[$0], g.id) }
      if tabIds.isEmpty { continue }
      let id = groups[g.id] != nil ? newId("g") : g.id
      idOf[g.id] = id
      var group = TabGroup(
        id: id, windowId: windowId, profileId: profileId, name: g.name, icon: g.icon, color: g.color, collapsed: g.collapsed, pinned: true,
        tabIds: tabIds, createdAt: now)
      group.setLook(icon: g.icon, color: g.color, absent: g.absent)
      if id != g.id { group.pinKey = g.id }
      for (key, value) in g.extra { group.extra[key] = value }
      groups[id] = group
    }
    for g in park.groups {
      if let id = idOf[g.id], let parentKey = g.parentId, let parent = idOf[parentKey] { groups[id] = Groups.withParent(groups[id]!, parent) }
    }
    var splits = s.splits
    var order = added + w.tabIds
    for v in park.splits ?? [] {
      let panes = v.ids.map { tabOf[$0] ?? "" }
      if !panes.allSatisfy({ !$0.isEmpty }) { continue }
      let id = newId("split")
      splits[id] = SplitView(id: id, windowId: windowId, tabIds: panes, orientation: v.orientation, sizes: v.sizes, stack: v.stack)
      order = Groups.placeBlock(order, order.filter { panes.contains($0) })
    }
    var window = w
    window.tabIds = Groups.orderSections(pinnedFirst(order, tabs, groups), tabs, groups)
    groups = Groups.syncGroupOrder(groups, window)
    var next = s
    next.tabs = tabs
    next.groups = groups
    next.splits = splits
    next.windows[windowId] = window
    next.parkedPins.remove([profileId])
    return next
  }

  func settlePinHomes(_ s: BrowserState, _ prev: BrowserState) -> Table<Tab>? {
    if !s.tabs.changed(from: prev.tabs) && !s.groups.changed(from: prev.groups) { return nil }
    let members = s.pinnedGroupMemberSet()
    let ids = s.groups.changed(from: prev.groups) || s.windows.changed(from: prev.windows) ? s.tabs.keys : s.tabs.changedIds(from: prev.tabs)
    var tabs: Table<Tab>? = nil
    for id in ids {
      guard let t = s.tabs[id] else { continue }
      let housed = t.pinned || members.contains(id)
      let home: String? = housed ? (truthy(t.pinnedUrl) ? t.pinnedUrl : (t.url.isEmpty ? nil : t.url)) : nil
      if home == t.pinnedUrl { continue }
      if tabs == nil { tabs = s.tabs }
      var changed = t
      changed.pinnedUrl = home
      tabs![id] = changed
    }
    return tabs
  }
}
