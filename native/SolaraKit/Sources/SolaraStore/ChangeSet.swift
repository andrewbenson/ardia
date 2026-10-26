import SolaraModel

public struct ChangeSet: Sendable, Equatable {
  public var settingsChanged: [String] = []
  public var settingsRemoved: [String] = []
  public var downloads = false

  public init() {}

  public init(from before: BrowserState, to after: BrowserState) {
    if before.settings != after.settings {
      for (key, value) in after.settings.values where before.settings.values[key] != value { settingsChanged.append(key) }
      for key in before.settings.values.keys where !after.settings.values.contains(key) { settingsRemoved.append(key) }
    }
    downloads = before.downloads != after.downloads
  }

  public var isEmpty: Bool { settingsChanged.isEmpty && settingsRemoved.isEmpty && !downloads }
}

public struct Patch: Sendable, Equatable {
  public let rev: Int
  public var settings: JSONObject?
  public var settingsRemoved: [String]
  public var downloads: [Download]?

  public init(rev: Int, changes: ChangeSet, state: BrowserState) {
    self.rev = rev
    settings = changes.settingsChanged.isEmpty ? nil : JSONObject(changes.settingsChanged.map { ($0, state.settings.values[$0]!) })
    settingsRemoved = changes.settingsRemoved
    downloads = changes.downloads ? state.downloads : nil
  }

  public var json: JSONValue {
    var out: JSONObject = ["rev": JSONValue(rev)]
    if settings != nil || !settingsRemoved.isEmpty {
      var entry = JSONObject()
      if let settings { entry["set"] = .object(settings) }
      if !settingsRemoved.isEmpty { entry["remove"] = JSONValue(settingsRemoved) }
      out["settings"] = .object(entry)
    }
    if let downloads { out["downloads"] = .array(downloads.map { .object($0.json) }) }
    return .object(out)
  }
}
