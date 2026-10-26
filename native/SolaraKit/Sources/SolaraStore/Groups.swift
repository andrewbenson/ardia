import SolaraModel

public enum Groups {
  public static func syncGroupOrder(_ input: Table<TabGroup>, _ window: BrowserWindow) -> Table<TabGroup> {
    let groups = nestGroups(input)
    let at = positions(window.tabIds)
    var next: Table<TabGroup>? = nil
    for g in groups.values {
      if g.windowId != window.id { continue }
      var ordered = true
      for (i, id) in g.tabIds.enumerated() {
        guard let here = at[id] else {
          ordered = false
          break
        }
        if i > 0, !(here > at[g.tabIds[i - 1]]!) {
          ordered = false
          break
        }
      }
      if ordered { continue }
      let members = Set(g.tabIds)
      var changed = g
      changed.tabIds = window.tabIds.filter { members.contains($0) }
      if next == nil { next = groups }
      next![g.id] = changed
    }
    return next ?? groups
  }

  public static func orderSections(_ ids: [String], _ tabs: Table<Tab>, _ groups: Table<TabGroup>) -> [String] {
    var pinnedGroup = Set<String>()
    for g in groups.values where g.pinned { pinnedGroup.formUnion(g.tabIds) }
    func rank(_ id: String) -> Int {
      if let t = tabs[id], t.pinned { return t.pinnedAsRow == true ? 1 : 0 }
      return pinnedGroup.contains(id) ? 1 : 2
    }
    let out = [0, 1, 2].flatMap { r in ids.filter { rank($0) == r } }
    return out == ids ? ids : out
  }

  public static func insertAll(_ list: inout [String], _ at: Int, _ items: [String]) {
    let tail = list.jsSplice(at)
    list.append(contentsOf: items)
    list.append(contentsOf: tail)
  }

  public static func placeBlock(_ tabIds: [String], _ block: [String]) -> [String] {
    let members = Set(block)
    let at = tabIds.firstIndex { members.contains($0) } ?? -1
    var rest = tabIds.filter { !members.contains($0) }
    let before = tabIds.jsSliced(0, at).filter { !members.contains($0) }.count
    insertAll(&rest, before, block)
    return rest
  }

  public static func placeGroups(_ input: [String], _ groups: Table<TabGroup>, _ windowId: String) -> [String] {
    var tabIds = input
    let own = groups.values.filter { $0.windowId == windowId }.map { ($0, depthOf(groups, $0.id)) }.stableSorted { $0.1 < $1.1 }
    var at = positions(tabIds)
    for (g, _) in own {
      let spots = g.tabIds.compactMap { at[$0] }
      guard !spots.isEmpty else { continue }
      let low = spots.min()!
      let high = spots.max()!
      if high - low + 1 == spots.count { continue }
      let members = Set(g.tabIds)
      tabIds = placeBlock(tabIds, tabIds.filter { members.contains($0) })
      at = positions(tabIds)
    }
    return tabIds
  }

  static func positions(_ ids: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    for (i, id) in ids.enumerated() { out[id] = i }
    return out
  }

  public static func leaveGroups(_ groups: Table<TabGroup>, _ ids: Set<String>, keep: Set<String>? = nil) -> Table<TabGroup> {
    let touched = groups.values.contains { g in !(keep?.contains(g.id) ?? false) && g.tabIds.contains { ids.contains($0) } }
    if !touched { return groups }
    var next = JSMap<TabGroup>()
    for g in groups.values {
      let tabIds = keep?.contains(g.id) == true ? g.tabIds : g.tabIds.filter { !ids.contains($0) }
      if tabIds.count == g.tabIds.count {
        next[g.id] = g
      } else if tabIds.count > (g.autoUngroup == true && g.pinnedOpenerId == nil ? 1 : 0) {
        var changed = g
        changed.tabIds = tabIds
        next[g.id] = changed
      }
    }
    var out = groups
    out.replace(with: next)
    return reparent(out, groups)
  }

  public static func reparent(_ input: Table<TabGroup>, _ was: Table<TabGroup>) -> Table<TabGroup> {
    var next = input
    for g in input.values {
      guard let parent = g.parentId, next[parent] == nil else { continue }
      var up = was[parent]?.parentId
      while let candidate = up, next[candidate] == nil { up = was[candidate]?.parentId }
      next[g.id] = withParent(next[g.id] ?? g, up)
    }
    return next
  }

  public static func withParent(_ g: TabGroup, _ parentId: String?) -> TabGroup {
    if g.parentId == parentId { return g }
    var next = g
    next.parentId = parentId
    return next
  }

  static func ancestorList(_ groups: Table<TabGroup>, _ id: String) -> [String] {
    var seen: [String] = []
    var seenSet = Set<String>()
    var g = groups[id]
    while let current = g, let parent = current.parentId, groups[parent] != nil, !seenSet.contains(parent) {
      seen.append(parent)
      seenSet.insert(parent)
      g = groups[parent]
    }
    return seen
  }

  public static func depthOf(_ groups: Table<TabGroup>, _ id: String) -> Int { ancestorList(groups, id).count }

  public static func ancestorIds(_ groups: Table<TabGroup>, _ id: String) -> [String] { ancestorList(groups, id) }

  public static func rootOf(_ groups: Table<TabGroup>, _ id: String) -> TabGroup? {
    groups[ancestorIds(groups, id).last ?? id]
  }

  public static func descendantIds(_ groups: Table<TabGroup>, _ id: String) -> [String] {
    var children = OrderedDict<String, [String]>()
    for g in groups.values { if let parent = g.parentId { children[parent, default: []].append(g.id) } }
    var seen: Set<String> = [id]
    var out: [String] = []
    func walk(_ parent: String) {
      for child in children[parent] ?? [] {
        if seen.contains(child) { continue }
        seen.insert(child)
        out.append(child)
        walk(child)
      }
    }
    walk(id)
    return out
  }

  public static func commonGroup(_ groups: Table<TabGroup>, _ ids: [String]) -> TabGroup? {
    var best: TabGroup? = nil
    var bestDepth = -1
    for g in groups.values {
      if !ids.allSatisfy({ g.tabIds.contains($0) }) { continue }
      let depth = g.parentId != nil ? depthOf(groups, g.id) : 0
      if depth <= bestDepth { continue }
      best = g
      bestDepth = depth
    }
    return best
  }

  public static func innermostGroupOf(_ groups: Table<TabGroup>, _ tabId: String) -> TabGroup? {
    commonGroup(groups, [tabId])
  }

  public static func groupPath(_ groups: Table<TabGroup>, _ id: String) -> [String] {
    ancestorIds(groups, id).reversed() + [id]
  }

  public static func canNest(_ groups: Table<TabGroup>, _ groupId: String, _ parentId: String) -> Bool {
    guard let g = groups[groupId], let p = groups[parentId], groupId != parentId, g.windowId == p.windowId, g.profileId == p.profileId else {
      return false
    }
    return !ancestorIds(groups, parentId).contains(groupId)
  }

  final class Lineage {
    let groups: Table<TabGroup>
    var above: [String: [String]] = [:]

    init(_ groups: Table<TabGroup>) {
      self.groups = groups
    }

    func of(_ id: String) -> [String] {
      if let known = above[id] { return known }
      var chain: [String] = []
      var at: String? = id
      while let current = at, groups[current] != nil, above[current] == nil, !chain.contains(current) {
        chain.append(current)
        at = groups[current]!.parentId
      }
      var up: [String] = []
      if let current = at, let known = above[current] { up = [current] + known }
      for g in chain.reversed() {
        above[g] = up
        up = [g] + up
      }
      return above[id] ?? []
    }

    func contains(_ id: String, _ ancestor: String) -> Bool { of(id).contains(ancestor) }
  }

  public static func nestGroups(_ groups: Table<TabGroup>) -> Table<TabGroup> {
    let all = groups.values
    if !all.contains(where: { $0.parentId != nil }) { return groups }
    var next: Table<TabGroup>? = nil
    func edit(_ g: TabGroup) {
      if next == nil { next = groups }
      next![g.id] = g
    }
    func cur(_ id: String) -> TabGroup { (next ?? groups)[id]! }
    let ancestorsBefore = Lineage(groups)
    for g in all {
      guard let parentId = g.parentId else { continue }
      let p = groups[parentId]
      let broken = p == nil || p!.windowId != g.windowId || p!.profileId != g.profileId || ancestorsBefore.contains(parentId, g.id)
      if broken { edit(withParent(cur(g.id), nil)) }
    }
    let ancestors = Lineage(next ?? groups)
    let byDepth = (next ?? groups).values.filter { $0.parentId != nil }.map { ($0.id, ancestors.of($0.id).count) }.stableSorted { $0.1 > $1.1 }
    for (id, _) in byDepth {
      let g = cur(id)
      var p = cur(g.parentId!)
      let has = Set(p.tabIds)
      let missing = g.tabIds.filter { !has.contains($0) }
      if !missing.isEmpty {
        p.tabIds += missing
        edit(p)
      }
    }
    for (id, _) in byDepth.reversed() {
      var g = cur(id)
      let pinned = cur(g.parentId!).pinned
      if g.pinned != pinned {
        g.pinned = pinned
        edit(g)
      }
    }
    var holders = OrderedDict<String, [String]>()
    for g in (next ?? groups).values { for t in g.tabIds { holders[t, default: []].append(g.id) } }
    var leaving = OrderedDict<String, OrderedSet<String>>()
    for (t, ids) in holders {
      if ids.count < 2 { continue }
      let deepest = ids.dropFirst().reduce(ids[0]) { a, z in ancestors.of(z).count > ancestors.of(a).count ? z : a }
      let chain = Set(ancestors.of(deepest))
      for id in ids where id != deepest && !chain.contains(id) { leaving[id, default: OrderedSet()].insert(t) }
    }
    for (id, gone) in leaving {
      var g = cur(id)
      g.tabIds = g.tabIds.filter { !gone.contains($0) }
      edit(g)
    }
    let settled = next ?? groups
    let emptied = settled.values.filter { $0.tabIds.isEmpty && !(groups[$0.id]?.tabIds.isEmpty ?? true) }
    if emptied.isEmpty { return settled }
    var kept = settled
    kept.remove(emptied.map(\.id))
    return reparent(kept, settled)
  }

  public static func closedGroupInfo(_ g: TabGroup) -> ClosedGroupInfo {
    var info = ClosedGroupInfo(id: g.id, name: g.name, icon: g.icon, color: g.color, pinned: g.pinned ? true : nil)
    info.absent = g.absent.intersection(lookKeys)
    return info
  }

  public static func settleNesting(_ s: BrowserState) -> (groups: Table<TabGroup>, windows: Table<BrowserWindow>)? {
    if !s.groups.values.contains(where: { $0.parentId != nil }) { return nil }
    var groups = nestGroups(s.groups)
    var windows = s.windows
    let windowIds = OrderedSet(groups.values.filter { $0.parentId != nil }.map(\.windowId))
    for windowId in windowIds {
      guard let w = windows[windowId] else { continue }
      let tabIds = orderSections(placeGroups(w.tabIds, groups, windowId), s.tabs, groups)
      var window = w
      if tabIds != w.tabIds {
        window.tabIds = tabIds
        windows[windowId] = window
      }
      groups = syncGroupOrder(groups, window)
    }
    return !groups.changed(from: s.groups) && !windows.changed(from: s.windows) ? nil : (groups, windows)
  }

  public static func withGroupsPlaced(_ s: BrowserState, _ windowId: String, _ groups: Table<TabGroup>) -> BrowserState {
    let w = s.windows[windowId]!
    let tabIds = orderSections(placeGroups(w.tabIds, groups, windowId), s.tabs, groups)
    var window = w
    var next = s
    if tabIds != w.tabIds {
      window.tabIds = tabIds
    }
    next.windows[windowId] = window
    next.groups = syncGroupOrder(groups, window)
    return next
  }
}

extension Session {
  func rejoinGroups(_ input: Table<TabGroup>, _ chain: [ClosedGroupInfo], _ tabIds: [String], _ windowId: String, _ profileId: String,
    made: inout [String: String]) -> Table<TabGroup>
  {
    let groups = input
    func here(_ info: ClosedGroupInfo) -> TabGroup? {
      guard let g = groups[made[info.id] ?? info.id], g.windowId == windowId, g.profileId == profileId else { return nil }
      return g
    }
    let at = chain.firstIndex { here($0) != nil } ?? -1
    var next = groups
    next.touch()
    var parentId: String? = nil
    if at >= 0 {
      var g = here(chain[at])!
      g.tabIds += tabIds.filter { !g.tabIds.contains($0) }
      next[g.id] = g
      parentId = g.id
    }
    for info in chain.jsSliced(0, at < 0 ? chain.count : at).reversed() {
      let id = next[info.id] != nil ? newId("g") : info.id
      var g = TabGroup(
        id: id, windowId: windowId, profileId: profileId, name: info.name, icon: info.icon, color: info.color, collapsed: false,
        pinned: info.pinned == true, tabIds: tabIds, createdAt: now)
      g.setLook(icon: info.icon, color: info.color, absent: info.absent)
      g.parentId = parentId
      next[id] = g
      made[info.id] = id
      parentId = id
    }
    return Groups.nestGroups(next)
  }
}
