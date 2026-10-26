import CryptoKit
import Foundation
import GRDB
import SolaraModel
import SolaraStore

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

  func read(_ file: URL) -> Data? {
    try? Data(contentsOf: file)
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
  public let persisted: PersistedState
  public let report: LaunchReport

  public var rows: WorkspaceRows { persisted.workspace ?? WorkspaceRows() }
}

public enum Launcher {
  public static let markerKey = "nativeExport"
  public static let keptAsideCopies = 3

  public static func open(
    _ folder: DataFolder, appVersion: String, now: Date = Date(), context: LoadContext, scope: PersistenceScope = .everything
  ) throws -> Launch {
    let fm = FileManager.default
    try fm.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try preserveOriginals(folder)
    let launch = try openUnpruned(folder, appVersion: appVersion, now: now, context: context, scope: scope)
    pruneMovedAside(folder)
    return launch
  }

  static let unreadableCodes: [ResultCode] = [.SQLITE_ERROR, .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_SCHEMA, .SQLITE_MISMATCH, .SQLITE_FORMAT, .SQLITE_RANGE]

  static func everHadDatabase(_ folder: DataFolder) -> Bool {
    let base = folder.database.lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []
    return names.contains { $0 == base || ($0.hasPrefix(base + ".") && !$0.hasPrefix(folder.importing.lastPathComponent)) }
  }

  static func openUnpruned(_ folder: DataFolder, appVersion: String, now: Date, context: LoadContext, scope: PersistenceScope) throws -> Launch {
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
          if let reason = try writtenByOlderBuild(folder, database: database) {
            carried = try? database.load()
            try database.close()
            importReason = reason
            for file in [folder.session, folder.downloads] where fm.fileExists(atPath: file.path) {
              movedAside.append(try copyAside(file, label: "pre-reimport", now: now))
            }
            movedAside.append(try moveAside(folder.database, label: "superseded", now: now))
          } else {
            return try fromDatabase(database, folder: folder, now: now, context: context, scope: scope)
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
      folder, carrying: carried, appVersion: appVersion, now: now, context: context, scope: scope, originalsFallback: originalsFallback)
    let database = try SolaraDatabase(url: folder.database)
    var report = LaunchReport(source: .imported(reason: importReason ?? "first launch on the native store"))
    report.movedAside = movedAside
    report.notes = imported.notes
    return Launch(database: database, state: imported.state, memory: imported.memory, persisted: imported.persisted, report: report)
  }

  static func fromDatabase(_ database: SolaraDatabase, folder: DataFolder, now: Date, context: LoadContext, scope: PersistenceScope) throws -> Launch {
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
    let sessionHash = folder.read(folder.session).map(sha256)
    let importedFrom = try database.meta("workspace_source_sha256")
    let staleWorkspace = persisted.workspace != nil && markerScope(folder).map { $0 != PersistenceScope.everything.markerName } == true
      && sessionHash != importedFrom
    guard let stored = persisted.workspace, !staleWorkspace else {
      var result = Importer.read(folder, carrying: nil, settings: persisted.settings, downloads: persisted.downloads, context: context)
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

  static func preserveOriginals(_ folder: DataFolder) throws {
    let fm = FileManager.default
    for (source, copy) in [(folder.session, folder.preNativeSession), (folder.downloads, folder.preNativeDownloads)] {
      guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: copy.path) else { continue }
      if marker(in: folder.read(source)) == true { continue }
      let temporary = copy.deletingLastPathComponent().appending(path: ".\(copy.lastPathComponent).copying")
      if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
      try fm.copyItem(at: source, to: temporary)
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

  static func markerScope(_ folder: DataFolder) -> String? {
    guard let data = folder.read(folder.session), let marker = (try? JSONValue.parse(data))?[markerKey]?.object else { return nil }
    return marker["scope"]?.string ?? PersistenceScope.settingsAndDownloads.markerName
  }

  static func marker(in data: Data?) -> Bool? {
    guard let data, let object = try? JSONValue.parse(data).object else { return nil }
    return object[markerKey]?.object != nil
  }

  static func writtenByOlderBuild(_ folder: DataFolder, database: SolaraDatabase) throws -> String? {
    let session = folder.read(folder.session)
    if let session, marker(in: session) == false {
      let importedHash = try database.meta("source_session_sha256")
      if importedHash != sha256(session) { return "session.json was written by a build without the native store" }
    }
    let downloads = folder.read(folder.downloads)
    if let downloads, marker(in: downloads) == false {
      let importedHash = try database.meta("source_downloads_sha256")
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
