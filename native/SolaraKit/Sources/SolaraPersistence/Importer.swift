import Foundation
import SolaraModel

public struct ImportResult: Sendable {
  public var persisted: PersistedState
  public var meta: [String: String]
  public var notes: [String]
}

public enum Importer {
  public static func read(_ folder: DataFolder, carrying carried: PersistedState?) -> ImportResult {
    var notes: [String] = []
    var meta: [String: String] = ["imported_from": "session.json"]
    let sessionData = folder.read(folder.session)
    let downloadsData = folder.read(folder.downloads)
    var savedSettings: JSONObject? = nil
    if let sessionData {
      meta["source_session_sha256"] = Launcher.sha256(sessionData)
      meta["source_session_size"] = String(sessionData.count)
      do {
        let session = try JSONValue.parse(sessionData)
        meta["source_session_version"] = session["version"].map { $0.text() } ?? "none"
        if session["version"] == .number(2) {
          savedSettings = session["settings"]?.object
        } else {
          notes.append("session.json has version \(meta["source_session_version"]!), so its settings were not read")
        }
      } catch {
        notes.append("session.json could not be parsed: \(error)")
      }
    } else {
      notes.append("no session.json")
    }
    if let carriedSettings = carried?.settings {
      var merged = savedSettings ?? JSONObject()
      var kept: [String] = []
      for (key, value) in carriedSettings where !merged.contains(key) && !Settings.bookkeepingKeys.contains(key) {
        merged[key] = value
        kept.append(key)
      }
      if !kept.isEmpty {
        notes.append("kept settings only the database had: \(kept.joined(separator: ", "))")
        savedSettings = merged
      }
    }
    var downloads: [Download] = []
    if let downloadsData {
      meta["source_downloads_sha256"] = Launcher.sha256(downloadsData)
      meta["source_downloads_size"] = String(downloadsData.count)
      do {
        let all = (try JSONValue.parse(downloadsData)["downloads"]?.array ?? []).compactMap { $0.object.map(Download.init) }
        downloads = all.filter { !$0.isPrivate }
        if downloads.count < all.count { notes.append("dropped \(all.count - downloads.count) private downloads") }
      } catch {
        notes.append("downloads.json could not be parsed: \(error)")
      }
    }
    let settings = Settings.hydrated(from: savedSettings.map(JSONValue.object)).values
    meta["count_settings"] = String(settings.count)
    meta["count_downloads"] = String(downloads.count)
    return ImportResult(persisted: PersistedState(settings: settings, downloads: downloads), meta: meta, notes: notes)
  }

  @discardableResult
  public static func importFolder(_ folder: DataFolder, carrying carried: PersistedState?, appVersion: String, now: Date) throws -> ImportResult {
    var result = read(folder, carrying: carried)
    result.meta["app_version"] = appVersion
    result.meta["imported_at"] = String(Int64(now.timeIntervalSince1970 * 1000))
    let fm = FileManager.default
    for suffix in ["", "-journal", "-wal", "-shm"] {
      let path = folder.importing.path + suffix
      if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
    }
    try SolaraDatabase.create(at: folder.importing, writing: result.persisted, meta: result.meta)
    try fsync(folder.importing)
    guard rename(folder.importing.path, folder.database.path) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: folder.database.path])
    }
    try fsync(folder.url)
    if !result.notes.isEmpty {
      let stamp = ISO8601DateFormatter().string(from: now)
      let lines = result.notes.map { "\(stamp) \($0)\n" }.joined()
      if let handle = try? FileHandle(forWritingTo: folder.importLog) {
        handle.seekToEndOfFile()
        handle.write(Data(lines.utf8))
        try? handle.close()
      } else {
        try Data(lines.utf8).write(to: folder.importLog)
      }
    }
    return result
  }

  static func fsync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
    defer { close(fd) }
    _ = Darwin.fsync(fd)
  }
}
