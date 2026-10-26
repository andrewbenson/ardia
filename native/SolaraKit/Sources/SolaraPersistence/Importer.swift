import Foundation
import SolaraModel
import SolaraStore

public struct ImportResult: Sendable {
  public var state: BrowserState
  public var memory: StoreMemory
  public var persisted: PersistedState
  public var meta: [String: String]
  public var notes: [String]
  public var refusal: String?
}

public struct ImportRefused: Error, CustomStringConvertible {
  public let reason: String
  public var description: String { "the native store refused to import: \(reason)" }
}

public struct LoadContext: Sendable {
  public var env: WebAddressing
  public var config: StoreConfig
  public var memory: StoreMemory
  public var now: Double

  public init(env: WebAddressing = PlainWebAddressing(), config: StoreConfig = StoreConfig(), memory: StoreMemory, now: Double) {
    self.env = env
    self.config = config
    self.memory = memory
    self.now = now
  }

  func session() -> Session {
    Session(state: BrowserState(), memory: memory, env: env, config: config, now: now)
  }
}

public enum Importer {
  static func keepLaunchBackdrop(_ state: inout BrowserState, from session: JSONValue?) {
    if let stored = session?["launchBackdrop"], state.caches.launchBackdrop.isNull { state.caches.launchBackdrop = stored }
  }

  static func counts(_ session: JSONValue?) -> [String: Int] {
    let object = session?.object ?? [:]
    func count(_ key: String) -> Int { object[key]?.array?.count ?? object[key]?.object?.count ?? 0 }
    return [
      "profiles": count("profiles"), "windows": count("windows"), "tabs": count("tabs"), "groups": count("groups"), "splits": count("splits"),
      "closedTabs": count("closedTabs"), "closedWindows": count("closedWindows"), "closedGroups": count("closedGroups"),
      "deletedGroups": count("deletedGroups"), "cleanedTabs": count("cleanedTabs"), "parkedPins": count("parkedPins"),
    ]
  }

  static func counts(_ state: BrowserState, _ doc: SessionDocument) -> [String: Int] {
    [
      "profiles": doc.profiles.count, "windows": doc.windows.count, "tabs": doc.tabs.count, "groups": doc.groups.count, "splits": doc.splits.count,
      "closedTabs": doc.closedTabs.count, "closedWindows": doc.closedWindows.count, "closedGroups": doc.closedGroups.count,
      "deletedGroups": doc.deletedGroups.count, "cleanedTabs": doc.cleanedTabs.count, "parkedPins": doc.parkedPins.count,
    ]
  }

  static func ids(_ session: JSONValue?, _ key: String) -> [String] {
    guard let value = session?[key] else { return [] }
    if let list = value.array { return list.compactMap { $0["id"]?.string } }
    return value.object?.keys ?? []
  }

  static let checkedCounts = ["profiles", "windows", "tabs"]

  static func readableCounts(_ session: JSONValue?) -> [String: Int] {
    var out: [String: Int] = [:]
    for key in checkedCounts {
      let value = session?[key]
      let items = value?.array ?? value?.object?.values ?? []
      out[key] = items.filter { $0.object != nil }.count
    }
    return out
  }

  static func refusal(before: [String: Int], readable: [String: Int]) -> String? {
    let lost = checkedCounts.filter { key in
      let had = before[key] ?? 0
      return had > 0 && (readable[key] ?? 0) * 2 < had
    }
    if lost.isEmpty { return nil }
    return "session.json holds far fewer readable " + lost.map { "\($0) (\(readable[$0] ?? 0) of \(before[$0] ?? 0))" }.joined(separator: ", ")
      + " than it lists"
  }

  public static func read(
    _ folder: DataFolder, carrying carried: PersistedState?, settings owned: JSONObject? = nil, downloads ownedDownloads: [Download]? = nil,
    context: LoadContext
  ) -> ImportResult {
    var notes: [String] = []
    var refusal: String? = nil
    var meta: [String: String] = ["imported_from": "session.json"]
    let sessionData = folder.read(folder.session) ?? folder.read(folder.preNativeSession)
    let downloadsData = folder.read(folder.downloads) ?? folder.read(folder.preNativeDownloads)
    var session: JSONValue? = nil
    if let sessionData {
      meta["source_session_sha256"] = Launcher.sha256(sessionData)
      meta["source_session_size"] = String(sessionData.count)
      do {
        let parsed = try JSONValue.parse(sessionData)
        meta["source_session_version"] = parsed["version"].map { $0.text() } ?? "none"
        if parsed["version"] == .number(2) {
          session = parsed
        } else {
          refusal = "session.json has version \(meta["source_session_version"]!)"
          notes.append("session.json has version \(meta["source_session_version"]!), so it was not read")
        }
      } catch {
        refusal = "session.json could not be parsed"
        notes.append("session.json could not be parsed: \(error)")
      }
    } else {
      notes.append("no session.json")
    }
    if var object = session?.object {
      var settings = owned ?? object["settings"]?.object ?? JSONObject()
      if let carriedSettings = carried?.settings {
        var kept: [String] = []
        for (key, value) in carriedSettings where !settings.contains(key) && !Settings.bookkeepingKeys.contains(key) {
          settings[key] = value
          kept.append(key)
        }
        if !kept.isEmpty { notes.append("kept settings only the database had: \(kept.joined(separator: ", "))") }
      }
      if owned != nil || carried?.settings != nil { object["settings"] = .object(settings) }
      session = .object(object)
    }
    var downloads: JSONValue? = nil
    if let ownedDownloads {
      downloads = ["version": 2, "downloads": .array(ownedDownloads.map { .object($0.json) })]
    } else if let downloadsData {
      meta["source_downloads_sha256"] = Launcher.sha256(downloadsData)
      meta["source_downloads_size"] = String(downloadsData.count)
      do {
        downloads = try JSONValue.parse(downloadsData)
        let all = downloads?["downloads"]?.array ?? []
        let privateCount = all.filter { $0.object.map { Download(json: $0).isPrivate } ?? false }.count
        if privateCount > 0 { notes.append("dropped \(privateCount) private downloads") }
      } catch {
        notes.append("downloads.json could not be parsed: \(error)")
      }
    }
    let loader = context.session()
    let loaded = DecodeLog.collecting { loader.loadSession(session, downloads: downloads) }
    var state = loaded.0
    notes += loaded.1
    keepLaunchBackdrop(&state, from: session)
    if session == nil, let owned { state.settings = Settings.hydrated(from: .object(owned)) }
    let doc = loader.sessionDocument(state)
    let before = counts(session)
    let after = counts(state, doc)
    for (key, value) in before.sorted(by: { $0.key < $1.key }) {
      meta["count_\(key)_before"] = String(value)
      meta["count_\(key)_after"] = String(after[key] ?? 0)
    }
    for key in ["windows", "tabs", "groups", "splits", "profiles"] {
      let kept: Set<String>
      switch key {
      case "windows": kept = Set(doc.windows.keys)
      case "tabs": kept = Set(doc.tabs.keys)
      case "groups": kept = Set(doc.groups.keys)
      case "splits": kept = Set(doc.splits.keys)
      default: kept = Set(doc.profiles.keys)
      }
      let dropped = OrderedSet(ids(session, key).filter { !kept.contains($0) }).elements
      if !dropped.isEmpty { notes.append("loading dropped \(dropped.count) \(key): \(dropped.joined(separator: ", "))") }
    }
    if refusal == nil {
      refusal = Self.refusal(before: before, readable: readableCounts(session))
    }
    meta["count_settings"] = String(state.settings.values.count)
    meta["count_downloads"] = String(state.downloads.count)
    let persisted = PersistedState(
      settings: state.settings.values, downloads: state.downloads.filter { !$0.isPrivate }.map { $0.persisted() }, workspace: WorkspaceRows(doc),
      documents: carried?.documents ?? JSMap())
    return ImportResult(state: state, memory: loader.memory, persisted: persisted, meta: meta, notes: notes, refusal: refusal)
  }

  @discardableResult
  public static func importFolder(_ folder: DataFolder, carrying carried: PersistedState?, appVersion: String, now: Date, context: LoadContext) throws
    -> ImportResult
  {
    var result = read(folder, carrying: carried, context: context)
    if let refusal = result.refusal {
      log(result.notes + ["refused the import: \(refusal)"], to: folder, now: now)
      throw ImportRefused(reason: refusal)
    }
    result.meta["app_version"] = appVersion
    result.meta["imported_at"] = String(Int64(now.timeIntervalSince1970 * 1000))
    let fm = FileManager.default
    for suffix in ["", "-journal", "-wal", "-shm"] {
      let path = folder.importing.path + suffix
      if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    }
    try SolaraDatabase.create(at: folder.importing, writing: result.persisted, meta: result.meta)
    try fullSync(folder.importing)
    if !fm.fileExists(atPath: folder.database.path) {
      for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: folder.database.path + suffix) {
        let name = try Launcher.moveAside(URL(fileURLWithPath: folder.database.path + suffix), label: "orphan", now: now)
        result.notes.append("moved an orphaned \(suffix) aside to \(name)")
      }
    }
    guard rename(folder.importing.path, folder.database.path) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: folder.database.path])
    }
    try fullSync(folder.url)
    log(result.notes, to: folder, now: now)
    return result
  }

  static func log(_ notes: [String], to folder: DataFolder, now: Date) {
    if notes.isEmpty { return }
    let stamp = ISO8601DateFormatter().string(from: now)
    let lines = notes.map { "\(stamp) \($0)\n" }.joined()
    if let handle = try? FileHandle(forWritingTo: folder.importLog) {
      handle.seekToEndOfFile()
      handle.write(Data(lines.utf8))
      try? handle.close()
    } else {
      try? Data(lines.utf8).write(to: folder.importLog)
    }
  }

  static func fullSync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    if fcntl(fd, F_FULLFSYNC) == 0 { return }
    guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  static func writeDurably(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).writing")
    try data.write(to: temporary)
    try fullSync(temporary)
    guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try fullSync(url.deletingLastPathComponent())
  }
}
