import SolaraModel

extension BrowserState {
  static func table<V: JSONConvertible>(_ value: JSONValue?) throws -> Table<V> {
    var map = JSMap<V>()
    for (key, item) in value?.object ?? [:] { map[key] = try V(value: item) }
    return Table(map)
  }

  static func list<V: JSONConvertible>(_ value: JSONValue?) throws -> [V] {
    try (value?.array ?? []).map { try V(value: $0) }
  }

  public init(stateJSON json: JSONObject) throws {
    self.init()
    profiles = try Self.table(json["profiles"])
    profileOrder = json["profileOrder"]?.array?.compactMap(\.string) ?? []
    orphanedProfileData = json["orphanedProfileData"]?.array?.compactMap(\.string) ?? []
    windows = try Self.table(json["windows"])
    windowOrder = json["windowOrder"]?.array?.compactMap(\.string) ?? []
    tabs = try Self.table(json["tabs"])
    groups = try Self.table(json["groups"])
    splits = try Self.table(json["splits"])
    peeks = try Self.table(json["peeks"])
    closedTabs = try Self.list(json["closedTabs"])
    closedWindows = try Self.list(json["closedWindows"])
    closedGroups = try Self.list(json["closedGroups"])
    deletedGroups = try Self.list(json["deletedGroups"])
    cleanedTabs = try Self.list(json["cleanedTabs"])
    var privateCleaned = JSMap<[ClosedTab]>()
    for (key, value) in json["privateCleanedTabs"]?.object ?? [:] { privateCleaned[key] = try Self.list(value) }
    privateCleanedTabs = privateCleaned
    var mutes = JSMap<JSMap<Bool>>()
    for (key, value) in json["privateSiteMutes"]?.object ?? [:] {
      var mine = JSMap<Bool>()
      for (host, muted) in value.object ?? [:] { if let b = muted.bool { mine[host] = b } }
      mutes[key] = mine
    }
    privateSiteMutes = mutes
    parkedPins = try Self.table(json["parkedPins"])
    var choices = JSMap<JSMap<Double>>()
    for (key, value) in json["pinChoices"]?.object ?? [:] {
      var mine = JSMap<Double>()
      for (k, n) in value.object ?? [:] { if let d = n.number { mine[k] = d } }
      choices[key] = mine
    }
    pinChoices = Table(choices)
    var sync = JSMap<JSMap<JSONValue>>()
    for (key, value) in json["pinSync"]?.object ?? [:] { sync[key] = value.object ?? [:] }
    pinSync = Table(sync)
    downloads = (json["downloads"]?.array ?? []).compactMap { $0.object.map(Download.init) }
    settings = Settings(values: json["settings"]?.object ?? Settings.defaults.values)
    let ui = json["ui"]?.object ?? [:]
    self.ui = FocusState(
      focusedWindowId: ui["focusedWindowId"]?.string, focusOrder: ui["focusOrder"]?.array?.compactMap(\.string) ?? [],
      lastProfileId: ui["lastProfileId"]?.string)
    let caches = json["caches"]?.object ?? [:]
    var hints = JSMap<[HistoryHint]>()
    for (profileId, list) in caches["historyHints"]?.object ?? [:] {
      hints[profileId] = (list.array ?? []).map { HistoryHint(url: $0["url"]?.string ?? "", title: $0["title"]?.string ?? "", favicon: $0["favicon"]?.string) }
    }
    self.caches.historyHints = hints
    self.caches.playingAudio = Set(caches["playingAudio"]?.array?.compactMap(\.string) ?? [])
    self.caches.launchBackdrop = caches["launchBackdrop"] ?? .null
  }

  public var stateJSON: JSONObject {
    func table<V: JSONConvertible>(_ t: Table<V>) -> JSONValue { .object(t.map.mapValues(\.jsonValue)) }
    return [
      "profiles": table(profiles), "profileOrder": JSONValue(profileOrder), "orphanedProfileData": JSONValue(orphanedProfileData),
      "windows": table(windows), "windowOrder": JSONValue(windowOrder), "tabs": table(tabs), "groups": table(groups), "splits": table(splits),
      "peeks": table(peeks), "closedTabs": .array(closedTabs.map(\.jsonValue)), "closedWindows": .array(closedWindows.map(\.jsonValue)),
      "closedGroups": .array(closedGroups.map(\.jsonValue)), "deletedGroups": .array(deletedGroups.map(\.jsonValue)),
      "cleanedTabs": .array(cleanedTabs.map(\.jsonValue)),
      "privateCleanedTabs": .object(privateCleanedTabs.mapValues { .array($0.map(\.jsonValue)) }),
      "privateSiteMutes": .object(privateSiteMutes.mapValues { .object($0.mapValues(JSONValue.bool)) }), "parkedPins": table(parkedPins),
      "pinChoices": .object(pinChoices.map.mapValues { .object($0.mapValues(JSONValue.number)) }), "pinSync": .object(pinSync.map.mapValues { .object($0) }),
      "downloads": .array(downloads.map { .object($0.json) }), "settings": settings.json,
      "ui": ["focusedWindowId": JSONValue(ui.focusedWindowId), "focusOrder": JSONValue(ui.focusOrder), "lastProfileId": JSONValue(ui.lastProfileId)],
    ]
  }
}

extension StoreMemory {
  public init(replayJSON json: JSONObject) {
    self.init(ids: IdSource(launch: json["launch"]?.string ?? "x", counter: json["counter"]?.int ?? 0))
    navSeq = json["navSeq"]?.int ?? 0
    lastPinChoice = json["lastPinChoice"]?.number ?? 0
    var deletions = JSMap<Double>()
    for (k, v) in json["remotePinDeletions"]?.object ?? [:] { deletions[k] = v.number ?? 0 }
    remotePinDeletions = deletions
    endedPrivateDownloads = Set(json["endedPrivateDownloads"]?.array?.compactMap(\.string) ?? [])
    closingWindows = Set(json["closingWindows"]?.array?.compactMap(\.string) ?? [])
    lastTabKeepsWindow = json["lastTabKeepsWindow"]?.truthy ?? false
    fromSyncDepth = json["fromSyncDepth"]?.int ?? 0
  }
}
