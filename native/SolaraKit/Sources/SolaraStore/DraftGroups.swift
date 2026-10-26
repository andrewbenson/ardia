import SolaraModel

public struct GroupDraft: Sendable {
  public var title: String
  public var url: String?
  public var customTitle: String?
  public var id: String?
  public var children: [GroupDraft]?

  public init(json: JSONValue) {
    title = json["title"]?.string ?? ""
    url = json["url"]?.string
    customTitle = json["customTitle"]?.string
    id = json["id"]?.string
    children = json["children"]?.array?.map(GroupDraft.init(json:))
  }
}

let maxDraftLinks = 5000

func opensUrl(_ url: String?) -> Bool {
  guard let url, !url.isEmpty else { return false }
  let lower = url.lowercased()
  return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("file:")
}

public func pageKey(_ url: String) -> String {
  let trimmed = url.jsTrim()
  guard let schemeEnd = trimmed.range(of: "://") else { return url }
  let scheme = String(trimmed[..<schemeEnd.lowerBound])
  func letter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
  func schemeChar(_ c: Unicode.Scalar) -> Bool { letter(c) || (c >= "0" && c <= "9") || c == "+" || c == "." || c == "-" }
  guard let first = scheme.unicodeScalars.first, letter(first), scheme.unicodeScalars.allSatisfy(schemeChar) else { return url }
  let afterScheme = trimmed[schemeEnd.upperBound...]
  if afterScheme.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return url }
  let hostEnd = afterScheme.firstIndex { "/?#".contains($0) } ?? afterScheme.endIndex
  let hostPart = String(afterScheme[..<hostEnd])
  let rest = String(afterScheme[hostEnd...])
  let at = hostPart.jsLastIndexOf("@")
  let host = hostPart.jsSlice(0, at + 1) + hostPart.jsSlice(at + 1).lowercased()
  var tail = rest.hasPrefix("/") ? rest : "/\(rest)"
  if tail.hasSuffix("#") { tail.removeLast() }
  return "\(scheme.lowercased())://\(host)\(tail)"
}

extension Session {
  func pinnedPages(_ s: BrowserState, _ profileId: String) -> Set<String> {
    let inPinnedGroup = Set(s.groups.values.filter { $0.pinned && $0.profileId == profileId }.flatMap(\.tabIds))
    var urls: [String] = []
    for t in s.tabs.values where t.profileId == profileId && (t.pinned || inPinnedGroup.contains(t.id)) {
      urls.append(t.url)
      if let p = t.pinnedUrl { urls.append(p) }
    }
    for p in s.parkedPins[profileId]?.tabs ?? [] {
      urls.append(p.snapshot.url)
      if let u = p.snapshot.pinnedUrl { urls.append(u) }
    }
    return Set(urls.filter { !$0.isEmpty }.map(pageKey))
  }

  func withDraftGroups(_ s: BrowserState, _ windowId: String, _ profileId: String, _ drafts: [GroupDraft]) -> (BrowserState, JSONValue) {
    var carried = OrderedSet<String>()
    guard let w = s.windows[windowId], !w.incognito else { return (s, ["made": [], "carried": [], "skipped": 0]) }
    var seen = pinnedPages(s, profileId)
    var tabs = s.tabs
    tabs.touch()
    var groups = s.groups
    groups.touch()
    var order: [String] = []
    var made: [String] = []
    var all: [String] = []
    let stamp = now
    var skipped = 0
    var taken = 0
    func make(_ d: GroupDraft, _ parentId: String?) -> [String] {
      let id = newId("g")
      var tabIds: [String] = []
      for c in d.children ?? [] {
        guard let url = c.url, !url.isEmpty else {
          tabIds.append(contentsOf: make(c, id))
          continue
        }
        if !opensUrl(url) || seen.contains(pageKey(url)) { continue }
        if taken >= maxDraftLinks {
          skipped += 1
          continue
        }
        seen.insert(pageKey(url))
        taken += 1
        var patch = TabPatch()
        patch.title = c.title
        patch.customTitle = .some(c.customTitle)
        var t = makeTab(windowId, profileId, url, patch)
        t.navigation = nil
        t.unloaded = true
        tabs[t.id] = t
        order.append(t.id)
        tabIds.append(t.id)
        if let cid = c.id { carried.insert(cid) }
      }
      if tabIds.isEmpty { return tabIds }
      var g = TabGroup(id: id, windowId: windowId, profileId: profileId, name: d.title, icon: nil, color: nil, collapsed: false, pinned: true, tabIds: tabIds, createdAt: stamp)
      g.parentId = parentId
      groups[id] = g
      all.append(id)
      if parentId == nil { made.append(id) }
      return tabIds
    }
    for d in drafts {
      taken = 0
      _ = make(d, nil)
    }
    let result: JSONValue = ["made": JSONValue(made), "carried": JSONValue(carried.elements), "skipped": JSONValue(skipped)]
    if made.isEmpty { return (s, result) }
    let pinnedArea = Set(s.groups.values.filter(\.pinned).flatMap(\.tabIds))
    var at = 0
    for (i, id) in w.tabIds.enumerated() where s.tabs[id]?.pinned == true || pinnedArea.contains(id) { at = i + 1 }
    var ids = w.tabIds
    Groups.insertAll(&ids, at, order)
    groups = Groups.nestGroups(groups)
    var window = w
    window.tabIds = Groups.orderSections(ids, tabs, groups)
    var pinChoices = s.pinChoices
    if !Ids.isIncognitoProfile(profileId) {
      var mine = pinChoices[profileId] ?? JSMap()
      for id in all { mine[groupChoiceKey(id)] = nextPinChoice() }
      for id in order { mine[placeChoiceKey(id)] = nextPinChoice() }
      pinChoices[profileId] = mine
    }
    var next = s
    next.tabs = tabs
    next.pinChoices = pinChoices
    next.groups = Groups.syncGroupOrder(groups, window)
    next.windows[windowId] = window
    return (next, result)
  }
}
