import SolaraModel

struct SectionItem {
  let uid: Int
  var tab: Tab
  var group: String?
}

struct SectionGroup {
  var group: TabGroup
  var parent: String?
}

struct PinnedSplit {
  var keys: [String]
  var orientation: String
  var sizes: [Double]
  var stack: SplitStack?
}

struct Section {
  var items: [SectionItem] = []
  var groups = OrderedDict<String, SectionGroup>()
  var own: [TabGroup] = []
  var duplicate = false
  var splits: [PinnedSplit]? = nil
}

func homeOf(_ t: Tab) -> String { truthy(t.pinnedUrl) ? t.pinnedUrl! : t.url }
func isTile(_ t: Tab) -> Bool { t.pinned && t.pinnedAsRow != true }
func mirrored(_ w: BrowserWindow?) -> Bool {
  guard let w else { return false }
  return !w.incognito && !w.isSmall
}

func pinnedGroupsOf(_ s: BrowserState) -> [TabGroup] { s.groups.values.filter(\.pinned) }

func chainOf(_ x: Section, _ key: String?) -> [String] {
  var out: [String] = []
  var k = key
  while let current = k, x.groups[current] != nil, !out.contains(current) {
    out.insert(current, at: 0)
    k = x.groups[current]!.parent
  }
  return out
}

func numberText(_ value: Double?) -> String { value.map(jsNumberText) ?? "" }

func tileSig(_ t: Tab) -> String {
  [
    t.pinKeyOrId, t.pinnedUrl ?? "", t.customTitle ?? "", t.customIcon ?? "", t.pinnedAsRow == true ? "r" : "", t.tileFolder?.id ?? "",
    t.tileFolder?.name ?? "", numberText(t.tileFolder?.renamedAt),
  ].joined(separator: "\u{1}")
}

func memberSig(_ t: Tab) -> String {
  [t.pinKeyOrId, t.pinnedUrl ?? "", t.customTitle ?? "", t.customIcon ?? ""].joined(separator: "\u{1}")
}

func splitSig(_ v: PinnedSplit) -> String {
  "S\(v.keys.joined(separator: "\u{3}"))\u{1}\(v.orientation)\u{1}\(v.stack.map { String($0.index) } ?? "")"
}

func signature(_ x: Section) -> String {
  var shown = Set<String>()
  var lines: [String] = []
  for item in x.items {
    for key in chainOf(x, item.group) {
      if shown.contains(key) { continue }
      shown.insert(key)
      let entry = x.groups[key]!
      let g = entry.group
      lines.append("G\(key)\u{1}\(g.name)\u{1}\(g.icon ?? "")\u{1}\(g.color ?? "")\u{1}\(entry.parent ?? "")")
    }
    lines.append(item.group.map { "\(memberSig(item.tab))\u{2}\($0)" } ?? tileSig(item.tab))
  }
  if let splits = x.splits { lines.append(contentsOf: splits.map(splitSig).jsSortedStrings()) }
  return lines.joined(separator: "\n")
}

func profilesOf(_ s: BrowserState, _ w: BrowserWindow) -> OrderedSet<String> {
  var out = OrderedSet<String>()
  for id in w.tabIds {
    if let p = s.tabs[id]?.profileId, !Ids.isIncognitoProfile(p) { out.insert(p) }
  }
  return out
}

func hasDuplicates(_ x: Section) -> Bool {
  let keys = x.items.map(\.tab.pinKeyOrId)
  return x.duplicate || Set(keys).count < keys.count
}

func spreadGroup(_ base: TabGroup, _ over: TabGroup?) -> TabGroup {
  guard let over else { return base }
  var out = over
  if out.autoUngroup == nil { out.autoUngroup = base.autoUngroup }
  if out.pinnedOpenerId == nil { out.pinnedOpenerId = base.pinnedOpenerId }
  if out.pinKey == nil { out.pinKey = base.pinKey }
  if out.parentId == nil { out.parentId = base.parentId }
  for (key, value) in base.extra where out.extra[key] == nil { out.extra[key] = value }
  return out
}

func keyField(_ t: inout Tab, _ key: String) { t.pinKey = t.id == key ? nil : key }
func keyField(_ g: inout TabGroup, _ key: String) { g.pinKey = g.id == key ? nil : key }

extension Session {
  func nextItemUid() -> Int {
    itemSerial += 1
    return itemSerial
  }

  func innermostPinned(_ s: BrowserState, _ own: [TabGroup]) -> [String: TabGroup] {
    var inner: [String: TabGroup] = [:]
    for g in own.map({ ($0, Groups.depthOf(s.groups, $0.id)) }).stableSorted(by: { $0.1 < $1.1 }).map(\.0) {
      for id in g.tabIds { inner[id] = g }
    }
    return inner
  }

  func pinnedChain(_ s: BrowserState, _ g: TabGroup, _ ownIds: Set<String>) -> [TabGroup] {
    Groups.ancestorIds(s.groups, g.id).filter { ownIds.contains($0) }.reversed().map { s.groups[$0]! } + [g]
  }

  func sectionOf(_ s: BrowserState, _ w: BrowserWindow, _ profileId: String, _ pinnedGroups: [TabGroup], member: ((Tab) -> Bool)? = nil) -> Section {
    let mine = pinnedGroups.filter { $0.windowId == w.id && $0.profileId == profileId }
    let ownIds = Set(mine.map(\.id))
    let inner = innermostPinned(s, mine)
    var x = Section()
    var owned = Set<String>()
    for id in w.tabIds {
      guard let t = s.tabs[id], t.profileId == profileId else { continue }
      let g = t.pinned ? nil : inner[id]
      if let member { if !member(t) { continue } } else if !t.pinned && g == nil { continue }
      if let g {
        for c in pinnedChain(s, g, ownIds) {
          if owned.contains(c.id) { continue }
          owned.insert(c.id)
          let key = c.pinKeyOrId
          if x.groups[key] != nil {
            x.duplicate = true
          } else {
            let p = c.parentId.flatMap { ownIds.contains($0) ? s.groups[$0] : nil }
            x.groups[key] = SectionGroup(group: c, parent: p?.pinKeyOrId)
          }
          x.own.append(c)
        }
      }
      x.items.append(SectionItem(uid: nextItemUid(), tab: t, group: g?.pinKeyOrId))
    }
    return x
  }

  func withSplits(_ s: BrowserState, _ w: BrowserWindow, _ input: Section) -> Section {
    var x = input
    var keyOf: [String: String] = [:]
    for item in x.items where !isTile(item.tab) { keyOf[item.tab.id] = item.tab.pinKeyOrId }
    x.splits = s.splits.values.filter { v in v.windowId == w.id && v.tabIds.allSatisfy { keyOf[$0] != nil } }.map { v in
      PinnedSplit(keys: v.tabIds.map { keyOf[$0]! }, orientation: v.orientation, sizes: v.sizes, stack: v.stack)
    }
    return x
  }

  func pinnedSplitsChanged(_ s: BrowserState, _ prev: BrowserState) -> Bool {
    if !s.splits.changed(from: prev.splits) { return false }
    let members = Set(pinnedGroupsOf(s).flatMap(\.tabIds))
    func pinnedPane(_ id: String) -> Bool { s.tabs[id]?.pinned == true || prev.tabs[id]?.pinned == true || members.contains(id) }
    return (s.splits.values + prev.splits.values).contains { $0.tabIds.contains(where: pinnedPane) }
  }

  func pinsMayDiffer(_ s: BrowserState, _ prev: BrowserState) -> Bool {
    if s.windows.changed(from: prev.windows) || s.groups.changed(from: prev.groups) || pinnedSplitsChanged(s, prev) { return true }
    if !s.tabs.changed(from: prev.tabs) { return false }
    var members: Set<String>? = nil
    for id in s.tabs.changedIds(from: prev.tabs) {
      let a = s.tabs[id]
      let b = prev.tabs[id]
      guard let a, let b else {
        if a?.pinned == true || b?.pinned == true { return true }
        if members == nil { members = Set(pinnedGroupsOf(s).flatMap(\.tabIds)) }
        if members!.contains(id) { return true }
        continue
      }
      if a.pinned != b.pinned || a.pinnedUrl != b.pinnedUrl || a.pinnedAsRow != b.pinnedAsRow || a.tileFolder != b.tileFolder
        || a.customTitle != b.customTitle || a.customIcon != b.customIcon || a.profileId != b.profileId || a.windowId != b.windowId
        || a.pinKey != b.pinKey
      {
        return true
      }
    }
    return false
  }

  func union(_ sections: [Section], samePages: Bool = true) -> Section {
    var spec = Section()
    var keys = Set<String>()
    func within(_ item: SectionItem, _ key: String) -> Bool { chainOf(spec, item.group).contains(key) }
    func lastIn(_ key: String) -> Int { spec.items.lastIndex { within($0, key) } ?? -1 }
    for x in sections {
      let earlier = spec.items.filter { $0.group == nil }.map(\.tab)
      let paired = Set((x.splits ?? []).flatMap(\.keys))
      for (key, g) in x.groups where spec.groups[key] == nil { spec.groups[key] = g }
      var anchor = -1
      for item in x.items {
        let key = item.tab.pinKeyOrId
        if keys.contains(key) {
          anchor = spec.items.firstIndex { $0.tab.pinKeyOrId == key } ?? -1
          continue
        }
        if samePages, item.group == nil, !paired.contains(key), earlier.contains(where: { samePage(homeOf($0), homeOf(item.tab)) }) { continue }
        keys.insert(key)
        let host = chainOf(spec, item.group).reversed().first { lastIn($0) >= 0 }
        let at: Int
        if let host {
          at = anchor >= 0 && within(spec.items[anchor], host) ? anchor : lastIn(host)
        } else if anchor >= 0 {
          at = anchor
        } else if item.group != nil {
          at = spec.items.count - 1
        } else {
          at = spec.items.lastIndex { $0.group == nil } ?? -1
        }
        spec.items.jsSplice(at + 1, 0, [item])
        anchor = at + 1
      }
      if x.splits != nil, spec.splits == nil { spec.splits = [] }
      for v in x.splits ?? [] where !spec.splits!.contains(where: { u in u.keys.contains { v.keys.contains($0) } }) { spec.splits!.append(v) }
    }
    return spec
  }

  enum TreeNode {
    case item(SectionItem)
    case group(String)
  }

  func treeOrder(_ x: Section) -> [SectionItem] {
    var kids = OrderedDict<String?, [TreeNode]>()
    var seen = Set<String>()
    for item in x.items {
      let chain = chainOf(x, item.group)
      kids[chain.last, default: []].append(.item(item))
      var i = chain.count - 1
      while i >= 0, !seen.contains(chain[i]) {
        seen.insert(chain[i])
        kids[i > 0 ? chain[i - 1] : nil, default: []].append(.group(chain[i]))
        i -= 1
      }
    }
    func flat(_ parent: String?) -> [SectionItem] {
      (kids[parent] ?? []).flatMap { node -> [SectionItem] in
        switch node {
        case .group(let key): flat(key)
        case .item(let item): [item]
        }
      }
    }
    return flat(nil)
  }

  func copyOf(_ src: Tab, _ windowId: String, _ tile: Bool) -> Tab {
    let url = tile ? homeOf(src) : src.url
    let atSource = samePage(src.url, url)
    var patch = TabPatch()
    patch.title = atSource ? src.title : ""
    patch.favicon = .some(atSource ? src.favicon : nil)
    patch.pinned = tile
    let pinnedUrl = truthy(src.pinnedUrl) ? src.pinnedUrl : (tile && !src.url.isEmpty ? src.url : nil)
    patch.pinnedUrl = .some(pinnedUrl)
    if tile && src.pinnedAsRow == true { patch.pinnedAsRow = .some(true) }
    if tile && src.pinnedAsRow != true, let folder = src.tileFolder { patch.tileFolder = .some(folder) }
    patch.customTitle = .some(src.customTitle)
    patch.customIcon = .some(src.customIcon)
    patch.muted = src.muted
    patch.zoom = src.zoom
    var tab = makeTab(windowId, src.profileId, url, patch)
    tab.pinKey = src.pinKeyOrId
    tab.navigation = nil
    tab.unloaded = true
    return tab
  }

  func conform(_ s: BrowserState, _ windowId: String, _ profileId: String, _ spec: Section) -> BrowserState {
    let w = s.windows[windowId]!
    let cur = sectionOf(s, w, profileId, pinnedGroupsOf(s))
    let mine = cur.items.map(\.tab)
    var used = Set<String>()
    var tabs = s.tabs
    tabs.touch()
    var groups = s.groups
    groups.touch()
    let wantedKeys = Set(spec.items.map(\.tab.pinKeyOrId))
    var byKey = OrderedDict<String, [Tab]>()
    for m in mine { byKey[m.pinKeyOrId, default: []].append(m) }
    func reuse(_ src: Tab, _ tile: Bool) -> String {
      let key = src.pinKeyOrId
      let same = (byKey[key] ?? []).filter { !used.contains($0.id) }
      var t = same.first(where: hasPage) ?? same.first
      if t == nil && tile {
        t = mine.first { m in m.pinned && !used.contains(m.id) && !wantedKeys.contains(m.pinKeyOrId) && samePage(homeOf(m), homeOf(src)) }
      }
      guard var t else {
        let copy = copyOf(src, windowId, tile)
        tabs[copy.id] = copy
        used.insert(copy.id)
        return copy.id
      }
      used.insert(t.id)
      let original = t
      keyField(&t, key)
      t.pinned = tile
      t.pinnedAsRow = tile && src.pinnedAsRow == true ? true : nil
      t.tileFolder = tile && src.pinnedAsRow != true ? src.tileFolder : nil
      t.customTitle = src.customTitle
      t.customIcon = src.customIcon
      t.pinnedUrl = truthy(src.pinnedUrl) ? src.pinnedUrl : (tile && !src.url.isEmpty ? src.url : nil)
      if tile && !hasPage(original) && !samePage(original.url, homeOf(src)) {
        t.url = homeOf(src)
        t.title = src.title
        t.favicon = src.favicon
      }
      tabs[t.id] = t
      return t.id
    }
    let order = treeOrder(spec)
    var local: [Int: String] = [:]
    var tileIds: [(SectionItem, String)] = []
    for i in order where i.group == nil {
      let id = reuse(i.tab, true)
      local[i.uid] = id
      tileIds.append((i, id))
    }
    var memberIds: [(SectionItem, String)] = []
    for i in order where i.group != nil {
      let id = reuse(i.tab, false)
      local[i.uid] = id
      memberIds.append((i, id))
    }
    let placedIds = order.map { local[$0.uid]! }
    var within = OrderedDict<String, [String]>()
    for i in order { for key in chainOf(spec, i.group) { within[key, default: []].append(local[i.uid]!) } }
    var usedGroups = Set<String>()
    var groupIdOf: [String: String] = [:]
    for key in within.keys {
      let entry = spec.groups[key]!
      let src = entry.group
      let own = cur.own.first { !usedGroups.contains($0.id) && $0.pinKeyOrId == key }
      let id = own?.id ?? newId("g")
      usedGroups.insert(id)
      groupIdOf[key] = id
      var g =
        own
        ?? TabGroup(
          id: id, windowId: windowId, profileId: profileId, name: "", icon: nil, color: nil, collapsed: src.collapsed, pinned: true, tabIds: [],
          createdAt: now)
      keyField(&g, key)
      g.name = src.name
      g.icon = src.icon
      g.color = src.color
      g.pinned = true
      g.tabIds = within[key]!
      groups[id] = Groups.withParent(g, entry.parent.flatMap { groupIdOf[$0] })
    }
    let shown = Set(w.activeTabIds.values)
    let leaving = mine.filter { !used.contains($0.id) }
    let demoted = leaving.filter { hasPage($0) || shown.contains($0.id) }.map(\.id)
    let stays = Set(demoted)
    let gone = leaving.filter { !stays.contains($0.id) }.map(\.id)
    for id in demoted {
      var t = tabs[id]!
      t.pinned = false
      t.pinnedUrl = nil
      t.pinnedAsRow = nil
      t.tileFolder = nil
      t.pinKey = nil
      tabs[id] = t
    }
    var kept = OrderedSet<String>()
    for group in cur.own {
      if usedGroups.contains(group.id) { continue }
      let left = group.tabIds.filter { stays.contains($0) }
      if !left.isEmpty {
        var g = group
        g.pinned = false
        g.pinKey = nil
        g.tabIds = left
        groups[group.id] = g
        kept.insert(group.id)
      } else {
        groups.remove([group.id])
      }
    }
    for id in kept {
      if let parent = groups[id]!.parentId, !kept.contains(parent) { groups[id] = Groups.withParent(groups[id]!, nil) }
    }
    let section = Set(mine.map(\.id) + placedIds)
    var ids = placedIds + demoted + w.tabIds.filter { !section.contains($0) }
    var splits = s.splits
    if let specSplits = spec.splits {
      var paneOf: [String: String] = [:]
      for (i, id) in tileIds + memberIds where !isTile(i.tab) { paneOf[i.tab.pinKeyOrId] = id }
      let panes = Set(paneOf.values)
      let wanted = specSplits.map { v in (v, v.keys.map { paneOf[$0] ?? "" }) }.filter { $0.1.allSatisfy { !$0.isEmpty } }
      func same(_ v: SplitView, _ x: (PinnedSplit, [String])) -> Bool {
        v.tabIds.joined(separator: ",") == x.1.joined(separator: ",") && v.orientation == x.0.orientation && v.stack?.index == x.0.stack?.index
      }
      let stale = splits.values.filter { v in v.windowId == windowId && v.tabIds.allSatisfy { panes.contains($0) } && !wanted.contains { same(v, $0) } }
      if !stale.isEmpty { splits.remove(stale.map(\.id)) }
      for x in wanted {
        if !splits.values.contains(where: { same($0, x) }) {
          let id = newId("split")
          splits = Splits.removeFromSplits(splits, Set(x.1))
          splits[id] = SplitView(id: id, windowId: windowId, tabIds: x.1, orientation: x.0.orientation, sizes: x.0.sizes, stack: x.0.stack)
        }
        ids = Groups.placeBlock(ids, ids.filter { x.1.contains($0) })
      }
    }
    var window = w
    window.tabIds = Groups.orderSections(pinnedFirst(ids, tabs, groups), tabs, groups)
    groups = Groups.syncGroupOrder(groups, window)
    var next = s
    next.tabs = tabs
    next.groups = groups
    next.splits = splits
    next.windows[windowId] = window
    return gone.isEmpty ? next : removeTabs(next, gone, record: false)
  }

  func mirrorPins(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    if !pinsMayDiffer(s, prev) { return nil }
    let order = OrderedSet(s.ui.focusOrder + s.windowOrder).elements.filter { mirrored(s.windows[$0]) }
    var byProfile = OrderedDict<String, [String]>()
    for id in order { for p in profilesOf(s, s.windows[id]!) { byProfile[p, default: []].append(id) } }
    var next = s
    var changed = false
    for (profileId, ids) in byProfile {
      for id in ids {
        guard let w = next.windows[id] else { continue }
        let x = withSplits(next, w, sectionOf(next, w, profileId, pinnedGroupsOf(next)))
        if hasDuplicates(x) {
          next = conform(next, id, profileId, union([x]))
          changed = true
        }
      }
    }
    let nowGroups = pinnedGroupsOf(next)
    let prevGroups = pinnedGroupsOf(prev)
    for (profileId, ids) in byProfile {
      if ids.count < 2 { continue }
      var sections: [String: Section] = [:]
      for id in ids {
        guard let w = next.windows[id] else { continue }
        sections[id] = withSplits(next, w, sectionOf(next, w, profileId, nowGroups))
      }
      var sigs: [String: String] = [:]
      for id in ids { if let x = sections[id] { sigs[id] = signature(x) } }
      if Set(ids.map { sigs[$0] ?? "" }).count == 1 { continue }
      let before = ids.filter { id in mirrored(prev.windows[id]) && profilesOf(prev, prev.windows[id]!).contains(profileId) }
      let source = before.first { id in
        signature(withSplits(prev, prev.windows[id]!, sectionOf(prev, prev.windows[id]!, profileId, prevGroups))) != sigs[id]
      }
      let spec = source.map { sections[$0]! } ?? union((before + ids.filter { !before.contains($0) }).compactMap { sections[$0] })
      let want = source.map { sigs[$0]! }
      for id in ids {
        if id == source || (want != nil && sigs[id] == want) || next.windows[id] == nil { continue }
        next = conform(next, id, profileId, spec)
        changed = true
      }
    }
    return changed ? next : nil
  }

  func settleMovedPins(_ before: BrowserState, _ after: BrowserState, _ moved: [String], _ targetId: String) -> BrowserState {
    if !mirrored(after.windows[targetId]) { return after }
    let memberOf = innermostPinned(before, pinnedGroupsOf(before))
    let pins = moved.compactMap { before.tabs[$0] }.filter { t in
      (t.pinned || memberOf[t.id] != nil || sharedListTab(before, t)) && t.windowId != targetId && after.tabs[t.id]?.windowId == targetId
    }
    if pins.isEmpty { return after }
    var tabs = after.tabs
    tabs.touch()
    var windows = after.windows
    windows.touch()
    var groups = after.groups
    groups.touch()
    for sourceId in OrderedSet(pins.map(\.windowId)) {
      guard let src = windows[sourceId], mirrored(src), mirrored(before.windows[sourceId]) else { continue }
      var swap = OrderedDict<String, String>()
      let shown = before.windows[sourceId]!.activeTabIds
      var activeTabIds = src.activeTabIds
      var activeChanged = false
      for t in pins where t.windowId == sourceId {
        let copy = copyOf(t, sourceId, t.pinned)
        tabs[copy.id] = copy
        swap[t.id] = copy.id
        if shown[t.profileId] == t.id && !t.pinned && memberOf[t.id] == nil {
          activeTabIds[t.profileId] = copy.id
          activeChanged = true
        }
      }
      let present = Set(src.tabIds + swap.values)
      func keep(_ ids: [String]) -> [String] { ids.map { swap[$0] ?? $0 }.filter { present.contains($0) } }
      for g in sharesTabs(before) ? before.groups.values : pinnedGroupsOf(before) {
        if g.windowId == sourceId && g.tabIds.contains(where: { swap[$0] != nil }) {
          var merged = spreadGroup(g, groups[g.id])
          merged.tabIds = keep(g.tabIds)
          groups[g.id] = merged
        }
      }
      var window = src
      window.tabIds = pinnedFirst(keep(before.windows[sourceId]!.tabIds), tabs, groups)
      if activeChanged { window.activeTabIds = activeTabIds }
      windows[sourceId] = window
    }
    let target = windows[targetId]!
    var tabIds = target.tabIds
    var gone: [String] = []
    for m in pins {
      guard let g = memberOf[m.id] else { continue }
      let own = groups.values.first { x in x.pinned && x.windowId == targetId && x.profileId == m.profileId && x.pinKeyOrId == g.pinKeyOrId }
      let copy = own?.tabIds.first { id in tabs[id].map { $0.pinKeyOrId == m.pinKeyOrId } ?? false }
      guard let own, let copy else { continue }
      _ = own
      for x in groups.values where x.windowId == targetId && x.tabIds.contains(copy) {
        var changed = x
        changed.tabIds = x.tabIds.map { $0 == copy ? m.id : $0 }
        groups[x.id] = changed
      }
      tabIds = tabIds.filter { $0 != m.id }
      if let at = tabIds.firstIndex(of: copy) { tabIds[at] = m.id }
      if hasPage(tabs[copy]!) || target.activeTabIds.values.contains(copy) {
        var t = tabs[copy]!
        t.pinKey = nil
        tabs[copy] = t
        tabIds.append(copy)
      } else {
        gone.append(copy)
      }
    }
    var window = target
    window.tabIds = Groups.orderSections(pinnedFirst(tabIds, tabs, groups), tabs, groups)
    windows[targetId] = window
    var next = after
    next.tabs = tabs
    next.windows = windows
    next.groups = groups
    return gone.isEmpty ? next : removeTabs(next, gone, record: false)
  }
}
