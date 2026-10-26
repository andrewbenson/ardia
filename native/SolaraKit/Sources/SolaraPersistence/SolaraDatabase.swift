import Foundation
import GRDB
import SolaraModel

public enum OpenFailure: Error, Equatable {
  case corrupt(String)
  case newerSchema
}

public final class SolaraDatabase: Sendable {
  public let pool: DatabasePool
  public let url: URL

  static func configuration() -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
    }
    return config
  }

  public init(url: URL) throws {
    self.url = url
    pool = try DatabasePool(path: url.path, configuration: Self.configuration())
    let quick = try pool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
    guard quick == ["ok"] else { throw OpenFailure.corrupt(quick.joined(separator: "; ")) }
    let migrator = Schema.migrator
    if try pool.read({ try migrator.hasBeenSuperseded($0) }) { throw OpenFailure.newerSchema }
    try migrator.migrate(pool)
    try pool.write { db in try Rows.setMeta(db, "schema", Schema.migrationNames.last!) }
  }

  public func close() throws {
    try pool.close()
  }

  public func load() throws -> PersistedState {
    try pool.read { db in try Rows.load(db) }
  }

  public func meta(_ key: String) throws -> String? {
    try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
  }

  public static func create(at url: URL, writing persisted: PersistedState, meta: [String: String]) throws {
    let queue = try DatabaseQueue(path: url.path, configuration: configuration())
    try Schema.migrator.migrate(queue)
    try queue.write { db in
      try Rows.setMeta(db, "schema", Schema.migrationNames.last!)
      for (key, value) in meta.sorted(by: { $0.key < $1.key }) { try Rows.setMeta(db, key, value) }
      try Rows.writeSettings(db, persisted.settings)
      try Rows.writeDownloads(db, persisted.downloads)
    }
    try queue.close()
  }
}

public struct PersistedState: Sendable, Equatable {
  public var settings: JSONObject?
  public var downloads: [Download]

  public init(settings: JSONObject?, downloads: [Download]) {
    self.settings = settings
    self.downloads = downloads
  }
}

enum Rows {
  static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
    try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
  }

  static func writeSettings(_ db: Database, _ settings: JSONObject?) throws {
    try db.execute(sql: "DELETE FROM setting")
    guard let settings else { return }
    let statement = try db.makeStatement(sql: "INSERT INTO setting (key, position, value) VALUES (?, ?, ?)")
    for (position, key) in settings.keys.enumerated() {
      try statement.execute(arguments: [key, position, settings[key]!.text()])
    }
  }

  static func writeDownloads(_ db: Database, _ downloads: [Download]) throws {
    try db.execute(sql: "DELETE FROM download")
    let statement = try db.makeStatement(sql: "INSERT INTO download (id, position, payload) VALUES (?, ?, ?)")
    for (position, download) in downloads.enumerated() {
      try statement.execute(arguments: [download.id, position, JSONValue.object(download.json).text()])
    }
  }

  static func load(_ db: Database) throws -> PersistedState {
    var settings = JSONObject()
    let settingRows = try Row.fetchAll(db, sql: "SELECT key, value FROM setting ORDER BY position")
    for row in settingRows {
      let key: String = row["key"]
      let text: String = row["value"]
      settings[key] = try JSONValue.parse(text)
    }
    let downloadRows = try String.fetchAll(db, sql: "SELECT payload FROM download ORDER BY position")
    let downloads = try downloadRows.compactMap { try JSONValue.parse($0).object.map(Download.init) }
    return PersistedState(settings: settingRows.isEmpty ? nil : settings, downloads: downloads)
  }
}
