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
    defer { pruneMovedAside(folder) }
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
            movedAside.append(try moveAside(folder.database, label: "superseded", now: now))
          } else {
            return try fromDatabase(database, folder: folder, now: now, context: context, scope: scope)
          }
        } catch let refused as ImportRefused {
          try? database.close()
          throw refused
        } catch {
          try? database.close()
          importReason = "solara.sqlite could not be read: \(error)"
          movedAside.append(try moveAside(folder.database, label: "unreadable", now: now))
        }
      }
    }

    let imported = try Importer.importFolder(folder, carrying: carried, appVersion: appVersion, now: now, context: context, scope: scope)
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
    guard let stored = persisted.workspace else {
      var result = Importer.read(folder, carrying: nil, settings: persisted.settings, downloads: persisted.downloads, context: context)
      if let refusal = result.refusal {
        Importer.log(result.notes + ["refused the workspace import: \(refusal)"], to: folder, now: now)
        throw ImportRefused(reason: refusal)
      }
      result.meta["workspace_imported_at"] = String(Int64(now.timeIntervalSince1970 * 1000))
      let rows = result.persisted.workspace!
      try database.pool.write { db in
        try Rows.writeWorkspace(db, rows, previous: nil)
        for (key, value) in result.meta.sorted(by: { $0.key < $1.key }) { try Rows.setMeta(db, key, value) }
      }
      Importer.log(persisted.notes + result.notes, to: folder, now: now)
      var report = LaunchReport(source: .imported(reason: "the workspace moved from session.json into solara.sqlite"))
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
    var byLabel: [String: [String]] = [:]
    for name in names {
      for prefix in [base + ".", base + "-wal.", base + "-shm."] where name.hasPrefix(prefix) {
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

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
