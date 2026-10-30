import CryptoKit
import Foundation
import GRDB
import SolaraModel
import SolaraStore
import Synchronization

public struct DataFolder: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public var database: URL { url.appending(path: "solara.sqlite") }
  public var importing: URL { url.appending(path: "solara.sqlite.importing") }
  public var session: URL { url.appending(path: "session.json") }
  public var downloads: URL { url.appending(path: "downloads.json") }
  public var importLog: URL { url.appending(path: "import.log") }
  public var preNativeSession: URL { url.appending(path: "session.json.pre-native") }
  public var preNativeDownloads: URL { url.appending(path: "downloads.json.pre-native") }

  enum Contents {
    case missing
    case data(Data)
    case unreadable(String)
  }

  func contents(_ file: URL) -> Contents {
    FileReads.record(file)
    do {
      return .data(try Data(contentsOf: file))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .missing
    } catch {
      return .unreadable("\(file.lastPathComponent) exists but could not be read: \(error.localizedDescription)")
    }
  }

  func read(_ file: URL) -> Data? {
    contents(file).data
  }
}

extension DataFolder.Contents {
  var data: Data? { if case .data(let data) = self { data } else { nil } }
  var failure: String? { if case .unreadable(let failure) = self { failure } else { nil } }
}

final class FileReads: Sendable {
  @TaskLocal static var current: FileReads?

  let names = Mutex<[String]>([])

  func count(_ name: String) -> Int { names.withLock { $0.filter { $0 == name }.count } }

  static func record(_ file: URL) {
    current?.names.withLock { $0.append(file.lastPathComponent) }
  }
}

struct LaunchFiles {
  let session: DataFolder.Contents
  let downloads: DataFolder.Contents

  init(_ folder: DataFolder) {
    session = folder.contents(folder.session)
    downloads = folder.contents(folder.downloads)
  }
}

public struct LaunchReport: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    case database
    case imported(reason: String)
  }

  public var source: Source
  public var movedAside: [String] = []
  public var notes: [String] = []
}

public enum PersistenceScope: Sendable, Equatable {
  case settingsAndDownloads
  case everything

  public var markerName: String { self == .everything ? "everything" : "settingsAndDownloads" }
}

public struct Launch: Sendable {
  public let database: SolaraDatabase
  public let state: BrowserState
  public let memory: StoreMemory
  public var persisted: PersistedState
  public var report: LaunchReport

  public var rows: WorkspaceRows { persisted.workspace ?? WorkspaceRows() }
}

public struct SafeLaunch: Sendable {
  public let database: SolaraDatabase?
  public let state: BrowserState
  public let memory: StoreMemory
  public let persisted: PersistedState
  public let report: LaunchReport

  public init(_ launch: Launch) {
    self.init(database: launch.database, state: launch.state, memory: launch.memory, persisted: launch.persisted, report: launch.report)
  }

  init(database: SolaraDatabase?, state: BrowserState, memory: StoreMemory, persisted: PersistedState, report: LaunchReport) {
    self.database = database
    self.state = state
    self.memory = memory
    self.persisted = persisted
    self.report = report
  }
}

public enum Launcher {
  public static let markerKey = "nativeExport"
  public static let keptAsideCopies = 3

  public static func open(
    _ folder: DataFolder, appVersion: String, now: Date = Date(), context: LoadContext, scope: PersistenceScope = .everything
  ) throws -> Launch {
    let fm = FileManager.default
    try fm.createDirectory(at: folder.url, withIntermediateDirectories: true)
    let files = LaunchFiles(folder)
    if let failure = files.session.failure {
      Importer.log(["refused the launch: \(failure)"], to: folder, now: now)
      throw ImportRefused(reason: failure)
    }
    try preserveOriginals(folder, files)
    var launch = try openUnpruned(folder, appVersion: appVersion, now: now, context: context, scope: scope, files: files)
    if let failure = files.downloads.failure {
      launch.persisted.keepsDownloadsFile = true
      if !launch.report.notes.contains(failure) {
        launch.report.notes.append(failure)
        Importer.log([failure], to: folder, now: now)
      }
    }
    pruneMovedAside(folder)
    return launch
  }

  public static func openSafe(_ folder: DataFolder, appVersion: String, now: Date = Date(), context: LoadContext) throws -> SafeLaunch {
    let files = LaunchFiles(folder)
    let snapshot = FileManager.default.temporaryDirectory.appending(path: "solara-safe-\(UUID().uuidString)")
    let reader = try? safeSnapshot(folder, at: snapshot)
    defer {
      try? reader?.close()
      try? FileManager.default.removeItem(at: snapshot)
    }
    if let reader,
      let persisted = try? reader.read({ db in
        try SolaraDatabase.checkCurrent(db)
        return try Rows.load(db)
      })
    {
      let writable = (try? reader.read { db in
        guard files.session.failure == nil, files.downloads.failure == nil,
          try writtenByOlderBuild(files, db: db) == nil else { return false }
        if persisted.workspace != nil,
          markerScope(files.session.data).map({ $0 != PersistenceScope.everything.markerName }) == true,
          files.session.data.map(sha256) != (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'workspace_source_sha256'"))
        {
          return false
        }
        return true
      }) == true && !FileManager.default.fileExists(atPath: folder.database.path + "-journal")
      let database = writable ? (try? SolaraDatabase(existing: folder.database)) : nil
      let loader = context.session()
      var baseline = persisted
      if let workspace = persisted.workspace { baseline.workspace = workspace.readable().rows }
      let session = baseline.sessionJSON() ?? ["version": 2, "settings": persisted.settings.map(JSONValue.object) ?? .null]
      let loaded = DecodeLog.collecting { loader.loadSession(session, downloads: persisted.downloadsJSON) }
      baseline.workspace = nil
      return SafeLaunch(
        database: database, state: Importer.safeMode(of: loaded.0), memory: loader.memory, persisted: baseline,
        report: LaunchReport(source: .database, notes: persisted.notes + loaded.1))
    }
    var notes: [String] = []
    let settings = reader.flatMap { reader in
      try? reader.read { db in try Rows.loadSettings(db, notes: &notes) ?? JSONObject() }
    } ?? files.session.data.flatMap { (try? JSONValue.parse($0))?["settings"]?.object }
    let downloads = reader.flatMap { reader in
      try? reader.read { db in try Rows.loadDownloads(db, notes: &notes) }
    }
    let session: JSONValue = ["version": 2, "settings": settings.map(JSONValue.object) ?? .null]
    let downloadsJSON: JSONValue? = downloads.map { ["version": 2, "downloads": .array($0.map { .object($0.json) })] }
      ?? files.downloads.data.flatMap { try? JSONValue.parse($0) }
    let loader = context.session()
    let loaded = DecodeLog.collecting { loader.loadSession(session, downloads: downloadsJSON) }
    let state = Importer.settingsAndDownloads(of: loaded.0)
    return SafeLaunch(
      database: nil, state: state, memory: loader.memory,
      persisted: PersistedState(settings: settings, downloads: state.downloads),
      report: LaunchReport(source: .imported(reason: "settings-only safe launch without persistence"), notes: notes + loaded.1))
  }

  static func safeSnapshot(_ folder: DataFolder, at directory: URL) throws -> DatabaseQueue {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    let copy = directory.appending(path: "store")
    try Data(contentsOf: folder.database).write(to: copy)
    for suffix in ["-wal", "-journal"] {
      let side = URL(fileURLWithPath: folder.database.path + suffix)
      if fm.fileExists(atPath: side.path) { try Data(contentsOf: side).write(to: URL(fileURLWithPath: copy.path + suffix)) }
    }
    var config = Configuration()
    config.busyMode = .timeout(5)
    return try DatabaseQueue(path: copy.path, configuration: config)
  }

  static func workspaceIsCurrent(_ database: SolaraDatabase, files: LaunchFiles) throws -> Bool {
    guard try database.load().workspace != nil else { return false }
    guard markerScope(files.session.data).map({ $0 != PersistenceScope.everything.markerName }) == true else { return true }
    return files.session.data.map(sha256) == (try database.meta("workspace_source_sha256"))
  }

  static let unreadableCodes: [ResultCode] = [.SQLITE_ERROR, .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_SCHEMA, .SQLITE_MISMATCH, .SQLITE_FORMAT, .SQLITE_RANGE]

  static func everHadDatabase(_ folder: DataFolder) -> Bool {
    let base = folder.database.lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []
    return names.contains { $0 == base || ($0.hasPrefix(base + ".") && !$0.hasPrefix(folder.importing.lastPathComponent)) }
  }

  static func openUnpruned(_ folder: DataFolder, appVersion: String, now: Date, context: LoadContext, scope: PersistenceScope, files: LaunchFiles) throws -> Launch {
    let fm = FileManager.default
    let originalsFallback = !everHadDatabase(folder)
    var movedAside: [String] = []
    var importReason: String? = nil
    var carried: PersistedState? = nil

    if fm.fileExists(atPath: folder.database.path) {
      var opened: SolaraDatabase? = nil
      do {
        opened = try SolaraDatabase(url: folder.database)
      } catch OpenFailure.newerSchema {
        importReason = "solara.sqlite was written by a newer build"
        movedAside.append(try moveAside(folder.database, label: "newer", now: now))
      } catch let failure as OpenFailure {
        importReason = "solara.sqlite failed its check: \(failure)"
        movedAside.append(try moveAside(folder.database, label: "corrupt", now: now))
      } catch let error as DatabaseError where [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode) {
        importReason = "solara.sqlite is damaged: \(error.message ?? "\(error.resultCode)")"
        movedAside.append(try moveAside(folder.database, label: "corrupt", now: now))
      }
      if let database = opened {
        do {
          if let reason = try writtenByOlderBuild(files, database: database) {
            carried = try? database.load()
            try database.close()
            importReason = reason
            for file in [folder.session, folder.downloads] where fm.fileExists(atPath: file.path) {
              movedAside.append(try copyAside(file, label: "pre-reimport", now: now))
            }
            movedAside.append(try moveAside(folder.database, label: "superseded", now: now))
          } else {
            return try fromDatabase(database, folder: folder, now: now, context: context, scope: scope, files: files)
          }
        } catch let refused as ImportRefused {
          try? database.close()
          throw refused
        } catch let error as DatabaseError where !unreadableCodes.contains(error.resultCode) {
          try? database.close()
          throw error
        } catch let error where !(error is DatabaseError || error is ModelDecodeError || error is JSONParseError) {
          try? database.close()
          throw error
        } catch {
          try? database.close()
          importReason = "solara.sqlite could not be read: \(error)"
          movedAside.append(try moveAside(folder.database, label: "unreadable", now: now))
        }
      }
    }

    let imported = try Importer.importFolder(
      folder, carrying: carried, appVersion: appVersion, now: now, context: context, scope: scope, originalsFallback: originalsFallback, files: files)
    let database = try SolaraDatabase(url: folder.database)
    var report = LaunchReport(source: .imported(reason: importReason ?? "first launch on the native store"))
    report.movedAside = movedAside
    report.notes = imported.notes
    return Launch(database: database, state: imported.state, memory: imported.memory, persisted: imported.persisted, report: report)
  }

  static func fromDatabase(_ database: SolaraDatabase, folder: DataFolder, now: Date, context: LoadContext, scope: PersistenceScope, files: LaunchFiles) throws -> Launch {
    let persisted = try database.load()
    if scope == .settingsAndDownloads {
      let loader = context.session()
      let session: JSONValue = ["version": 2, "settings": persisted.settings.map(JSONValue.object) ?? .null]
      let loaded = DecodeLog.collecting { loader.loadSession(session, downloads: persisted.downloadsJSON) }
      var report = LaunchReport(source: .database)
      report.notes = persisted.notes + loaded.1
      Importer.log(report.notes, to: folder, now: now)
      var baseline = persisted
      baseline.workspace = nil
      return Launch(database: database, state: Importer.settingsAndDownloads(of: loaded.0), memory: loader.memory, persisted: baseline, report: report)
    }
    let sessionHash = files.session.data.map(sha256)
    let importedFrom = try database.meta("workspace_source_sha256")
    let staleWorkspace = persisted.workspace != nil && markerScope(files.session.data).map { $0 != PersistenceScope.everything.markerName } == true
      && sessionHash != importedFrom
    guard let stored = persisted.workspace, !staleWorkspace else {
      var result = Importer.read(folder, carrying: nil, settings: persisted.settings, downloads: persisted.downloads, context: context, files: files)
      if let refusal = result.refusal {
        Importer.log(result.notes + ["refused the workspace import: \(refusal)"], to: folder, now: now)
        throw ImportRefused(reason: refusal)
      }
      result.meta["workspace_imported_at"] = String(Int64(now.timeIntervalSince1970 * 1000))
      if let sessionHash { result.meta["workspace_source_sha256"] = sessionHash }
      let rows = result.persisted.workspace!
      if staleWorkspace {
        let name = uniqueAsideName(folder.database, label: "pre-reimport", now: now)
        try database.pool.backup(to: DatabaseQueue(path: folder.url.appending(path: name).path))
        Importer.log(["kept the database as it was before the workspace re-import: \(name)"], to: folder, now: now)
      }
      try database.pool.write { db in
        if staleWorkspace { try Rows.clearWorkspace(db) }
        try Rows.writeWorkspace(db, rows, previous: nil)
        for (key, value) in result.meta.sorted(by: { $0.key < $1.key }) { try Rows.setMeta(db, key, value) }
      }
      Importer.log(persisted.notes + result.notes, to: folder, now: now)
      var report = LaunchReport(
        source: .imported(
          reason: staleWorkspace
            ? "session.json was written in the settings-and-downloads scope, so its workspace replaces the database's"
            : "the workspace moved from session.json into solara.sqlite"))
      report.notes = persisted.notes + result.notes
      var baseline = persisted
      baseline.workspace = rows
      return Launch(database: database, state: result.state, memory: result.memory, persisted: baseline, report: report)
    }
    let (rows, unreadable) = stored.readable()
    var baseline = persisted
    baseline.workspace = rows
    let loader = context.session()
    let session = baseline.sessionJSON()
    var loaded = DecodeLog.collecting { loader.loadSession(session, downloads: baseline.downloadsJSON) }
    Importer.keepLaunchBackdrop(&loaded.0, from: session)
    var report = LaunchReport(source: .database)
    report.notes = persisted.notes + unreadable.map { "left unreadable row \($0) in place" } + loaded.1
    Importer.log(report.notes, to: folder, now: now)
    return Launch(database: database, state: loaded.0, memory: loader.memory, persisted: baseline, report: report)
  }

  static func preserveOriginals(_ folder: DataFolder, _ files: LaunchFiles) throws {
    let fm = FileManager.default
    for (contents, copy) in [(files.session, folder.preNativeSession), (files.downloads, folder.preNativeDownloads)] {
      guard let data = contents.data, !fm.fileExists(atPath: copy.path) else { continue }
      if marker(in: data) == true { continue }
      let temporary = copy.deletingLastPathComponent().appending(path: ".\(copy.lastPathComponent).copying")
      if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
      try data.write(to: temporary)
      try Importer.fullSync(temporary)
      guard rename(temporary.path, copy.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      try Importer.fullSync(folder.url)
    }
  }

  static func pruneMovedAside(_ folder: DataFolder) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: folder.url.path) else { return }
    let base = folder.database.lastPathComponent
    let prefixes = [base + ".", base + "-wal.", base + "-shm.", folder.session.lastPathComponent + ".", folder.downloads.lastPathComponent + "."]
    var byLabel: [String: [String]] = [:]
    for name in names where !name.hasSuffix(".pre-native") {
      for prefix in prefixes where name.hasPrefix(prefix) {
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-"), !name.hasSuffix("-wal"), !name.hasSuffix("-shm") else { continue }
        byLabel[prefix + rest[..<dash], default: []].append(name)
      }
    }
    for (_, copies) in byLabel {
      for name in copies.sorted().dropLast(keptAsideCopies) {
        for file in [name, name + "-wal", name + "-shm"] { try? fm.removeItem(at: folder.url.appending(path: file)) }
      }
    }
  }

  static func markerScope(_ session: Data?) -> String? {
    guard let data = session, let marker = (try? JSONValue.parse(data))?[markerKey]?.object else { return nil }
    return marker["scope"]?.string ?? PersistenceScope.settingsAndDownloads.markerName
  }

  static func marker(in data: Data?) -> Bool? {
    guard let data, let object = try? JSONValue.parse(data).object else { return nil }
    return object[markerKey]?.object != nil
  }

  static func writtenByOlderBuild(_ files: LaunchFiles, database: SolaraDatabase) throws -> String? {
    try database.pool.read { db in try writtenByOlderBuild(files, db: db) }
  }

  static func writtenByOlderBuild(_ files: LaunchFiles, db: Database) throws -> String? {
    let session = files.session.data
    if let session, marker(in: session) == false {
      let importedHash = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'source_session_sha256'")
      if importedHash != sha256(session) { return "session.json was written by a build without the native store" }
    }
    let downloads = files.downloads.data
    if let downloads, marker(in: downloads) == false {
      let importedHash = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'source_downloads_sha256'")
      if importedHash != sha256(downloads) { return "downloads.json was written by a build without the native store" }
    }
    return nil
  }

  static func moveAside(_ url: URL, label: String, now: Date) throws -> String {
    let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate, .withTime])
    let fm = FileManager.default
    var name = "\(url.lastPathComponent).\(label)-\(stamp)"
    var serial = 1
    while fm.fileExists(atPath: url.deletingLastPathComponent().appending(path: name).path) {
      serial += 1
      name = "\(url.lastPathComponent).\(label)-\(stamp)-\(serial)"
    }
    let target = url.deletingLastPathComponent().appending(path: name)
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: url.path + suffix)
      if fm.fileExists(atPath: side.path) { try fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix)) }
    }
    try fm.moveItem(at: url, to: target)
    return name
  }

  static func uniqueAsideName(_ url: URL, label: String, now: Date) -> String {
    let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate, .withTime])
    var name = "\(url.lastPathComponent).\(label)-\(stamp)"
    var serial = 1
    while FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: name).path) {
      serial += 1
      name = "\(url.lastPathComponent).\(label)-\(stamp)-\(serial)"
    }
    return name
  }

  static func copyAside(_ url: URL, label: String, now: Date) throws -> String {
    let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withFullDate, .withTime])
    var name = "\(url.lastPathComponent).\(label)-\(stamp)"
    var serial = 1
    while FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: name).path) {
      serial += 1
      name = "\(url.lastPathComponent).\(label)-\(stamp)-\(serial)"
    }
    try Importer.copyDurably(url, to: url.deletingLastPathComponent().appending(path: name))
    return name
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
