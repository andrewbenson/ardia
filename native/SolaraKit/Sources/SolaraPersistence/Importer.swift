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

  static let checkedCounts = ["profiles", "windows", "tabs", "groups", "splits", "closedTabs", "closedWindows", "closedGroups", "deletedGroups", "cleanedTabs"]

  static func readableCounts(_ session: JSONValue?) -> [String: Int] {
    var out: [String: Int] = [:]
    for key in checkedCounts {
      let value = session?[key]
      let items = value?.array ?? value?.object?.values ?? []
      out[key] = items.filter { $0.object != nil }.count
    }
    return out
  }

  static func unreadableContainers(_ session: JSONValue?) -> String? {
    for key in ["windows", "tabs", "profiles", "groups", "splits"] {
      guard let value = session?[key], !value.isNull else { continue }
      if value.array == nil && value.object == nil { return "session.json's \(key) is neither a list nor an object" }
    }
    let windows = session?["windows"]
    let listedWindows = windows?.array ?? windows?.object?.values ?? []
    let badWindows = listedWindows.filter { $0.object == nil || $0["tabIds"]?.array == nil }.count
    if badWindows > 0 {
      let held = session?["tabs"]?.array?.count ?? session?["tabs"]?.object?.count ?? 0
      return "session.json lists \(badWindows) unreadable window\(badWindows == 1 ? "" : "s") among \(held) tabs"
    }
    let profiles = session?["profiles"]?.object?.values ?? session?["profiles"]?.array ?? []
    let badProfiles = profiles.filter { $0.object == nil }.count
    if badProfiles > 0 { return "session.json lists \(badProfiles) unreadable profile\(badProfiles == 1 ? "" : "s")" }
    return nil
  }

  static func refusal(before: [String: Int], readable: [String: Int]) -> String? {
    let lost = checkedCounts.filter { key in
      let had = before[key] ?? 0
      let kept = readable[key] ?? 0
      let leastLost = ["profiles", "windows", "tabs"].contains(key) ? 1 : 2
      return had - kept >= leastLost && kept * 2 < had
    }
    if lost.isEmpty { return nil }
    return "session.json holds far fewer readable " + lost.map { "\($0) (\(readable[$0] ?? 0) of \(before[$0] ?? 0))" }.joined(separator: ", ")
      + " than it lists"
  }

  public static func read(
    _ folder: DataFolder, carrying carried: PersistedState?, settings owned: JSONObject? = nil, downloads ownedDownloads: [Download]? = nil,
    context: LoadContext, originalsFallback: Bool = true
  ) -> ImportResult {
    read(folder, carrying: carried, settings: owned, downloads: ownedDownloads, context: context, originalsFallback: originalsFallback, files: nil)
  }

  static func read(
    _ folder: DataFolder, carrying carried: PersistedState?, settings owned: JSONObject? = nil, downloads ownedDownloads: [Download]? = nil,
    context: LoadContext, originalsFallback: Bool = true, files: LaunchFiles?
  ) -> ImportResult {
    var notes: [String] = []
    var refusal: String? = nil
    var meta: [String: String] = ["imported_from": "session.json"]
    func source(_ file: URL, original: URL, read: DataFolder.Contents?) -> DataFolder.Contents {
      let contents = read ?? folder.contents(file)
      if case .missing = contents, originalsFallback { return folder.contents(original) }
      return contents
    }
    let sessionSource = source(folder.session, original: folder.preNativeSession, read: files?.session)
    let downloadsSource = source(folder.downloads, original: folder.preNativeDownloads, read: files?.downloads)
    let sessionData = sessionSource.data
    let downloadsData = downloadsSource.data
    if let failure = sessionSource.failure {
      refusal = failure
      notes.append(failure)
    }
    if let failure = downloadsSource.failure, ownedDownloads == nil { notes.append(failure) }
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
    } else if case .missing = sessionSource {
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
    if refusal == nil, let settings = session?["settings"], !settings.isNull, settings.object == nil {
      refusal = "session.json's settings aren't an object"
    }
    if refusal == nil { refusal = unreadableContainers(session) }
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
  public static func settingsAndDownloads(of state: BrowserState) -> BrowserState {
    var only = BrowserState(settings: state.settings, downloads: state.downloads)
    only.caches = state.caches
    return only
  }

  public static func safeMode(of state: BrowserState) -> BrowserState {
    var safe = settingsAndDownloads(of: state)
    if !state.profiles.isEmpty {
      safe.profiles = state.profiles
      safe.profileOrder = state.profileOrder
      safe.orphanedProfileData = state.orphanedProfileData
    }
    safe.ui.lastProfileId = state.ui.lastProfileId
    return safe
  }

  public static func importFolder(
    _ folder: DataFolder, carrying carried: PersistedState?, appVersion: String, now: Date, context: LoadContext, scope: PersistenceScope = .everything,
    originalsFallback: Bool = true
  ) throws -> ImportResult {
    try importFolder(folder, carrying: carried, appVersion: appVersion, now: now, context: context, scope: scope, originalsFallback: originalsFallback, files: nil)
  }

  static func importFolder(
    _ folder: DataFolder, carrying carried: PersistedState?, appVersion: String, now: Date, context: LoadContext, scope: PersistenceScope = .everything,
    originalsFallback: Bool = true, files: LaunchFiles?
  ) throws -> ImportResult {
    var result = read(folder, carrying: carried, context: context, originalsFallback: originalsFallback, files: files)
    if scope == .settingsAndDownloads {
      result.state = settingsAndDownloads(of: result.state)
      result.persisted.workspace = nil
    } else if let source = result.meta["source_session_sha256"] {
      result.meta["workspace_source_sha256"] = source
    }
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

  static func barrierSync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    if fcntl(fd, F_BARRIERFSYNC) == 0 { return }
    guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  static func copyDurably(_ source: URL, to target: URL) throws {
    try FileManager.default.copyItem(at: source, to: target)
    try fullSync(target)
    try fullSync(target.deletingLastPathComponent())
  }

  static func writeDurably(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).writing")
    try data.write(to: temporary)
    try barrierSync(temporary)
    guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try barrierSync(url.deletingLastPathComponent())
  }
}
