import SolaraModel

struct PinSlot {
  var id: String
  var group: Bool
  var pos: JSONValue?
  var chain: [String] = []
}

func slotOrder(_ a: PinSlot, _ z: PinSlot) -> Double {
  if jsLess(a.pos, z.pos) { return -1 }
  if jsLess(z.pos, a.pos) { return 1 }
  return jsKeyPrecedes(a.id, z.id) ? -1 : 1
}

func or(_ a: JSONValue?, _ b: @autoclosure () -> JSONValue?) -> JSONValue? { truthy(a) ? a : b() }

func lookPatch(_ v: JSONValue?, _ key: String, into patch: inout TabPatch) {
  let value = v?[key]
  let field: String = key == "t" ? "customTitle" : "customIcon"
  let text: String?? = .some(value?.string)
  if field == "customTitle" { patch.customTitle = text } else { patch.customIcon = text }
  if value == nil { patch.undefined.insert(field) }
}

func keepUnseenMembers(_ wanted: [String], _ local: [String], _ unseen: (String) -> Bool) -> [String] {
  var out = wanted
  var after = -1
  for id in local {
    if let at = out.firstIndex(of: id) {
      after = at
    } else if unseen(id) {
      after += 1
      out.insert(id, at: after)
    }
  }
  return out
}

extension Session {
  func carryNullable(_ copy: inout Tab, _ from: Tab, _ keys: Set<String>) {
    copy.markAbsent(from.absent.intersection(keys))
  }

  public func applySyncedPins(
    _ profileId: String, _ visibleList: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?,
    known recordKnown: (String) -> Bool, now recordsNow: Double, horizon: Double
  ) -> Bool? {
    let rowPrefix = PinnedSync.row
    let nestPrefix = PinnedSync.nest
    if changed.allSatisfy({ starts($0, rowPrefix) }) { return true }
    let visible = uniqueVisible(visibleList)
    func pinItem(_ k: String) -> Bool { starts(k, "pin:t:") || starts(k, "pin:g:") || starts(k, "\(nestPrefix)g:") }
    if changed.contains(where: { pinItem($0) && visible[$0] == nil }) { noteRemotePinDeletion(profileId) }
    let sync = state.pinSync[profileId] ?? JSMap()
    var s = state
    guard let home = pinnedHomeWindow(s, profileId) else { return false }
    func marked(_ key: String) -> Bool { base("\(rowPrefix)\(key)") == .number(1) }
    let park = "park:\(profileId)"
    let shown = home.tabIds.contains { s.tabs[$0]?.profileId == profileId }
    if s.parkedPins[profileId] != nil || !shown {
      s.windows[park] = BrowserWindow(id: park, profileId: profileId, incognito: false, frame: nil, createdAt: 0)
      if s.parkedPins[profileId] != nil { s = adoptParkedPins(s, park, profileId) }
    }
    let newPinWindow = shown ? home.id : park
    let scope = [home.id, park]
    var tabOfKey: [String: String] = [:]
    var groupOfKey: [String: String] = [:]
    let pinnedMember = Set(s.groups.values.filter { $0.pinned && $0.profileId == profileId }.flatMap(\.tabIds))
    let searchOrder = scope + s.windows.keys.filter { !scope.contains($0) }
    var kept = OrderedDict<String, Tab>()
    for wid in searchOrder {
      for id in s.windows[wid]?.tabIds ?? [] {
        guard let t = s.tabs[id], t.profileId == profileId else { continue }
        if t.pinned || pinnedMember.contains(id) {
          if tabOfKey[t.pinKeyOrId] == nil { tabOfKey[t.pinKeyOrId] = id }
        } else if let pinKey = t.pinKey, !pinKey.isEmpty {
          let other = kept[pinKey]
          if other == nil || (!hasPage(other!) && hasPage(t)) { kept[pinKey] = t }
        }
      }
    }
    for (key, t) in kept where tabOfKey[key] == nil { tabOfKey[key] = t.id }
    for g in s.groups.values where g.pinned && g.profileId == profileId && scope.contains(g.windowId) && groupOfKey[g.pinKeyOrId] == nil {
      groupOfKey[g.pinKeyOrId] = g.id
    }
    var keyOfLocal: [String: String] = [:]
    func tid(_ key: String) -> String {
      if let known = tabOfKey[key], !known.isEmpty { return known }
      let taken = s.tabs[key].map { $0.profileId != profileId } ?? false
      let id = taken ? newId("tab") : key
      tabOfKey[key] = id
      if id != key { keyOfLocal[id] = key }
      return id
    }
    func gidText(_ key: String) -> String {
      if let known = groupOfKey[key], !known.isEmpty { return known }
      let taken = s.groups[key].map { $0.profileId != profileId || !$0.pinned } ?? false
      let id = taken ? newId("tab") : key
      groupOfKey[key] = id
      if id != key { keyOfLocal[id] = key }
      return id
    }
    var alienGroupOf: [JSONValue?: JSONValue?] = [:]
    func gid(_ key: JSONValue?) -> JSONValue? {
      if let text = key?.string { return .string(gidText(text)) }
      let cacheable = key == nil || key!.array == nil && key!.object == nil
      if cacheable, let hit = alienGroupOf[key] { return hit }
      let taken = s.groups[jsText(key)].map { $0.profileId != profileId || !$0.pinned } ?? false
      let id: JSONValue? = taken ? .string(newId("tab")) : key
      if cacheable { alienGroupOf[key] = .some(id) }
      return id
    }
    var pins = OrderedDict<String, JSONObject>()
    var groupValues = OrderedDict<String, JSONValue>()
    var nestValues = OrderedDict<String, JSONValue>()
    var awaiting: [String: JSONValue] = [:]
    let hadGroup = Set(s.groups.values.filter { $0.profileId == profileId }.map(\.pinKeyOrId) + (s.parkedPins[profileId]?.groups ?? []).map(\.id))
    func expired(_ k: String, _ g: JSONValue?) -> Bool {
      let entry = sync[k.jsSlice(6)]
      guard jsStrict(entry?["g"], g) else { return false }
      let w = entry?["w"]
      return (nullish(w) ? 0 : (w?.number ?? .nan)) <= recordsNow
    }
    func listed(_ g: JSONValue?) -> Bool { visible["pin:g:\(jsText(g))"] != nil || visible["\(nestPrefix)g:\(jsText(g))"] != nil }
    func unresolved(_ k: String, _ g: JSONValue?) -> Bool {
      !listed(g) && !(g?.string.map(hadGroup.contains) ?? false) && !recordKnown("pin:g:\(jsText(g))") && !expired(k, g)
    }
    func contained(_ id: String) -> Bool {
      guard let t = s.tabs[id] else { return false }
      return t.pinned || pinnedMember.contains(id)
    }
    func retainedIn(_ id: String, _ g: JSONValue?) -> Bool {
      !contained(id) && s.groups.values.contains { x in !x.pinned && x.profileId == profileId && jsStrict(.string(x.pinKeyOrId), g) && x.tabIds.contains(id) }
    }
    for (k, v) in visible {
      if starts(k, "pin:t:") {
        let g = v["g"]
        let id = tid(k.jsSlice(6))
        if truthy(g) && !listed(g) && retainedIn(id, g) { continue }
        if truthy(g) && unresolved(k, g) { awaiting[id] = g! }
        var pin = spread(v)
        let local = truthy(g) ? gid(g) : g
        if let local { pin["g"] = local } else { pin.removeValue(forKey: "g") }
        pins[id] = pin
      } else if starts(k, "pin:g:") {
        groupValues[gidText(k.jsSlice(6))] = v
      } else if starts(k, "\(nestPrefix)g:") {
        nestValues[gidText(k.jsSlice(nestPrefix.utf16.count + 2))] = v
      }
    }
    let all = OrderedSet(groupValues.keys + nestValues.keys)
    func keyOf(_ id: String) -> String { keyOfLocal[id] ?? id }
    func byKey(_ a: String, _ z: String) -> Bool { jsKeyPrecedes(keyOf(a), keyOf(z)) }
    var parentGroup: [String: String?] = [:]
    for id in all {
      let p = nestValues[id]?["p"]
      let parent = truthy(p) && listed(p) ? gid(p)?.string : nil
      parentGroup[id] = .some(parent != nil && parent != id && all.contains(parent!) ? parent : nil)
    }
    func parentOf(_ id: String) -> String? { parentGroup[id] ?? nil }
    for start in all.elements.stableSorted(by: byKey) {
      var path: [String] = []
      var at: String? = start
      while let current = at, !current.isEmpty {
        if let loop = path.firstIndex(of: current) {
          parentGroup[Array(path[loop...]).stableSorted(by: byKey)[0]] = .some(nil)
          break
        }
        path.append(current)
        at = parentOf(current)
      }
    }
    func chainUp(_ id: String) -> [String] {
      var out: [String] = []
      var g: String? = id
      while let current = g, !current.isEmpty, !out.contains(current) {
        out.append(current)
        g = parentOf(current)
      }
      return out
    }
    func lookOf(_ id: String) -> JSONValue? {
      truthy(parentOf(id)) ? coalesce(nestValues[id], groupValues[id]) : coalesce(groupValues[id], nestValues[id])
    }
    for (k, v) in visible where starts(k, "\(nestPrefix)t:") {
      let key = k.jsSlice(nestPrefix.utf16.count + 2)
      let inner = v["g"]
      if visible["pin:t:\(key)"] == nil || !listed(inner) { continue }
      let id = tid(key)
      guard let pin = pins[id], truthy(pin["g"]), let current = pin["g"]?.string, all.contains(current) else { continue }
      guard let target = gid(inner)?.string, all.contains(target), chainUp(target).last == chainUp(current).last else { continue }
      var moved = pin
      moved["g"] = gid(inner)
      pins[id] = moved
    }
    for (id, v) in pins where truthy(v["g"]) && !(v["g"]?.string.map(all.contains) ?? false) {
      var cleared = v
      cleared["g"] = .null
      pins[id] = cleared
    }
    let roots = all.elements.filter { !truthy(parentOf($0)) }
    let unsortedArea = (pins.filter { !truthy($0.value["g"]) }.map { PinSlot(id: $0.key, group: false, pos: $0.value["pos"]) }
      + roots.map { PinSlot(id: $0, group: true, pos: coalesce(groupValues[$0]?["pos"], .string("\u{ffff}\(keyOf($0))"))) })
    let areaSlots = jsSort(unsortedArea, slotOrder)
    var kids: [String: [PinSlot]] = [:]
    var placedGroups = Set<String>()
    let members = pins.filter { truthy($0.value["g"]) }.map { entry in
      PinSlot(id: entry.key, group: false, pos: entry.value["pos"], chain: Array(chainUp(entry.value["g"]!.string!).reversed()))
    }
    for m in jsSort(members, slotOrder) {
      for (i, g) in m.chain.enumerated() {
        if i == 0 || placedGroups.contains(g) { continue }
        placedGroups.insert(g)
        kids[m.chain[i - 1], default: []].append(PinSlot(id: g, group: true, pos: .string("")))
      }
      kids[m.chain.last!, default: []].append(m)
    }
    func walk(_ id: String) -> [PinSlot] { (kids[id] ?? []).flatMap { $0.group ? [$0] + walk($0.id) : [$0] } }
    let tree = areaSlots.flatMap { $0.group ? [$0] + walk($0.id) : [$0] }
    let groupOrder = tree.filter(\.group).map(\.id)
    let tileOrder = areaSlots.filter { !$0.group }.map(\.id)
    var memberOrder: [String: [String]] = [:]
    for g in all { memberOrder[g] = walk(g).filter { !$0.group }.map(\.id) }

    let goneTabs = changed.filter { starts($0, "pin:t:") && visible[$0] == nil }.map { tid($0.jsSlice(6)) }
      .filter { contained($0) && scope.contains(s.tabs[$0]!.windowId) }
    let removable = goneTabs.filter { id in
      let t = s.tabs[id]!
      guard let w = s.windows[t.windowId] else { return false }
      let keptTab = t.navigation != nil || truthy(t.adoptId) || w.activeTabIds.values.contains(id)
      return !keptTab && w.tabIds.contains { $0 != id && !goneTabs.contains($0) }
    }
    s = removeTabs(s, removable, record: false)
    var tabs = touched(s.tabs)
    for id in goneTabs {
      guard var t = tabs[id] else { continue }
      t.pinned = false
      t.pinnedUrl = nil
      t.pinnedAsRow = nil
      t.tileFolder = nil
      t.pinKey = nil
      tabs[id] = t
    }
    let framed = Set(memberOrder.values.flatMap { $0 })
    let changedKeys = Set(changed)
    let gone = Set(goneTabs)
    func unseenByView(_ id: String) -> Bool {
      guard tabs[id] != nil, let before = s.tabs[id], !framed.contains(id), !gone.contains(id) else { return false }
      let key = "pin:t:\(before.pinKeyOrId)"
      return visible[key] == nil && !changedKeys.contains(key)
    }
    var groups = s.groups
    groups.touch()
    var orphaned = OrderedSet<String>()
    for k in changed {
      let key: String? = starts(k, "pin:g:") ? k.jsSlice(6) : starts(k, "\(nestPrefix)g:") ? k.jsSlice(nestPrefix.utf16.count + 2) : nil
      guard let key, visible[k] == nil else { continue }
      if all.contains(gidText(key)) { continue }
      guard let deleted = groups[gidText(key)], deleted.pinned, scope.contains(deleted.windowId) else { continue }
      for id in deleted.tabIds where unseenByView(id) { _ = orphaned.insert(id) }
      groups[gidText(key)] = nil
    }
    let before = s.groups
    func localGroupsOf(_ id: String) -> [String] {
      before.values.filter { $0.pinned && $0.profileId == profileId && $0.tabIds.contains(id) }.map(\.id)
        .stableSorted { Groups.depthOf(before, $0) > Groups.depthOf(before, $1) }
    }
    func homeOf(_ id: String) -> String? { localGroupsOf(id).first { groups[$0] != nil } }
    for id in orphaned where homeOf(id) == nil {
      var tile = tabs[id]!
      tile.pinned = true
      tile.pinnedUrl = tile.pinnedUrl.flatMap { $0.isEmpty ? nil : $0 } ?? tile.url
      tabs[id] = tile
    }
    var windows = s.windows
    windows.touch()

    var described = OrderedSet<String>()
    for id in groupOrder { _ = described.insert(id) }
    for id in all.elements where groups[id] != nil && !described.contains(id) {
      for x in chainUp(id).reversed() { _ = described.insert(x) }
    }
    for id in described {
      let v = lookOf(id)
      let old = groups[id]
      let color = lookedColor(v?["c"], base("\(PinnedSync.groupLook)\(old.map(\.pinKeyOrId) ?? keyOf(id))"))
      let icon = v?["i"]
      var made: TabGroup
      if let old {
        made = old
        made.name = v?["n"]?.string ?? ""
        made.pinned = true
      } else {
        made = TabGroup(
          id: id, windowId: newPinWindow, profileId: profileId, name: v?["n"]?.string ?? "", icon: nil, color: nil, collapsed: false, pinned: true,
          tabIds: [], createdAt: now)
        if let key = keyOfLocal[id] { made.pinKey = key }
      }
      made.setLook(icon: icon?.string, color: color.string, absent: icon == nil ? ["icon"] : [])
      groups[id] = Groups.withParent(made, parentOf(id))
    }
    var noted = OrderedDict<String, JSONValue>()
    func note(_ key: String, _ id: String) {
      let g = awaiting[id]
      let was = sync[key]
      let had = was?["g"]
      if jsStrict(nullish(had) ? nil : had, g) { return }
      if let g, g.truthy {
        let keep = jsStrict(had, g) && was?["w"] != nil
        noted[key] = ["g": g, "w": keep ? was!["w"]! : .number(recordsNow + horizon)]
      } else {
        noted[key] = [:]
      }
    }
    for (id, v) in pins {
      let vg = v["g"]
      var group: TabGroup? = nil
      if truthy(vg), let text = vg?.string, all.contains(text), let g = groups[text] { group = g }
      let u = v["u"]
      if var old = tabs[id] {
        let key = old.pinKeyOrId
        if group != nil {
          let current = JSONValue(old.pinnedUrl)
          let homeUrl: JSONValue? =
            pinnedMember.contains(id)
            ? or(current, syncedHome(base("\(PinnedSync.home)\(key)")).map(JSONValue.string))
            : or(syncedHome(base("\(PinnedSync.home)\(key)")).map(JSONValue.string), current)
          old.pinnedUrl = (or(homeUrl, u).flatMap { truthy($0) ? $0 : nil } ?? .null).string
          old.pinnedAsRow = nil
          old.tileFolder = nil
        } else {
          old.setNullable("pinnedUrl", u)
          if !old.pinned { old.pinnedAsRow = marked(key) ? true : nil }
          if !old.pinned && !marked(key), let folder = folderMark(base, key) { old.tileFolder = folder }
        }
        old.pinned = group == nil
        old.setNullable("customTitle", v["t"])
        old.setNullable("customIcon", v["i"])
        if old.unloaded == true {
          old.url = u?.string ?? ""
          old.title = v["ti"]?.string ?? ""
        }
        tabs[id] = old
        note(old.pinKeyOrId, id)
        continue
      }
      let windowId = group?.windowId ?? newPinWindow
      guard var w = windows[windowId] else { continue }
      var patch = TabPatch()
      patch.title = v["ti"]?.string ?? ""
      patch.pinned = group == nil
      lookPatch(.object(v), "t", into: &patch)
      lookPatch(.object(v), "i", into: &patch)
      var tab = makeTab(windowId, profileId, u?.string ?? "", patch)
      tab.id = id
      if let key = keyOfLocal[id] { tab.pinKey = key }
      let key = keyOfLocal[id] ?? id
      let synced: JSONValue? = group != nil ? syncedHome(base("\(PinnedSync.home)\(key)")).map(JSONValue.string) : nil
      tab.pinnedUrl = (or(synced, u).flatMap { truthy($0) ? $0 : nil } ?? .null).string
      if group == nil && marked(key) { tab.pinnedAsRow = true }
      if group == nil && !marked(key), let folder = folderMark(base, key) { tab.tileFolder = folder }
      tab.navigation = nil
      tab.unloaded = true
      note(key, id)
      tabs[id] = tab
      w.tabIds.append(id)
      windows[windowId] = w
    }
    let standalone = Set(tileOrder.filter { tabs[$0]?.pinned == true })
    var pinnedPart = JSMap<TabGroup>()
    var unpinnedPart = JSMap<TabGroup>()
    for (id, g) in groups {
      if g.pinned { pinnedPart[id] = g } else { unpinnedPart[id] = g }
    }
    for (id, g) in Groups.leaveGroups(Table(unpinnedPart), standalone) { pinnedPart[id] = g }
    groups = Table(pinnedPart)
    let inGroup = Set(memberOrder.values.flatMap { $0 }.filter { tabs[$0] != nil })
    var localMembers = OrderedSet<String>()
    for g in s.groups.values where g.pinned && g.profileId == profileId {
      for id in g.tabIds { _ = localMembers.insert(id) }
    }
    let unseenHere = localMembers.filter { unseenByView($0) && homeOf($0) != nil }
    func keptUnder(_ id: String, _ group: String) -> Bool {
      guard let home = homeOf(id) else { return false }
      return home == group || Groups.ancestorIds(groups, home).contains(group)
    }
    for g in groups.values where g.profileId == profileId {
      var next = g
      next.tabIds =
        g.pinned && memberOrder[g.id] != nil
        ? keepUnseenMembers(memberOrder[g.id]!.filter { tabs[$0] != nil }, g.tabIds + unseenHere.filter { !g.tabIds.contains($0) }) {
          unseenByView($0) && keptUnder($0, g.id)
        }
        : g.tabIds.filter { !inGroup.contains($0) && (!g.pinned || !unseenByView($0) || keptUnder($0, g.id)) }
      groups[g.id] = next
    }
    for g in groups.values where g.profileId == profileId && g.tabIds.isEmpty { groups[g.id] = nil }
    var copied: [String: String] = [:]
    let pinnedHere = groups.values.filter { $0.profileId == profileId && $0.pinned }
    for groupId in pinnedHere.map({ ($0.id, Groups.depthOf(groups, $0.id)) }).stableSorted(by: { $0.1 < $1.1 }).map(\.0) {
      let g = groups[groupId]!
      let parent = truthy(g.parentId) ? groups[g.parentId!] : nil
      func real(_ w: String) -> Bool { w != park && windows[w] != nil }
      let homes = g.tabIds.map { tabs[copied[$0] ?? $0]! }.filter { real($0.windowId) }
      let windowId =
        parent?.windowId
        ?? (homes.isEmpty || homes.contains { $0.windowId == g.windowId } ? g.windowId : (homes.first(where: hasPage) ?? homes[0]).windowId)
      var tabIds: [String] = []
      for id in g.tabIds.map({ copied[$0] ?? $0 }) {
        let t = tabs[id]!
        if t.windowId == windowId {
          tabIds.append(id)
        } else if t.windowId == park, windows[windowId] != nil {
          var parkWindow = windows[park]!
          parkWindow.tabIds = parkWindow.tabIds.filter { $0 != id }
          windows[park] = parkWindow
          var target = windows[windowId]!
          target.tabIds.append(id)
          windows[windowId] = target
          var moved = t
          moved.windowId = windowId
          tabs[id] = moved
          tabIds.append(id)
        } else if windows[windowId] != nil {
          var patch = TabPatch()
          patch.title = t.title
          patch.favicon = .some(t.favicon)
          patch.customTitle = .some(t.customTitle)
          patch.customIcon = .some(t.customIcon)
          patch.undefined = t.absent.intersection(["favicon", "customTitle", "customIcon"])
          var copy = makeTab(windowId, profileId, t.url, patch)
          copy.pinKey = t.pinKeyOrId
          copy.pinnedUrl = t.pinnedUrl
          carryNullable(&copy, t, ["pinnedUrl"])
          copy.navigation = nil
          copy.unloaded = true
          tabs[copy.id] = copy
          var original = t
          original.pinKey = nil
          tabs[id] = original
          var target = windows[windowId]!
          target.tabIds.append(copy.id)
          windows[windowId] = target
          tabIds.append(copy.id)
          copied[id] = copy.id
        }
      }
      var placed = g
      placed.windowId = windowId
      placed.tabIds = tabIds
      groups[g.id] = placed
    }

    let sequence = tree.filter { !$0.group }.map { copied[$0.id] ?? $0.id }
    var rank: [String: Int] = [:]
    for (i, id) in sequence.enumerated() { rank[id] = i }
    func anchorOf(_ group: String) -> String?? { anchorIn(base("\(PinnedSync.order)\(group)")) }
    for w in windows.values {
      if w.incognito { continue }
      var ids = w.tabIds.filter { tabs[$0] != nil }
      let slots = ids.indices.filter { rank[ids[$0]] != nil }
      let sorted = slots.map { ids[$0] }.stableSorted { rank[$0]! < rank[$1]! }
      for (i, slot) in slots.enumerated() { ids[slot] = sorted[i] }
      var sectioned = w
      sectioned.tabIds = Groups.orderSections(pinnedFirst(ids, tabs, groups), tabs, groups)
      var view = BrowserState()
      view.tabs = tabs
      view.groups = groups
      var window = sectioned
      window.tabIds = arrangePinnedArea(view, sectioned, profileId, anchorOf)
      windows[w.id] = window
      groups = Groups.syncGroupOrder(groups, window)
    }
    var parkedPins = s.parkedPins
    if let parkWindow = windows[park] {
      var source = BrowserState()
      source.tabs = tabs
      source.groups = groups
      source.caches = s.caches
      parkedPins = parkWindowPins(parkedPins, parkWindow, source, otherWindows: false, history: true)
      tabs.remove(parkWindow.tabIds)
      groups = groups.filtered { $0.windowId != park }
      windows[park] = nil
    }
    var pinSync = s.pinSync
    if !noted.isEmpty {
      var mine = s.pinSync[profileId] ?? JSMap()
      for (k, v) in noted { mine[k] = v }
      pinSync[profileId] = mine
    }
    var next = state
    next.tabs = tabs
    next.windows = windows
    next.groups = groups
    next.splits = s.splits
    next.windowOrder = s.windowOrder
    next.parkedPins = parkedPins
    next.pinSync = pinSync
    writeFromSync(next)
    return nil
  }
}
