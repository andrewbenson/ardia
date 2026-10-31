import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SafeWholeFolderTests {
  struct FolderImage {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
  }

  func image(_ folder: DataFolder) throws -> FolderImage {
    let root = folder.url.resolvingSymlinksInPath()
    let entries = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]))
    var result = FolderImage()
    for case let entry as URL in entries {
      let relative = entry.resolvingSymlinksInPath().pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
      let kind = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if kind.isDirectory == true {
        result.directories.insert(relative)
      } else {
        #expect(kind.isRegularFile == true, "Unexpected fixture entry: \(relative)")
        result.files[relative] = try Data(contentsOf: entry)
      }
    }
    return result
  }

  func sqlName(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

  func rowBytes(_ rows: [Row]) -> Data {
    let lines = rows.map { row in
      row.map { column in
        switch column.1.storage {
        case .null: "null"
        case .int64(let value): "integer:\(value)"
        case .double(let value): "real:\(value.bitPattern)"
        case .string(let value): "text:" + Data(value.utf8).base64EncodedString()
        case .blob(let value): "blob:" + value.base64EncodedString()
        }
      }.joined(separator: "|")
    }
    return Data(lines.joined(separator: "\n").utf8)
  }

  func tableBytes(_ folder: DataFolder) throws -> [String: Data] {
    var config = Configuration()
    config.readonly = true
    let reader = try DatabaseQueue(path: folder.database.path, configuration: config)
    defer { try? reader.close() }
    return try reader.read { db in
      var result: [String: Data] = [:]
      let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
      for table in tables {
        let primaryKey = try db.primaryKey(table).columns
        #expect(!primaryKey.isEmpty, "A deterministic primary-key dump is required for \(table)")
        let order = primaryKey.map(sqlName).joined(separator: ", ")
        result[table] = rowBytes(try Row.fetchAll(db, sql: "SELECT * FROM \(sqlName(table)) ORDER BY \(order)"))
      }
      result["sqlite_master"] = rowBytes(try Row.fetchAll(db, sql: "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"))
      return result
    }
  }

  func fixture() throws -> DataFolder {
    let folder = try scratchFolder()
    try copyFixture("nested-groups-folders-rows", into: folder)
    let normal = try open(folder)
    let normalStore = store(for: normal)
    let writer = PersistenceWriter(store: normalStore, database: normal.database, folder: folder, persisted: normal.persisted)
    try normalStore.dispatch(Command("upsertDownload", [["id": "saved-download", "url": "https://saved.example/file.zip", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    writer.freeze()
    try normal.database.close()
    let files: [String: String] = [
      "bookmarks-cache.json": #"{"version":1,"trees":{"":{"roots":[],"nodes":[]}}}"#,
      "switches-cache.json": #"{"version":1,"switches":{"launchTab":true}}"#,
      "favicons-default.json": #"{"version":1,"icons":{"https://saved.example":"saved-icon"}}"#,
      "bookmarks.json": #"{"bookmarks":{"nodes":{},"roots":{}}}"#,
      "history.json": #"{"history":{"default":[]}}"#,
      "launch-look.json": #"{"version":1,"appearance":"light"}"#,
      "launch-layout.json": #"{"version":1,"sidebarWidth":240}"#,
      "launch-picture-saved.png": "saved launch picture bytes",
      "Chromium/Default/Solara Favicons/saved.png": "saved favicon bytes",
      "release-notes.json": #"{"version":"1.0"}"#,
      "onboarding.json": #"{"complete":true}"#,
      "Chromium/NavigationDownloads.json": #"{"https://saved.example/file.zip":1793016000}"#,
      "live.json": #"{"version":1,"lanes":[],"cards":[]}"#,
      "Scripts/extension/manifest.json": #"{"manifest_version":3,"name":"Saved script","version":"1.0","content_scripts":[{"matches":["https://saved.example/*"],"js":["saved.js"]}]}"#,
      "Scripts/extension/saved.js": "globalThis.savedScript = true;",
      "Scripts/status.json": #"{"state":"loaded"}"#,
      "user-scripts/saved.js": "globalThis.otherSavedScript = true;",
      "sync/ledger.json": #"{"anchor":"saved-anchor"}"#,
    ]
    for (name, text) in files {
      let file = folder.url.appending(path: name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
    for profile in ["Default", "Profile 1"] {
      let directory = folder.url.appending(path: "Chromium/\(profile)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(#"{"checksum":"saved","roots":{"bookmark_bar":{"children":[{"name":"Saved","type":"url","url":"https://saved.example"}]}}}"#.utf8).write(to: directory.appending(path: "Bookmarks"))
      let history = try DatabaseQueue(path: directory.appending(path: "History").path)
      try history.write { db in
        try db.execute(sql: "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT NOT NULL); INSERT INTO urls VALUES (1, 'https://saved.example')")
      }
      try history.close()
    }
    return folder
  }

  @Test func safeLaunchFlushAndClosePreserveTheWholeExistingFolderExceptSettingsAndDownloads() throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let beforeTables = try tableBytes(folder)
    let beforeFiles = try image(folder)
    for required in ["workspace", "tab", "profile", "setting", "download"] {
      #expect(try #require(beforeTables[required]).isEmpty == false, "The fixture must exercise \(required)")
    }
    var config = StoreConfig()
    config.safeMode = true
    config.handOffPinsImmediately = false
    let loading = LoadContext(config: config, memory: StoreMemory(ids: IdSource(launch: "safe-whole-folder")), now: now.timeIntervalSince1970 * 1000)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: loading)
    let database = try #require(safe.database)
    let safeStore = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let writer = PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted, scope: .settingsAndDownloads)
    defer { writer.freeze(); try? database.close() }
    #expect(safeStore.state.tabs.isEmpty)
    #expect(safeStore.state.windows.isEmpty)
    let profile = try #require(safeStore.state.profileOrder.first)
    let window = try #require(try safeStore.dispatch(Command("createWindow", [["url": "https://temporary.example/kept"]])).result?.string)
    let tab = try #require(try safeStore.dispatch(Command("newTab", [.string(window), ["url": "https://temporary.example/closed"]])).result?.string)
    #expect(safeStore.state.tabs[tab] != nil)
    try safeStore.dispatch(Command("closeTab", [.string(tab)]))
    let savedProfile = safeStore.state.profiles[profile]
    #expect(throws: CommandError.self) {
      try safeStore.dispatch(Command("updateProfile", [.string(profile), ["name": "Refused safe rename"]]))
    }
    try safeStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try safeStore.dispatch(Command("upsertDownload", [["id": "safe-download", "url": "https://temporary.example/new.zip", "state": "complete", "profile": ""]]))
    #expect(safeStore.state.tabs[tab] == nil)
    #expect(safeStore.state.closedTabs.contains(where: { $0.tabId == tab }))
    #expect(safeStore.state.profiles[profile] == savedProfile)
    let early = EarlyLaunchTabProvider(store: safeStore, environment: "launchTab=off", readCache: { nil })
    try early.refresh()
    #expect(safeStore.sessionDocument().launchTab == .null)
    let enabled = EarlyLaunchTabProvider(store: safeStore, environment: "launchTab=on", readCache: { nil })
    try enabled.refresh()
    try safeStore.updateAppAppearance(true)
    #expect(safeStore.sessionDocument().launchBackdrop != .null)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    #expect(writer.flushCount > 0)
    writer.freeze()
    try database.close()
    let afterTables = try tableBytes(folder)
    let afterFiles = try image(folder)
    let mutableTables: Set<String> = ["setting", "download"]
    #expect(Set(beforeTables.keys) == Set(afterTables.keys))
    for table in beforeTables.keys where !mutableTables.contains(table) {
      #expect(afterTables[table] == beforeTables[table], "Safe mode changed rows in \(table)")
    }
    for table in mutableTables {
      #expect(afterTables[table] != beforeTables[table], "The safe write did not change \(table)")
    }
    let mutableFileReasons = [
      "solara.sqlite": "Only setting and download rows may change in the existing current database; profile fields and order are refused.",
      "downloads.json": "The safe writer exports changed downloads.",
      "solara.sqlite-wal": "SQLite may create or remove its write-ahead log while persisting settings and downloads.",
      "solara.sqlite-shm": "SQLite may create or remove shared-memory coordination for its write-ahead log.",
    ]
    let optionalSidecars: Set<String> = ["solara.sqlite-wal", "solara.sqlite-shm"]
    let changedNames = Set(beforeFiles.files.keys).symmetricDifference(Set(afterFiles.files.keys))
    #expect(changedNames.subtracting(optionalSidecars).isEmpty, "Unexpected files added or removed: \(changedNames)")
    #expect(afterFiles.directories == beforeFiles.directories)
    for (name, bytes) in beforeFiles.files where mutableFileReasons[name] == nil {
      #expect(afterFiles.files[name] == bytes, "Safe mode changed \(name)")
    }
    #expect(afterFiles.files["downloads.json"] != beforeFiles.files["downloads.json"])
    for profile in ["Default", "Profile 1"] {
      let directory = "Chromium/\(profile)"
      #expect(afterFiles.directories.contains(directory))
      for name in ["Bookmarks", "History"] {
        let file = "\(directory)/\(name)"
        let original = try #require(beforeFiles.files[file])
        let kept = try #require(afterFiles.files[file])
        #expect(!original.isEmpty)
        #expect(kept.count >= original.count, "Safe mode shortened \(file)")
        #expect(kept == original)
      }
    }
  }
}
