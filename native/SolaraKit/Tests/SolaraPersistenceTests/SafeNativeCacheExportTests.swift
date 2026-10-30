import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SafeNativeCacheExportTests {
  @Test func automaticCacheUpdatesLeaveSparseSettingsAndDownloadsRowsUnrepaired() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let normal = try open(folder)
    try normal.database.pool.write { db in
      try db.execute(sql: "DELETE FROM setting")
      try db.execute(sql: "INSERT INTO setting (key, position, value) VALUES ('appearance', 0, '\"light\"')")
      try db.execute(sql: "INSERT INTO download (id, position, payload) VALUES ('original', 0, '{\"id\":\"original\",\"url\":\"https://saved.example/file.zip\",\"state\":\"downloading\"}')")
    }
    try normal.database.close()
    var config = StoreConfig()
    config.safeMode = true
    let loading = LoadContext(config: config, memory: StoreMemory(ids: IdSource(launch: "safe-sparse-cache")), now: now.timeIntervalSince1970 * 1000)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: loading)
    let database = try #require(safe.database)
    let store = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let before = try database.load()
    #expect(store.state.settings.values != before.settings)
    #expect(store.state.downloads.map { $0.persisted() } != before.downloads)
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: safe.persisted)
    defer { writer.freeze(); try? database.close() }
    try EarlyLaunchTabProvider(store: store, environment: "launchTab=off", readCache: { nil }).refresh()
    #expect(writer.flush(timeout: 5) == .saved)
    let after = try database.load()
    #expect(after.settings == before.settings)
    #expect(after.downloads == before.downloads)
    #expect(after.workspace == before.workspace)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try database.load().settings?["appearance"] == "dark")
  }

  @Test func automaticCacheUpdatesPreserveTheDownloadsFileUntilAnExplicitDownloadEdit() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    try copyFixture("downloads-and-staging", into: folder)
    let normal = try open(folder)
    try normal.database.close()
    let original = try Data(contentsOf: folder.downloads)
    var config = StoreConfig()
    config.safeMode = true
    let loading = LoadContext(config: config, memory: StoreMemory(ids: IdSource(launch: "safe-cache")), now: now.timeIntervalSince1970 * 1000)
    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: loading)
    let database = try #require(safe.database)
    let store = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let persisted = try database.load()
    let writer = PersistenceWriter(store: store, database: database, folder: folder, persisted: safe.persisted)
    defer { writer.freeze(); try? database.close() }
    let early = EarlyLaunchTabProvider(store: store, environment: "launchTab=off", readCache: { nil })
    try early.refresh()
    try store.updateAppAppearance(true)
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try Data(contentsOf: folder.downloads) == original)
    let after = try database.load()
    #expect(after.downloads == persisted.downloads)
    #expect(after.settings == persisted.settings)
    #expect(after.workspace == persisted.workspace)
    try store.dispatch(Command("upsertDownload", [["id": "explicit", "url": "https://explicit.example/file.zip", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(try Data(contentsOf: folder.downloads) != original)
    #expect(try database.load().downloads.contains { $0.id == "explicit" })
    #expect(try JSONValue.parse(Data(contentsOf: folder.downloads))["downloads"]?.array?.contains { $0["id"] == "explicit" } == true)
  }
}
