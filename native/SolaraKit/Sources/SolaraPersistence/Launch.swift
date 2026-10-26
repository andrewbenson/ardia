import CryptoKit
import Foundation
import GRDB
import SolaraModel

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

public struct Launch: Sendable {
  public let database: SolaraDatabase
  public let state: BrowserState
  public let report: LaunchReport
}

public enum Launcher {
  public static let markerKey = "nativeExport"

  public static func open(_ folder: DataFolder, appVersion: String, now: Date = Date()) throws -> Launch {
    let fm = FileManager.default
    try fm.createDirectory(at: folder.url, withIntermediateDirectories: true)
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
        if let reason = try writtenByOlderBuild(folder, database: database) {
          carried = try? database.load()
          try database.close()
          importReason = reason
          movedAside.append(try moveAside(folder.database, label: "superseded", now: now))
        } else {
          return Launch(database: database, state: hydrated(try database.load()), report: LaunchReport(source: .database))
        }
      }
    }

    let imported = try Importer.importFolder(folder, carrying: carried, appVersion: appVersion, now: now)
    let database = try SolaraDatabase(url: folder.database)
    var report = LaunchReport(source: .imported(reason: importReason ?? "first launch on the native store"))
    report.movedAside = movedAside
    report.notes = imported.notes
    return Launch(database: database, state: hydrated(try database.load()), report: report)
  }

  public static func hydrated(_ persisted: PersistedState) -> BrowserState {
    let settings = Settings.hydrated(from: persisted.settings.map(JSONValue.object))
    let downloads = persisted.downloads.filter { !$0.isPrivate }.enumerated().map { $0.element.persisted().loaded(at: $0.offset) }
    return BrowserState(settings: settings, downloads: downloads)
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
    try fm.moveItem(at: url, to: target)
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: url.path + suffix)
      if fm.fileExists(atPath: side.path) { try fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix)) }
    }
    return name
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
