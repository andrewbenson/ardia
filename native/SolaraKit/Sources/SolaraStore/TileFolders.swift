import SolaraModel

func tileFolderOf(_ t: Tab?) -> TileFolder? {
  guard let t, let folder = t.tileFolder, t.pinSection == .tile else { return nil }
  return folder
}

func withTileFolder(_ t: Tab, _ folder: TileFolder?) -> Tab {
  if t.tileFolder == folder { return t }
  var out = t
  out.tileFolder = folder
  return out
}

func folderMembers(_ s: BrowserState, _ windowId: String, _ folderId: String) -> [String] {
  var profileId: String? = nil
  return (s.windows[windowId]?.tabIds ?? []).filter { id in
    let t = s.tabs[id]
    if tileFolderOf(t)?.id != folderId { return false }
    if profileId == nil { profileId = t!.profileId }
    return t!.profileId == profileId
  }
}

func folderIn(_ s: BrowserState, _ windowId: String, _ folderId: String) -> TileFolder? {
  guard let first = folderMembers(s, windowId, folderId).first else { return nil }
  return tileFolderOf(s.tabs[first])
}

extension Session {
  func tileAfter(_ s: BrowserState, _ windowId: String, _ anchor: String?, _ skip: [String]) -> String? {
    let ids = s.windows[windowId]?.tabIds ?? []
    let at = anchor.map { ids.jsIndexOf($0) } ?? -1
    if at < 0 { return nil }
    return ids.jsSliced(at + 1).first { !skip.contains($0) }
  }

  func sameWindow(_ s: BrowserState, _ ids: [String], _ anchor: Tab) -> [String] {
    let order = s.windows[anchor.windowId]?.tabIds ?? []
    return OrderedSet(ids).elements.filter { s.tabs[$0]?.windowId == anchor.windowId && s.tabs[$0]!.profileId == anchor.profileId }
      .stableSorted { order.jsIndexOf($0) < order.jsIndexOf($1) }
  }

  public func addToTileFolder(_ s: BrowserState, _ ids: [String], _ ontoId: String, _ beforeId: String?) -> BrowserState {
    guard let onto = s.tabs[ontoId], onto.pinSection == .tile else { return s }
    let folder = tileFolderOf(onto) ?? TileFolder(id: newId("tf"), name: "")
    let moving = sameWindow(s, ids, onto).filter { $0 != ontoId }
    var next = s
    if onto.tileFolder != folder { next.tabs[ontoId] = withTileFolder(onto, folder) }
    if moving.isEmpty { return next }
    let last = folderMembers(next, onto.windowId, folder.id).filter { !moving.contains($0) }.last
    let at: String? = beforeId.flatMap { !$0.isEmpty && !moving.contains($0) ? $0 : nil } ?? tileAfter(next, onto.windowId, last, moving)
    return placing(next, moving, TabPlacement(pinned: true, row: false, beforeId: .some(at), tileFolder: .some(folder)))
  }

  public func newTileFolder(_ s: BrowserState, _ ids: [String], _ name: String = "") -> (state: BrowserState, folderId: String?) {
    guard let first = s.tabs[ids.first ?? ""], s.windows[first.windowId] != nil else { return (s, nil) }
    let moving = sameWindow(s, ids, first)
    let anchor = moving.first { s.tabs[$0]?.pinSection == .tile } ?? moving[0]
    let trimmed = name.jsTrim()
    let folder = TileFolder(id: newId("tf"), name: trimmed, renamedAt: trimmed.isEmpty ? nil : now)
    let before = tileAfter(s, first.windowId, anchor, moving)
    return (placing(s, moving, TabPlacement(pinned: true, row: false, beforeId: .some(before), tileFolder: .some(folder))), folder.id)
  }

  public func leaveTileFolder(_ s: BrowserState, _ ids: [String]) -> BrowserState {
    guard let first = s.tabs[ids.first ?? ""], let folder = tileFolderOf(first) else { return s }
    let moving = sameWindow(s, ids, first).filter { tileFolderOf(s.tabs[$0])?.id == folder.id }
    let last = folderMembers(s, first.windowId, folder.id).filter { !moving.contains($0) }.last
    return placing(s, moving, TabPlacement(pinned: true, row: false, beforeId: .some(tileAfter(s, first.windowId, last, moving)), tileFolder: .some(nil)))
  }

  func patchMembers(_ s: BrowserState, _ windowId: String, _ folderId: String, _ folder: TileFolder?) -> BrowserState {
    let members = folderMembers(s, windowId, folderId)
    if members.isEmpty { return s }
    var next = s
    for id in members { next.tabs[id] = withTileFolder(next.tabs[id]!, folder) }
    next.tabs.touch()
    return next
  }

  public func renameTileFolder(_ s: BrowserState, _ windowId: String, _ folderId: String, _ name: String) -> BrowserState {
    guard let folder = folderIn(s, windowId, folderId), folder.name != name.jsTrim() else { return s }
    return patchMembers(s, windowId, folderId, TileFolder(id: folderId, name: name.jsTrim(), renamedAt: max(now, (folder.renamedAt ?? 0) + 1)))
  }

  public func dissolveTileFolder(_ s: BrowserState, _ windowId: String, _ folderId: String) -> BrowserState {
    patchMembers(s, windowId, folderId, nil)
  }

  func membersByWindow(_ tabs: Table<Tab>, _ windows: Table<BrowserWindow>, _ folders: Set<String>) -> OrderedDict<String, [String]> {
    var out = OrderedDict<String, [String]>()
    for w in windows.values {
      for id in w.tabIds {
        guard let folder = tileFolderOf(tabs[id]), folders.contains(folder.id) else { continue }
        out["\(w.id)\u{1}\(tabs[id]!.profileId)\u{1}\(folder.id)", default: []].append(id)
      }
    }
    return out
  }

  func parkedFolders(_ park: ParkedPins?) -> OrderedDict<String, Int> {
    var count = OrderedDict<String, Int>()
    for p in park?.tabs ?? [] {
      if let folder = p.snapshot.tileFolder, p.groupId == nil, p.snapshot.pinnedAsRow != true { count[folder.id] = (count[folder.id] ?? 0) + 1 }
    }
    return count
  }

  func settleParked(_ s: BrowserState, _ prev: BrowserState) -> Table<ParkedPins>? {
    if !s.parkedPins.changed(from: prev.parkedPins) { return nil }
    var out: Table<ParkedPins>? = nil
    for (profileId, park) in s.parkedPins {
      if park == prev.parkedPins[profileId] { continue }
      let now = parkedFolders(park)
      let before = parkedFolders(prev.parkedPins[profileId])
      let alone = Set(now.filter { $0.value == 1 && (before[$0.key] ?? 0) >= 2 }.map(\.key))
      if alone.isEmpty { continue }
      var changed = park
      changed.tabs = park.tabs.map { p in
        guard let folder = p.snapshot.tileFolder, alone.contains(folder.id) else { return p }
        var q = p
        q.snapshot.tileFolder = nil
        return q
      }
      if out == nil { out = s.parkedPins }
      out![profileId] = changed
    }
    return out
  }

  func settleTileFolders(_ s: BrowserState, _ prev: BrowserState) -> BrowserState? {
    let parkedPins = settleParked(s, prev)
    if !s.tabs.changed(from: prev.tabs) {
      guard let parkedPins else { return nil }
      var next = s
      next.parkedPins = parkedPins
      return next
    }
    var tabs: Table<Tab>? = nil
    var shrunk = Set<String>()
    for id in s.tabs.changedIds(from: prev.tabs) {
      let now = s.tabs[id]
      let was = prev.tabs[id]
      let wasIn = tileFolderOf(was)?.id
      let otherProfile = now != nil && was != nil && now!.profileId != was!.profileId
      let moved = otherProfile || (now != nil && was != nil && now!.windowId != was!.windowId)
      if let now, now.tileFolder != nil, tileFolderOf(now) == nil || otherProfile {
        if tabs == nil { tabs = s.tabs }
        tabs![id] = withTileFolder(now, nil)
      }
      let isIn = tileFolderOf((tabs ?? s.tabs)[id])?.id
      if let wasIn, isIn != wasIn || moved { shrunk.insert(wasIn) }
    }
    if !shrunk.isEmpty {
      let current = tabs ?? s.tabs
      let before = membersByWindow(prev.tabs, prev.windows, shrunk)
      for (key, ids) in membersByWindow(current, s.windows, shrunk) {
        if ids.count != 1 || (before[key]?.count ?? 0) < 2 { continue }
        if tabs == nil { tabs = s.tabs }
        tabs![ids[0]] = withTileFolder(current[ids[0]]!, nil)
      }
    }
    if tabs == nil && parkedPins == nil { return nil }
    var next = s
    if let tabs { next.tabs = tabs }
    if let parkedPins { next.parkedPins = parkedPins }
    return next
  }
}
