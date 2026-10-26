import SolaraModel

public struct TableChange: Sendable, Equatable {
  public var upserted: [String] = []
  public var removed: [String] = []
  public var reordered = false

  public var isEmpty: Bool { upserted.isEmpty && removed.isEmpty && !reordered }

  public init() {}

  init<V>(_ after: Table<V>, _ before: Table<V>) {
    guard after.changed(from: before) else { return }
    for (id, value) in after.map where before.map[id] != value { upserted.append(id) }
    for id in before.keys where !after.contains(id) { removed.append(id) }
    let gone = Set(removed)
    let kept = before.keys.filter { !gone.contains($0) }
    let fresh = Set(upserted.filter { !before.contains($0) })
    let order = after.keys.filter { !fresh.contains($0) }
    reordered = kept != order || after.keys.suffix(fresh.count).contains { !fresh.contains($0) }
  }
}

public struct ChangeSet: Sendable, Equatable {
  public var profiles = TableChange()
  public var windows = TableChange()
  public var tabs = TableChange()
  public var groups = TableChange()
  public var splits = TableChange()
  public var peeks = TableChange()
  public var parkedPins = TableChange()
  public var pinChoices = TableChange()
  public var pinSync = TableChange()
  public var lists: Set<String> = []
  public var settingsChanged: [String] = []
  public var settingsRemoved: [String] = []

  public init() {}

  public init(from before: BrowserState, to after: BrowserState) {
    profiles = TableChange(after.profiles, before.profiles)
    windows = TableChange(after.windows, before.windows)
    tabs = TableChange(after.tabs, before.tabs)
    groups = TableChange(after.groups, before.groups)
    splits = TableChange(after.splits, before.splits)
    peeks = TableChange(after.peeks, before.peeks)
    parkedPins = TableChange(after.parkedPins, before.parkedPins)
    pinChoices = TableChange(after.pinChoices, before.pinChoices)
    pinSync = TableChange(after.pinSync, before.pinSync)
    if after.profileOrder != before.profileOrder { lists.insert("profileOrder") }
    if after.orphanedProfileData != before.orphanedProfileData { lists.insert("orphanedProfileData") }
    if after.windowOrder != before.windowOrder { lists.insert("windowOrder") }
    if after.closedTabs != before.closedTabs { lists.insert("closedTabs") }
    if after.closedWindows != before.closedWindows { lists.insert("closedWindows") }
    if after.closedGroups != before.closedGroups { lists.insert("closedGroups") }
    if after.deletedGroups != before.deletedGroups { lists.insert("deletedGroups") }
    if after.cleanedTabs != before.cleanedTabs { lists.insert("cleanedTabs") }
    if after.privateCleanedTabs != before.privateCleanedTabs { lists.insert("privateCleanedTabs") }
    if after.privateSiteMutes != before.privateSiteMutes { lists.insert("privateSiteMutes") }
    if after.downloads != before.downloads { lists.insert("downloads") }
    if after.ui != before.ui { lists.insert("ui") }
    if after.caches != before.caches { lists.insert("caches") }
    if before.settings != after.settings {
      for (key, value) in after.settings.values where before.settings.values[key] != value { settingsChanged.append(key) }
      for key in before.settings.values.keys where !after.settings.values.contains(key) { settingsRemoved.append(key) }
    }
  }

  public var isEmpty: Bool {
    profiles.isEmpty && windows.isEmpty && tabs.isEmpty && groups.isEmpty && splits.isEmpty && peeks.isEmpty && parkedPins.isEmpty
      && pinChoices.isEmpty && pinSync.isEmpty && lists.isEmpty && settingsChanged.isEmpty && settingsRemoved.isEmpty
  }

  public var downloads: Bool { lists.contains("downloads") }
  public var settings: Bool { !settingsChanged.isEmpty || !settingsRemoved.isEmpty }
}

struct TablePatch: Sendable, Equatable {
  var upsert: [JSONValue]
  var remove: [String]
  var order: [String]?

  init?<V>(_ change: TableChange, _ table: Table<V>, encode: (String, V) -> JSONValue) {
    if change.isEmpty { return nil }
    upsert = change.upserted.compactMap { id in table[id].map { encode(id, $0) } }
    remove = change.removed
    order = change.reordered ? table.keys : nil
  }

  var json: JSONValue {
    var out: JSONObject = ["upsert": .array(upsert), "remove": JSONValue(remove)]
    if let order { out["order"] = JSONValue(order) }
    return .object(out)
  }
}

public struct Patch: Sendable, Equatable {
  public let rev: Int
  var tables: [(String, TablePatch)] = []
  var values: JSONObject = [:]
  public var settings: JSONObject? = nil
  public var settingsRemoved: [String] = []

  public static func == (a: Patch, b: Patch) -> Bool {
    a.rev == b.rev && a.tables.map(\.0) == b.tables.map(\.0) && a.tables.map(\.1) == b.tables.map(\.1) && a.values == b.values
      && a.settings == b.settings && a.settingsRemoved == b.settingsRemoved
  }

  public init(rev: Int, changes: ChangeSet, state s: BrowserState) {
    self.rev = rev
    func add<V>(_ name: String, _ change: TableChange, _ table: Table<V>, _ encode: (String, V) -> JSONValue) {
      if let patch = TablePatch(change, table, encode: encode) { tables.append((name, patch)) }
    }
    add("profiles", changes.profiles, s.profiles) { _, v in v.jsonValue }
    add("windows", changes.windows, s.windows) { _, v in v.jsonValue }
    add("tabs", changes.tabs, s.tabs) { _, v in v.jsonValue }
    add("groups", changes.groups, s.groups) { _, v in v.jsonValue }
    add("splits", changes.splits, s.splits) { _, v in v.jsonValue }
    add("peeks", changes.peeks, s.peeks) { id, v in
      var o = v.json
      o["windowId"] = .string(id)
      return .object(o)
    }
    add("parkedPins", changes.parkedPins, s.parkedPins) { id, v in
      var o = v.json
      o["profileId"] = .string(id)
      return .object(o)
    }
    add("pinChoices", changes.pinChoices, s.pinChoices) { id, v in ["profileId": .string(id), "table": .object(v.mapValues(JSONValue.number))] }
    add("pinSync", changes.pinSync, s.pinSync) { id, v in ["profileId": .string(id), "table": .object(v)] }
    for name in changes.lists.sorted() {
      switch name {
      case "profileOrder": values[name] = JSONValue(s.profileOrder)
      case "orphanedProfileData": values[name] = JSONValue(s.orphanedProfileData)
      case "windowOrder": values[name] = JSONValue(s.windowOrder)
      case "closedTabs": values[name] = .array(s.closedTabs.map(\.jsonValue))
      case "closedWindows": values[name] = .array(s.closedWindows.map(\.jsonValue))
      case "closedGroups": values[name] = .array(s.closedGroups.map(\.jsonValue))
      case "deletedGroups": values[name] = .array(s.deletedGroups.map(\.jsonValue))
      case "cleanedTabs": values[name] = .array(s.cleanedTabs.map(\.jsonValue))
      case "privateCleanedTabs": values[name] = .object(s.privateCleanedTabs.mapValues { .array($0.map(\.jsonValue)) })
      case "privateSiteMutes": values[name] = .object(s.privateSiteMutes.mapValues { .object($0.mapValues(JSONValue.bool)) })
      case "downloads": values[name] = .array(s.downloads.map { .object($0.json) })
      case "ui":
        values[name] = [
          "focusedWindowId": JSONValue(s.ui.focusedWindowId), "focusOrder": JSONValue(s.ui.focusOrder), "lastProfileId": JSONValue(s.ui.lastProfileId),
        ]
      default: break
      }
    }
    settings = changes.settingsChanged.isEmpty ? nil : JSONObject(changes.settingsChanged.map { ($0, s.settings.values[$0]!) })
    settingsRemoved = changes.settingsRemoved
  }

  public var downloads: [Download]? { values["downloads"]?.array?.compactMap { $0.object.map(Download.init) } }

  public var json: JSONValue {
    var out: JSONObject = ["rev": JSONValue(rev)]
    for (name, table) in tables { out[name] = table.json }
    for (name, value) in values { out[name] = value }
    if settings != nil || !settingsRemoved.isEmpty {
      var entry = JSONObject()
      if let settings { entry["set"] = .object(settings) }
      if !settingsRemoved.isEmpty { entry["remove"] = JSONValue(settingsRemoved) }
      out["settings"] = .object(entry)
    }
    return .object(out)
  }
}
