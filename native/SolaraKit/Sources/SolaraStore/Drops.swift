import SolaraModel

public enum Drop: Sendable {
  case tabs(TabPlacement)
  case group(groupId: String, placement: GroupPlacement)
  case live
  case onto(targetId: String)
  case folder(ontoId: String, beforeId: String?)
  case none

  public init(json: JSONValue?) {
    guard let json, let type = json["type"]?.string else {
      self = .none
      return
    }
    switch type {
    case "tabs": self = .tabs(TabPlacement(json: json["placement"]))
    case "group":
      let p = json["placement"]
      self = .group(
        groupId: json["groupId"]?.string ?? "",
        placement: GroupPlacement(pinned: p?["pinned"]?.truthy ?? false, beforeId: p?["beforeId"]?.string, parentId: p?["parentId"]?.string))
    case "live": self = .live
    case "onto": self = .onto(targetId: json["targetId"]?.string ?? "")
    case "folder": self = .folder(ontoId: json["ontoId"]?.string ?? "", beforeId: json["beforeId"]?.string)
    default: self = .none
    }
  }
}

extension TabPlacement {
  public init(json: JSONValue?) {
    let o = json?.object ?? [:]
    pinned = o["pinned"]?.truthy ?? false
    row = o["row"].flatMap { $0.isNull ? nil : $0.truthy }
    beforeId = o.contains("beforeId") ? .some(o["beforeId"]?.string) : nil
    groupId = o.contains("groupId") ? .some(o["groupId"]?.string) : nil
    last = o["last"].flatMap { $0.isNull ? nil : $0.truthy }
    if let folder = o["tileFolder"] {
      tileFolder = .some(folder.isNull ? nil : try? TileFolder(value: folder))
    } else {
      tileFolder = nil
    }
  }
}

extension Session {
  func dropping(_ s: BrowserState, _ ids: [String], _ drop: Drop) -> BrowserState? {
    switch drop {
    case .tabs(let placement): return placing(s, ids, placement)
    case .group(let groupId, let placement): return movingGroup(s, groupId, placement)
    case .onto(let targetId):
      let (next, id) = groupingOnto(s, ids, targetId)
      return id.isEmpty ? nil : next
    case .folder(let ontoId, let beforeId): return addToTileFolder(s, ids, ontoId, beforeId)
    default: return nil
    }
  }

  public func dropTabs(_ ids: [String], _ drop: Drop) -> Bool {
    let s = state
    guard let next = dropping(s, ids, drop), !sameRef(next, s) else { return false }
    set(next)
    return true
  }

  func stepDrop(_ s: BrowserState, _ tabId: String, _ delta: Int) -> Drop {
    guard let tab = s.tabs[tabId], let w = s.windows[tab.windowId], tab.tileFolder == nil else { return .none }
    func chainOf(_ id: String) -> [String] {
      guard let g = Groups.innermostGroupOf(s.groups, id) else { return [] }
      return [g.id] + Groups.ancestorIds(s.groups, g.id)
    }
    func lane(_ id: String) -> String {
      if s.groups[chainOf(id).last ?? ""]?.pinned == true { return "row" }
      switch s.tabs[id]?.pinSection ?? .none {
      case .tile: return "tile"
      case .row: return "row"
      case .none: return "none"
      }
    }
    let container = Groups.innermostGroupOf(s.groups, tabId)
    func blockOf(_ id: String) -> String? {
      let chain = chainOf(id)
      let at = container.map { chain.jsIndexOf($0.id) } ?? chain.count
      if at < 0 { return nil }
      if at > 0 { return "g:\(chain[at - 1])" }
      if let folder = s.tabs[id]?.tileFolder { return "f:\(folder.id)" }
      return "t:\(Splits.splitOf(s, id)?.id ?? id)"
    }
    var blocks: [(key: String, ids: [String])] = []
    for id in w.tabIds {
      guard let t = s.tabs[id], t.profileId == tab.profileId, lane(id) == lane(tabId), let key = blockOf(id) else { continue }
      if blocks.last?.key == key { blocks[blocks.count - 1].ids.append(id) } else { blocks.append((key, [id])) }
    }
    guard let at = blocks.firstIndex(where: { $0.ids.contains(tabId) }) else { return .none }
    let target = at + delta
    if target >= 0 && target < blocks.count {
      let next = blocks[target]
      let beforeId: String? = delta < 0 ? next.ids[0] : (at + 2 < blocks.count ? blocks[at + 2].ids[0] : nil)
      return .tabs(
        TabPlacement(pinned: tab.pinned, beforeId: .some(beforeId), groupId: .some(container?.id), last: beforeId == nil ? true : nil))
    }
    guard let container, !(container.pinned && container.parentId == nil) else { return .none }
    let parent = container.parentId.flatMap { s.groups[$0] }
    let lastMember = container.tabIds.last
    let after = w.tabIds.jsSliced(w.tabIds.jsIndexOf(lastMember) + 1).first { id in
      !container.tabIds.contains(id) && (parent == nil || parent!.tabIds.contains(id))
    }
    let beforeId: String? = delta < 0 ? (container.tabIds.first { !blocks[at].ids.contains($0) } ?? after) : after
    return .tabs(TabPlacement(pinned: tab.pinned, beforeId: .some(beforeId), groupId: .some(parent?.id)))
  }
}
