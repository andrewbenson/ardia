import SolaraModel
import Synchronization

public struct PinnedLookups {
  public var base: (String) -> JSONValue?
  public var queued: (String) -> Bool
  public var now: Double
  public var known: (String) -> Bool
  public var remote: (String) -> JSONValue?
  public var stamp: (String) -> String?
  public var positions: ([String?]) throws -> [String]

  public init(
    positions: @escaping ([String?]) throws -> [String] = { $0.map { $0 ?? "" } }, base: @escaping (String) -> JSONValue?, queued: @escaping (String) -> Bool = { _ in false }, now: Double = 0,
    known: @escaping (String) -> Bool = { _ in false }, remote: @escaping (String) -> JSONValue? = { _ in nil },
    stamp: @escaping (String) -> String? = { _ in nil }
  ) {
    self.base = base
    self.queued = queued
    self.now = now
    self.known = known
    self.remote = remote
    self.stamp = stamp
    self.positions = positions
  }
}

public struct PinnedExtraction {
  public var values: [(key: String, value: JSONValue)]
  public var ignore: (String) -> Bool
  public var republish: ((String) -> Bool)?
  public var settled: (([String]) -> JSMap<Double>)?
}

public final class TileFolderMemory: Sendable {
  let held: Mutex<[String: [String]]>

  public init(_ seeded: [String: [String]] = [:]) { held = Mutex(seeded) }

  public static let shared = TileFolderMemory()

  func swap(_ profileId: String, _ next: [String]) -> Set<String> {
    held.withLock { held in
      let had = Set(held[profileId] ?? [])
      held[profileId] = next
      return had
    }
  }

  public var snapshot: [String: [String]] { held.withLock { $0 } }
}

public enum PinnedSync {
  public static let nest = "pinn:"
  public static let groupLook = "pgc:"
  public static let order = "pord:g:"
  public static let row = "pinrow:"
  public static let home = "pgh:"
  public static let tileFolder = "tilefold:"
  public static let folderName = "tilefold:n:"
  static let noBox = "none"
}

public func jsText(_ v: JSONValue?) -> String {
  guard let v else { return "undefined" }
  switch v {
  case .null: return "null"
  case .bool(let b): return b ? "true" : "false"
  case .number(let n): return jsNumberText(n)
  case .string(let s): return s
  case .array(let items): return items.map { $0.isNull ? "" : jsText($0) }.joined(separator: ",")
  case .object: return "[object Object]"
  }
}

public func jsStrict(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
  switch (a, b) {
  case (nil, nil): return true
  case (.some(.null), .some(.null)): return true
  case (.some(.bool(let x)), .some(.bool(let y))): return x == y
  case (.some(.number(let x)), .some(.number(let y))): return x == y
  case (.some(.string(let x)), .some(.string(let y))): return x == y
  default: return false
  }
}

func starts(_ s: String, _ prefix: String) -> Bool { s.utf16.starts(with: prefix.utf16) }

func nullish(_ v: JSONValue?) -> Bool { v == nil || v == .null }

func truthy(_ v: JSONValue?) -> Bool { v?.truthy ?? false }

func coalesce(_ a: JSONValue?, _ b: JSONValue?) -> JSONValue? { nullish(a) ? b : a }

func spread(_ v: JSONValue?) -> JSONObject {
  switch v {
  case .object(let o): return o
  case .array(let items): return JSONObject(items.enumerated().map { (String($0.offset), $0.element) })
  case .string(let s): return JSONObject(s.utf16.enumerated().map { (String($0.offset), .string(String(utf16CodeUnits: [$0.element], count: 1))) })
  default: return [:]
  }
}

func record(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var out = JSONObject()
  for (k, v) in pairs { if let v { out[k] = v } }
  return .object(out)
}

public enum JSPrimitive {
  case undefined, null, bool(Bool), number(Double), string(String)
}

public func jsPrimitive(_ v: JSONValue?) -> JSPrimitive {
  switch v {
  case nil: return .undefined
  case .null: return .null
  case .bool(let b): return .bool(b)
  case .number(let n): return .number(n)
  case .string(let s): return .string(s)
  case .array, .object: return .string(jsText(v))
  }
}

func jsStringToNumber(_ text: String) -> Double {
  let t = text.jsTrim()
  if t.isEmpty { return 0 }
  if t == "Infinity" || t == "+Infinity" { return .infinity }
  if t == "-Infinity" { return -.infinity }
  let lower = t.lowercased()
  for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
    let digits = lower.dropFirst(2)
    guard !digits.isEmpty else { return .nan }
    var value = 0.0
    for c in digits {
      guard let d = c.hexDigitValue, d < radix else { return .nan }
      value = value * Double(radix) + Double(d)
    }
    return value
  }
  var units = Array(t.utf8)
  var i = 0
  if i < units.count, units[i] == UInt8(ascii: "+") || units[i] == UInt8(ascii: "-") { i += 1 }
  var digits = 0
  while i < units.count, units[i] >= UInt8(ascii: "0"), units[i] <= UInt8(ascii: "9") { i += 1; digits += 1 }
  if i < units.count, units[i] == UInt8(ascii: ".") {
    i += 1
    while i < units.count, units[i] >= UInt8(ascii: "0"), units[i] <= UInt8(ascii: "9") { i += 1; digits += 1 }
  }
  if digits == 0 { return .nan }
  if i < units.count, units[i] == UInt8(ascii: "e") || units[i] == UInt8(ascii: "E") {
    i += 1
    if i < units.count, units[i] == UInt8(ascii: "+") || units[i] == UInt8(ascii: "-") { i += 1 }
    var exponent = 0
    while i < units.count, units[i] >= UInt8(ascii: "0"), units[i] <= UInt8(ascii: "9") { i += 1; exponent += 1 }
    if exponent == 0 { return .nan }
  }
  if i != units.count { return .nan }
  units = Array(t.utf8)
  return Double(String(decoding: units, as: UTF8.self)) ?? .nan
}

public func jsNumber(_ p: JSPrimitive) -> Double {
  switch p {
  case .undefined: return .nan
  case .null: return 0
  case .bool(let b): return b ? 1 : 0
  case .number(let n): return n
  case .string(let s): return jsStringToNumber(s)
  }
}

public func jsLess(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
  let x = jsPrimitive(a)
  let y = jsPrimitive(b)
  if case .string(let l) = x, case .string(let r) = y { return jsKeyPrecedes(l, r) }
  return jsNumber(x) < jsNumber(y)
}

public func jsSort<T>(_ input: [T], _ compare: (T, T) -> Double) -> [T] {
  var a = input
  let n = a.count
  if n < 2 { return a }
  if n >= 64 { return a.stableSorted { compare($0, $1) < 0 } }
  var run = 2
  let descending = compare(a[1], a[0]) < 0
  var previous = a[1]
  var i = 2
  while i < n {
    let order = compare(a[i], previous)
    if descending ? order >= 0 : order < 0 { break }
    previous = a[i]
    run += 1
    i += 1
  }
  if descending { a[0..<run].reverse() }
  var start = run
  while start < n {
    let pivot = a[start]
    var left = 0
    var right = start
    while left < right {
      let mid = left + ((right - left) >> 1)
      if compare(pivot, a[mid]) < 0 { right = mid } else { left = mid + 1 }
    }
    var p = start
    while p > left {
      a[p] = a[p - 1]
      p -= 1
    }
    a[left] = pivot
    start += 1
  }
  return a
}

func anchorIn(_ value: JSONValue?) -> String?? {
  guard let a = value?["a"] else { return .none }
  if a.isNull { return .some(nil) }
  return .some(a.string ?? "\u{0}\u{1}")
}

func legacyColor(_ color: JSONValue?) -> JSONValue? { color == .string(PinnedSync.noBox) ? .null : color }

func lookedColor(_ color: JSONValue?, _ look: JSONValue?) -> JSONValue {
  let c = color ?? .null
  return c.isNull && look == .string(PinnedSync.noBox) ? .string(PinnedSync.noBox) : c
}

func nullable(_ value: String?, absent: Bool) -> JSONValue? {
  if absent { return .none }
  return JSONValue(value)
}

func syncedHome(_ value: JSONValue?) -> String? {
  guard let s = value?.string, !s.isEmpty else { return nil }
  return s
}

func syncedFolderId(_ value: JSONValue?) -> String? { truthy(value) ? value?["f"]?.string : nil }
func syncedName(_ value: JSONValue?) -> String? { truthy(value) ? value?["n"]?.string : nil }

func folderMark(_ base: (String) -> JSONValue?, _ key: String) -> TileFolder? {
  guard let id = syncedFolderId(base("\(PinnedSync.tileFolder)\(key)")), !id.isEmpty else { return nil }
  return TileFolder(id: id, name: syncedName(base("\(PinnedSync.folderName)\(id)")) ?? "")
}

func pinnedOpenWindows(_ s: BrowserState) -> [BrowserWindow] {
  s.windowOrder.compactMap { s.windows[$0] }.filter { !$0.incognito && !$0.isSmall }
}

func pinnedHomeWindow(_ s: BrowserState, _ profileId: String) -> BrowserWindow? {
  let order = (s.ui.focusOrder + s.windowOrder).compactMap { s.windows[$0] }.filter { !$0.incognito && !$0.isSmall }
  func shows(_ w: BrowserWindow) -> Bool { w.tabIds.contains { s.tabs[$0]?.profileId == profileId } }
  return order.first { $0.profileId == profileId && shows($0) } ?? order.first(where: shows) ?? order.first { $0.profileId == profileId } ?? order.first
}

func homeFirst(_ s: BrowserState, _ profileId: String) -> [BrowserWindow] {
  let open = pinnedOpenWindows(s)
  guard let home = pinnedHomeWindow(s, profileId) else { return open }
  return [home] + open.filter { $0.id != home.id }
}

func chosenIn(_ s: BrowserState, _ profileId: String) -> JSMap<Double> { s.pinChoices[profileId] ?? JSMap() }

func settlement(_ chosen: JSMap<Double>, _ keys: [String]) -> JSMap<Double> {
  var out = JSMap<Double>()
  for c in keys where chosen.contains(c) { out[c] = chosen[c]! }
  return out
}

func pinnedGroupMembers(_ s: BrowserState) -> OrderedSet<String> {
  var ids = OrderedSet<String>()
  for g in s.groups.values where g.pinned { for id in g.tabIds { ids.insert(id) } }
  return ids
}

struct PinSource {
  var id: String
  var url: String
  var title: String
  var customTitle: JSONValue?
  var customIcon: JSONValue?
  var pinnedUrl: String?
  var row: Bool

  init(_ t: Tab) {
    id = t.pinKeyOrId
    url = t.url
    title = t.title
    customTitle = nullable(t.customTitle, absent: t.absent.contains("customTitle"))
    customIcon = nullable(t.customIcon, absent: t.absent.contains("customIcon"))
    pinnedUrl = t.absent.contains("pinnedUrl") ? nil : t.pinnedUrl
    row = t.pinnedAsRow == true
  }

  init(_ p: ParkedTab) {
    let snap = p.snapshot
    id = p.id
    url = snap.url
    title = snap.title
    customTitle = nullable(snap.customTitle, absent: snap.absent.contains("customTitle"))
    customIcon = nullable(snap.customIcon, absent: snap.absent.contains("customIcon"))
    pinnedUrl = snap.absent.contains("pinnedUrl") ? nil : snap.pinnedUrl
    row = snap.pinnedAsRow == true
  }
}

struct GroupLook {
  var key: String
  var name: String
  var icon: JSONValue?
  var color: JSONValue?

  init(_ g: TabGroup) {
    key = g.pinKeyOrId
    name = g.name
    icon = nullable(g.icon, absent: g.absent.contains("icon"))
    color = nullable(g.color, absent: g.absent.contains("color"))
  }

  init(_ g: ParkedGroup) {
    key = g.id
    name = g.name
    icon = nullable(g.icon, absent: g.absent.contains("icon"))
    color = nullable(g.color, absent: g.absent.contains("color"))
  }
}

enum PinNode {
  case pin(PinSource)
  case group(String)
}

public extension PinnedSync {
  static func pinnedValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups) throws -> PinnedExtraction {
    var area: [PinNode] = []
    var inside: [String: [PinNode]] = [:]
    var info: [String: (look: GroupLook, parent: String?)] = [:]
    func enter(_ chain: [GroupLook]) {
      for (i, g) in chain.enumerated() {
        if info[g.key] != nil { continue }
        let parent = i > 0 ? chain[i - 1].key : nil
        info[g.key] = (g, parent)
        inside[g.key] = []
        if let parent { inside[parent]!.append(.group(g.key)) } else { area.append(.group(g.key)) }
      }
    }
    let pinned = s.groups.values.filter { $0.pinned && $0.profileId == profileId }
    var pinnedGroupOf: [String: TabGroup] = [:]
    for g in pinned.map({ ($0, Groups.depthOf(s.groups, $0.id)) }).stableSorted(by: { $0.1 < $1.1 }).map(\.0) {
      for id in g.tabIds { pinnedGroupOf[id] = g }
    }
    var seen = Set<String>()
    for w in homeFirst(s, profileId) {
      for id in w.tabIds {
        guard let t = s.tabs[id], t.profileId == profileId, !seen.contains(t.pinKeyOrId) else { continue }
        if t.pinned {
          area.append(.pin(PinSource(t)))
        } else if let g = pinnedGroupOf[id] {
          let chain = Groups.ancestorIds(s.groups, g.id).reversed().map { s.groups[$0]! }.filter(\.pinned) + [g]
          enter(chain.map(GroupLook.init))
          inside[g.pinKeyOrId]!.append(.pin(PinSource(t)))
        } else {
          continue
        }
        seen.insert(t.pinKeyOrId)
      }
    }
    let park = s.parkedPins[profileId]
    var parkGroups: [String: ParkedGroup] = [:]
    for g in park?.groups ?? [] { parkGroups[g.id] = g }
    func parkChain(_ key: String) -> [GroupLook] {
      var chain: [GroupLook] = []
      var g = parkGroups[key]
      while let current = g, !chain.contains(where: { $0.key == current.id }) {
        chain.insert(GroupLook(current), at: 0)
        g = truthy(current.parentId) ? parkGroups[current.parentId!] : nil
      }
      return chain
    }
    for p in park?.tabs ?? [] {
      if !truthy(p.groupId) {
        area.append(.pin(PinSource(p)))
      } else if parkGroups[p.groupId!] != nil {
        enter(parkChain(p.groupId!))
        inside[p.groupId!]!.append(.pin(PinSource(p)))
      }
    }
    for g in park?.groups ?? [] { enter(parkChain(g.id)) }
    var values = OrderedDict<String, JSONValue>()
    let chosen = chosenIn(s, profileId)
    let sync = s.pinSync[profileId] ?? JSMap()
    func baseTab(_ key: String) -> JSONValue? { c.base("pin:t:\(key)") }
    func baseGroup(_ key: String) -> JSONValue? { c.base("pin:g:\(key)") }
    func pinValue(_ t: PinSource, _ group: String?, _ pos: String) -> JSONValue {
      let was = baseTab(t.id)
      let entry: JSONValue? = truthy(was) ? sync[t.id] : nil
      var waiting = false
      if group == nil, truthy(was?["g"]), let entry, jsStrict(entry["g"], was?["g"]) {
        let w = entry["w"]
        let until: Double = nullish(w) ? 0 : (w?.number ?? .nan)
        waiting = c.now < until
      }
      let url = group != nil ? t.url : ((t.pinnedUrl ?? "").isEmpty ? t.url : t.pinnedUrl!)
      return record([
        ("g", waiting ? was?["g"] : JSONValue(group)), ("u", .string(url)), ("t", t.customTitle), ("i", t.customIcon), ("ti", .string(t.title)),
        ("pos", waiting ? was?["pos"] : .string(pos)),
      ])
    }
    func flat(_ key: String) -> [(pin: PinSource, inner: String)] {
      inside[key]!.flatMap { n -> [(pin: PinSource, inner: String)] in
        switch n {
        case .pin(let p): return [(p, key)]
        case .group(let g): return flat(g)
        }
      }
    }
    func nestUnder(_ key: String) {
      for n in inside[key]! {
        guard case .group(let child) = n else { continue }
        let g = info[child]!.look
        values["\(nest)g:\(child)"] = record([("n", .string(g.name)), ("i", g.icon), ("c", legacyColor(g.color)), ("p", .string(key))])
        nestUnder(child)
      }
    }
    func legacyRank(_ n: PinNode) -> Int {
      if case .pin(let p) = n { return p.row ? 1 : 0 }
      return 2
    }
    area = area.stableSorted { legacyRank($0) < legacyRank($1) }
    let areaPositions = try c.positions(area.map { n -> String? in
      switch n {
      case .pin(let p): return nullish(baseTab(p.id)?["g"]) ? baseTab(p.id)?["pos"]?.string : nil
      case .group(let g): return baseGroup(g)?["pos"]?.string
      }
    })
    for (i, n) in area.enumerated() {
      switch n {
      case .pin(let p):
        values["pin:t:\(p.id)"] = pinValue(p, nil, areaPositions[i])
      case .group(let key):
        let g = info[key]!.look
        values["pin:g:\(key)"] = record([("n", .string(g.name)), ("i", g.icon), ("c", legacyColor(g.color)), ("pos", .string(areaPositions[i]))])
        let members = flat(key)
        let positions = try c.positions(members.map { m -> String? in
          jsStrict(baseTab(m.pin.id)?["g"], .string(key)) ? baseTab(m.pin.id)?["pos"]?.string : nil
        })
        for (j, m) in members.enumerated() {
          values["pin:t:\(m.pin.id)"] = pinValue(m.pin, key, positions[j])
          if m.inner != key { values["\(nest)t:\(m.pin.id)"] = ["g": .string(m.inner)] }
        }
        nestUnder(key)
      }
    }
    func choiceOf(_ k: String) -> String {
      let rest = k.jsSlice(6)
      return starts(k, "pin:g:") ? groupChoiceKey(rest) : placeChoiceKey(rest)
    }
    return PinnedExtraction(
      values: values.map { ($0.key, $0.value) },
      ignore: { starts($0, row) },
      republish: { k in starts(k, "pin:") && chosen.contains(choiceOf(k)) && !c.queued(k) },
      settled: { keys in settlement(chosen, keys.filter { starts($0, "pin:") }.map(choiceOf)) })
  }

  static func orderValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups) -> PinnedExtraction {
    let home = pinnedHomeWindow(s, profileId)
    let shown = home != nil && shownIn(s, profileId).contains { $0.id == home!.id }
    func ignore(_ k: String) -> Bool { c.remote("pin:g:\(k.jsSlice(order.count))") != .null }
    if !shown && s.parkedPins[profileId] == nil { return PinnedExtraction(values: [], ignore: ignore, republish: nil, settled: nil) }
    let keys = shown ? pinnedAreaKeys(s, home!, profileId) : parkedAreaKeys(s, profileId)
    let anchors = anchorsOf(keys)
    let chosen = chosenIn(s, profileId)
    func choiceOf(_ k: String) -> String { orderChoiceKey(k.jsSlice(order.count)) }
    let rows = Set(keys.filter { starts($0, "t:") }.map { $0.jsSlice(2) })
    var values = OrderedDict<String, JSONValue>()
    for (group, a) in anchors {
      let key = "\(order)\(group)"
      let was = c.base(key)
      let since = c.stamp(key)
      func changedSince(_ other: String) -> Bool {
        guard let since else { return false }
        return jsKeyPrecedes(since, c.stamp(other) ?? "")
      }
      let wasA = was?["a"]
      let anchored = truthy(wasA)
      let pin: JSONValue? = anchored ? c.remote("pin:t:\(jsText(wasA))") : nil
      let leftRows = anchored && changedSince("pin:t:\(jsText(wasA))") && (pin == .null || (truthy(pin) && pin?["g"] != .null))
      let madeTile = anchored && changedSince("\(row)\(jsText(wasA))") && c.remote("\(row)\(jsText(wasA))") != .number(1)
      let settled = leftRows || madeTile
      let waiting = !chosen.contains(orderChoiceKey(group)) && anchored && !jsStrict(wasA, JSONValue(a)) && !(wasA?.string.map(rows.contains) ?? false) && !settled
      values[key] = waiting ? was! : ["a": JSONValue(a)]
    }
    return PinnedExtraction(
      values: values.map { ($0.key, $0.value) }, ignore: ignore, republish: { k in chosen.contains(choiceOf(k)) && !c.queued(k) },
      settled: { keys in settlement(chosen, keys.map(choiceOf)) })
  }

  static func rowValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups) -> PinnedExtraction {
    var values = OrderedDict<String, JSONValue>()
    var known = Set<String>()
    let chosen = chosenIn(s, profileId)
    func mark(_ key: String, _ isRow: Bool) {
      if isRow {
        values["\(row)\(key)"] = 1
      } else if chosen.contains(key) || c.base("\(row)\(key)") != nil {
        values["\(row)\(key)"] = 0
      }
    }
    for w in homeFirst(s, profileId) {
      for id in w.tabIds {
        guard let t = s.tabs[id], t.pinned, t.profileId == profileId, !known.contains(t.pinKeyOrId) else { continue }
        known.insert(t.pinKeyOrId)
        mark(t.pinKeyOrId, t.pinnedAsRow == true)
      }
    }
    for p in s.parkedPins[profileId]?.tabs ?? [] {
      if truthy(p.groupId) || known.contains(p.id) { continue }
      known.insert(p.id)
      mark(p.id, p.snapshot.pinnedAsRow == true)
    }
    func keyOf(_ k: String) -> String { k.jsSlice(row.count) }
    return PinnedExtraction(
      values: values.map { ($0.key, $0.value) },
      ignore: { k in !known.contains(keyOf(k)) && c.base("pin:t:\(keyOf(k))") == nil },
      republish: { k in chosen.contains(keyOf(k)) && !c.queued(k) },
      settled: { keys in settlement(chosen, keys.map(keyOf)) })
  }

  static func groupLookValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups) -> PinnedExtraction {
    var values = OrderedDict<String, JSONValue>()
    var known = Set<String>()
    func offer(_ key: String, _ color: String?) {
      if known.contains(key) { return }
      known.insert(key)
      if color == noBox { values["\(groupLook)\(key)"] = .string(noBox) }
    }
    for g in s.groups.values where g.pinned && g.profileId == profileId { offer(g.pinKeyOrId, g.color) }
    for g in s.parkedPins[profileId]?.groups ?? [] { offer(g.id, g.color) }
    func records(_ key: String) -> [String] { ["pin:g:\(key)", "\(nest)g:\(key)"] }
    func gone(_ key: String) -> Bool { records(key).contains(where: c.known) && records(key).allSatisfy { nullish(c.remote($0)) } }
    func keyOf(_ k: String) -> String { k.jsSlice(groupLook.count) }
    return PinnedExtraction(values: values.map { ($0.key, $0.value) }, ignore: { k in !known.contains(keyOf(k)) && !gone(keyOf(k)) }, republish: nil, settled: nil)
  }

  static func homeValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups) -> PinnedExtraction {
    var values = OrderedDict<String, JSONValue>()
    var known = Set<String>()
    var held = Set<String>()
    func offer(_ key: String, _ member: Bool, _ home: String?) {
      if known.contains(key) { return }
      known.insert(key)
      if !member { return }
      let k = "\(PinnedSync.home)\(key)"
      if !truthy(home) {
        held.insert(key)
      } else if c.base(k) != nil || nullish(c.remote(k)) {
        values[k] = .string(home!)
      }
    }
    let members = pinnedGroupMembers(s)
    for w in homeFirst(s, profileId) {
      for id in w.tabIds {
        guard let t = s.tabs[id], t.profileId == profileId, t.pinned || members.contains(id) else { continue }
        offer(t.pinKeyOrId, !t.pinned, t.pinnedUrl)
      }
    }
    for p in s.parkedPins[profileId]?.tabs ?? [] {
      offer(p.id, truthy(p.groupId), truthy(p.snapshot.pinnedUrl) ? p.snapshot.pinnedUrl : p.snapshot.url)
    }
    func keyOf(_ k: String) -> String { k.jsSlice(PinnedSync.home.count) }
    func unpinned(_ key: String) -> Bool { c.known("pin:t:\(key)") && c.remote("pin:t:\(key)") == .null }
    return PinnedExtraction(
      values: values.map { ($0.key, $0.value) },
      ignore: { k in held.contains(keyOf(k)) || (!known.contains(keyOf(k)) && c.base("pin:t:\(keyOf(k))") == nil && !unpinned(keyOf(k))) },
      republish: nil, settled: nil)
  }

  static func tileFolderValues(_ s: BrowserState, _ profileId: String, _ c: PinnedLookups, _ memory: TileFolderMemory) -> PinnedExtraction {
    var values = OrderedDict<String, JSONValue>()
    var known = Set<String>()
    var local = OrderedDict<String, TileFolder>()
    func mark(_ key: String, _ folder: TileFolder?) {
      known.insert(key)
      guard let folder else { return }
      values["\(tileFolder)\(key)"] = ["f": .string(folder.id)]
      let was = local[folder.id]
      if was == nil || (folder.renamedAt ?? -1) > (was!.renamedAt ?? -1) { local[folder.id] = folder }
    }
    func unpinned(_ key: String) -> Bool { c.known("pin:t:\(key)") && c.remote("pin:t:\(key)") == .null }
    for w in homeFirst(s, profileId) {
      for id in w.tabIds {
        guard let t = s.tabs[id], t.pinned, t.profileId == profileId, !known.contains(t.pinKeyOrId) else { continue }
        mark(t.pinKeyOrId, tileFolderOf(t))
      }
    }
    for p in s.parkedPins[profileId]?.tabs ?? [] where !truthy(p.groupId) && !known.contains(p.id) {
      mark(p.id, p.snapshot.pinnedAsRow == true ? nil : p.snapshot.tileFolder)
    }
    for (folderId, folder) in local {
      let key = "\(folderName)\(folderId)"
      let synced = c.base(key)
      if folder.renamedAt != nil && syncedName(synced) != folder.name {
        values[key] = ["n": .string(folder.name)]
      } else if let synced {
        values[key] = synced
      }
    }
    let had = memory.swap(profileId, local.keys)
    func keyOf(_ k: String) -> String { k.jsSlice(tileFolder.count) }
    return PinnedExtraction(
      values: values.map { ($0.key, $0.value) },
      ignore: { k in
        if starts(k, folderName) { return !had.contains(k.jsSlice(folderName.count)) }
        return !known.contains(keyOf(k)) && c.base("pin:t:\(keyOf(k))") == nil && !unpinned(keyOf(k))
      }, republish: nil, settled: nil)
  }

  static func shownIn(_ s: BrowserState, _ profileId: String) -> [BrowserWindow] {
    pinnedOpenWindows(s).filter { w in w.tabIds.contains { s.tabs[$0]?.profileId == profileId } }
  }
}

func uniqueVisible(_ visible: [(key: String, value: JSONValue)]) -> OrderedDict<String, JSONValue> {
  var out = OrderedDict<String, JSONValue>()
  for (k, v) in visible { out[k] = v }
  return out
}

func touched(_ t: Table<Tab>) -> Table<Tab> {
  var out = t
  out.touch()
  return out
}

extension Tab {
  mutating func setNullable(_ key: String, _ value: JSONValue?) {
    let text = value?.string
    switch key {
    case "customTitle": customTitle = text
    case "customIcon": customIcon = text
    case "pinnedUrl": pinnedUrl = text
    case "favicon": favicon = text
    default: break
    }
    if value == nil { markAbsent([key]) }
  }
}

public extension Session {
  func writeFromSync(_ next: BrowserState) {
    memory.fromSyncDepth += 1
    defer { memory.fromSyncDepth -= 1 }
    set(next)
  }

  func settlePinChoices(_ profileId: String, _ published: JSMap<Double>) {
    let now = state.pinChoices
    guard let mine = now[profileId] else { return }
    let left = mine.filter { key, n in published[key] != n }
    if left.count == mine.count { return }
    var next = state
    var choices = now
    if left.isEmpty { choices.remove([profileId]) } else { choices[profileId] = left }
    next.pinChoices = choices
    set(next)
  }

  func noteRemotePinDeletion(_ profileId: String) {
    memory.remotePinDeletions[profileId] = (memory.remotePinDeletions[profileId] ?? 0) + 1
  }

  func applySyncedPinOrder(_ profileId: String, _ visible: [(key: String, value: JSONValue)]) -> Bool {
    let s = state
    let shown = uniqueVisible(visible)
    func anchorOf(_ group: String) -> String?? { anchorIn(shown["\(PinnedSync.order)\(group)"]) }
    var windows = s.windows
    var groups = s.groups
    var moved = false
    for w in PinnedSync.shownIn(s, profileId) {
      let tabIds = arrangePinnedArea(s, w, profileId, anchorOf)
      if tabIds == w.tabIds { continue }
      var window = w
      window.tabIds = tabIds
      windows[w.id] = window
      moved = true
      groups = Groups.syncGroupOrder(groups, window)
    }
    let park = s.parkedPins[profileId]
    let parked = park.map { arrangeParked($0, anchorOf) }
    let parkMoved = park != nil && parked! != park!
    if !moved && !parkMoved { return true }
    var next = state
    next.windows = windows
    next.groups = groups
    if parkMoved { next.parkedPins[profileId] = parked! }
    writeFromSync(next)
    return true
  }

  func applySyncedPinRows(_ profileId: String, _ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?) -> Bool {
    let s = state
    func keyOf(_ k: String) -> String { k.jsSlice(PinnedSync.row.count) }
    let shown = uniqueVisible(visible)
    let rows = Set(shown.filter { $0.value == .number(1) }.map { keyOf($0.key) })
    func pos(_ t: Tab?) -> JSONValue? { t.flatMap { base("pin:t:\($0.pinKeyOrId)")?["pos"] } }
    let stillMarked = Set(shown.keys.map(keyOf))
    let touchedKeys = Set(changed.map(keyOf).filter(stillMarked.contains))
    func wants(_ key: String, _ isRow: Bool) -> Bool { touchedKeys.contains(key) && isRow != rows.contains(key) }
    var tabs = touched(s.tabs)
    var windows = s.windows
    windows.touch()
    var edited = false
    func anchorOf(_ group: String) -> String?? { anchorIn(base("\(PinnedSync.order)\(group)")) }
    for w in pinnedOpenWindows(s) {
      var moved = false
      for id in w.tabIds {
        guard let t = tabs[id], t.pinned, t.profileId == profileId, wants(t.pinKeyOrId, t.pinnedAsRow == true) else { continue }
        var changedTab = t
        changedTab.pinnedAsRow = rows.contains(t.pinKeyOrId) ? true : nil
        tabs[id] = changedTab
        moved = true
      }
      if !moved { continue }
      var ids = w.tabIds
      let slots = ids.indices.filter { i in
        guard let t = tabs[ids[i]] else { return false }
        return t.pinned && t.profileId == profileId && pos(t) != nil
      }
      let sorted = jsSort(slots.map { ids[$0] }) { a, z in
        let pa = pos(tabs[a])
        let pz = pos(tabs[z])
        return jsLess(pa, pz) ? -1 : jsLess(pz, pa) ? 1 : 0
      }
      for (i, slot) in slots.enumerated() { ids[slot] = sorted[i] }
      var sectioned = w
      sectioned.tabIds = Groups.orderSections(pinnedFirst(ids, tabs, s.groups), tabs, s.groups)
      var view = s
      view.tabs = tabs
      sectioned.tabIds = arrangePinnedArea(view, sectioned, profileId, anchorOf)
      windows[w.id] = sectioned
      edited = true
    }
    let park = s.parkedPins[profileId]
    var parked: [ParkedTab]? = nil
    if let park {
      let marked = park.tabs.map { p -> ParkedTab in
        if truthy(p.groupId) || !wants(p.id, p.snapshot.pinnedAsRow == true) { return p }
        var q = p
        q.snapshot.pinnedAsRow = rows.contains(p.id) ? true : nil
        return q
      }
      var staged = park
      staged.tabs = marked
      parked = arrangeParked(staged, anchorOf).tabs
    }
    let parkEdited = park != nil && parked!.enumerated().contains { $0.element != park!.tabs[$0.offset] }
    if !edited && !parkEdited { return true }
    var next = state
    next.tabs = tabs
    next.windows = windows
    if parkEdited {
      var p = park!
      p.tabs = parked!
      next.parkedPins[profileId] = p
    }
    writeFromSync(next)
    return true
  }

  func applySyncedGroupLooks(_ profileId: String, _ visible: [(key: String, value: JSONValue)], _ changed: [String]) -> Bool {
    func keyOf(_ k: String) -> String { k.jsSlice(PinnedSync.groupLook.count) }
    let touchedKeys = Set(changed.map(keyOf))
    if touchedKeys.isEmpty { return true }
    let shown = uniqueVisible(visible)
    func wanted(_ key: String, _ color: JSONValue?) -> JSONValue? {
      if !touchedKeys.contains(key) { return nil }
      let next = lookedColor(legacyColor(color), shown["\(PinnedSync.groupLook)\(key)"])
      if jsStrict(next, color) { return .none }
      return next
    }
    let s = state
    var groups: Table<TabGroup>? = nil
    for g in s.groups.values where g.pinned && g.profileId == profileId {
      guard let color = wanted(g.pinKeyOrId, nullable(g.color, absent: g.absent.contains("color"))) else { continue }
      if groups == nil {
        groups = s.groups
        groups!.touch()
      }
      var changedGroup = g
      changedGroup.color = color.string
      groups![g.id] = changedGroup
    }
    let park = s.parkedPins[profileId]
    let parkedGroups = park?.groups.map { g -> ParkedGroup in
      guard let color = wanted(g.id, nullable(g.color, absent: g.absent.contains("color"))) else { return g }
      var q = g
      q.color = color.string
      return q
    }
    let parkEdited = park != nil && parkedGroups!.enumerated().contains { $0.element != park!.groups[$0.offset] }
    if groups == nil && !parkEdited { return true }
    var next = state
    if let groups { next.groups = groups }
    if parkEdited {
      var p = park!
      p.groups = parkedGroups!
      next.parkedPins[profileId] = p
    }
    writeFromSync(next)
    return true
  }

  func applySyncedPinHomes(_ profileId: String, _ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?) -> Bool {
    func keyOf(_ k: String) -> String { k.jsSlice(PinnedSync.home.count) }
    let shown = uniqueVisible(visible)
    var incoming = OrderedDict<String, String>()
    for k in changed {
      if let home = syncedHome(shown[k]) { incoming[keyOf(k)] = home }
    }
    if incoming.isEmpty { return true }
    func wanted(_ key: String, _ current: String?) -> String? {
      guard let home = incoming[key], home != current else { return nil }
      let synced = syncedHome(base("\(PinnedSync.home)\(key)"))
      return !truthy(current) || synced == nil || synced == current ? home : nil
    }
    let s = state
    var tabs: Table<Tab>? = nil
    for id in pinnedGroupMembers(s) {
      guard let t = s.tabs[id], t.profileId == profileId, !t.pinned else { continue }
      guard let home = wanted(t.pinKeyOrId, t.absent.contains("pinnedUrl") ? nil : t.pinnedUrl) else { continue }
      if tabs == nil { tabs = touched(s.tabs) }
      var changedTab = t
      changedTab.pinnedUrl = home
      tabs![id] = changedTab
    }
    let park = s.parkedPins[profileId]
    let parked = park?.tabs.map { p -> ParkedTab in
      let snap = p.snapshot
      let current = truthy(snap.pinnedUrl) ? snap.pinnedUrl : snap.url
      guard truthy(p.groupId), let home = wanted(p.id, current) else { return p }
      var q = p
      if snap.url != home {
        q.restoreFrom = nil
        q.snapshot.url = home
      }
      q.snapshot.pinnedUrl = home
      return q
    }
    let parkEdited = park != nil && parked!.enumerated().contains { $0.element != park!.tabs[$0.offset] }
    if tabs == nil && !parkEdited { return true }
    var next = state
    if let tabs { next.tabs = tabs }
    if parkEdited {
      var p = park!
      p.tabs = parked!
      next.parkedPins[profileId] = p
    }
    writeFromSync(next)
    return true
  }

  func applySyncedTileFolders(_ profileId: String, _ visible: [(key: String, value: JSONValue)], _ changed: [String]) -> Bool {
    let s = state
    func keyOf(_ k: String) -> String { k.jsSlice(PinnedSync.tileFolder.count) }
    let touchedKeys = Set(changed.filter { !starts($0, PinnedSync.folderName) }.map(keyOf))
    let shown = uniqueVisible(visible)
    var names: [String: String] = [:]
    for (k, v) in shown {
      guard starts(k, PinnedSync.folderName), let name = syncedName(v) else { continue }
      names[k.jsSlice(PinnedSync.folderName.count)] = name
    }
    func wanted(_ key: String, _ current: TileFolder?) -> TileFolder? {
      let id = touchedKeys.contains(key) ? syncedFolderId(shown["\(PinnedSync.tileFolder)\(key)"]) : current?.id
      guard let id, !id.isEmpty else { return nil }
      let name = names[id]
      if current?.id == id && (name == nil || name == current!.name) { return current }
      return TileFolder(id: id, name: name ?? (current?.id == id ? current!.name : ""))
    }
    var tabs: Table<Tab>? = nil
    for w in pinnedOpenWindows(s) {
      for id in w.tabIds {
        guard let t = s.tabs[id], t.pinned, t.pinnedAsRow != true, t.profileId == profileId else { continue }
        let folder = wanted(t.pinKeyOrId, t.tileFolder)
        if folder == t.tileFolder { continue }
        if tabs == nil { tabs = touched(s.tabs) }
        tabs![id] = withTileFolder(t, folder)
      }
    }
    let park = s.parkedPins[profileId]
    let parked = park?.tabs.map { p -> ParkedTab in
      if truthy(p.groupId) || p.snapshot.pinnedAsRow == true { return p }
      let folder = wanted(p.id, p.snapshot.tileFolder)
      if folder == p.snapshot.tileFolder { return p }
      var q = p
      q.snapshot.tileFolder = folder
      return q
    }
    let parkEdited = park != nil && parked!.enumerated().contains { $0.element != park!.tabs[$0.offset] }
    if tabs == nil && !parkEdited { return true }
    var next = state
    if let tabs { next.tabs = tabs }
    if parkEdited {
      var p = park!
      p.tabs = parked!
      next.parkedPins[profileId] = p
    }
    writeFromSync(next)
    return true
  }
}
