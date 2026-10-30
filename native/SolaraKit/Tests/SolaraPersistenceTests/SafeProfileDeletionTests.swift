import Foundation
import GRDB
import SolaraModel
import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SafeProfileDeletionTests {
  @Test func refusedDeletionKeepsTheProfileAndNeverQueuesDataDeletionAcrossFlushAndReopen() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    try copyFixture("nested-groups-folders-rows", into: folder)
    let normal = try open(folder)
    let normalStore = store(for: normal)
    let normalWriter = PersistenceWriter(store: normalStore, database: normal.database, folder: folder, persisted: normal.persisted)
    let profileId = try #require(normalStore.dispatch(Command("createProfile", [["name": "Keep this profile"]])).result?.string)
    let profile = try #require(normalStore.state.profiles[profileId]).jsonValue.canonical
    #expect(normalStore.state.profileOrder.count == 2)
    #expect(normalWriter.flush(timeout: 5) == .saved)
    #expect(normalWriter.errors.isEmpty)
    normalWriter.freeze()
    let originalRow = try #require(normal.database.pool.read { db in
      try String.fetchOne(db, sql: "SELECT payload FROM profile WHERE id = ?", arguments: [profileId])
    })
    try normal.database.close()

    let safe = try Launcher.openSafe(folder, appVersion: "1.0", now: now, context: context("safe-delete"))
    let database = try #require(safe.database)
    var config = StoreConfig()
    config.safeMode = true
    let safeStore = Store(state: safe.state, memory: safe.memory, config: config, checksInvariants: true)
    let writer = PersistenceWriter(store: safeStore, database: database, folder: folder, persisted: safe.persisted)
    #expect(safeStore.state.profiles[profileId]?.jsonValue.canonical == profile)
    #expect(safeStore.state.profileOrder.count == 2)
    #expect(safeStore.state.orphanedProfileData.isEmpty)
    #expect(throws: CommandError.self) {
      try safeStore.dispatch(Command("deleteProfile", [.string(profileId)]))
    }
    #expect(safeStore.state.profiles[profileId]?.jsonValue.canonical == profile)
    #expect(safeStore.state.profileOrder.contains(profileId))
    #expect(safeStore.state.orphanedProfileData.isEmpty)
    try safeStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    writer.freeze()
    #expect(try database.pool.read { db in
      try String.fetchOne(db, sql: "SELECT payload FROM profile WHERE id = ?", arguments: [profileId])
    } == originalRow)
    #expect(safeStore.state.orphanedProfileData.isEmpty)
    try database.close()

    let reopened = try open(folder)
    defer { try? reopened.database.close() }
    #expect(reopened.report.source == .database)
    #expect(reopened.state.profiles[profileId]?.jsonValue.canonical == profile)
    #expect(reopened.state.profileOrder.contains(profileId))
    #expect(reopened.state.orphanedProfileData.isEmpty)
    #expect(reopened.state.settings["appearance"] == "dark")
    #expect(try reopened.database.pool.read { db in
      try String.fetchOne(db, sql: "SELECT payload FROM profile WHERE id = ?", arguments: [profileId])
    } == originalRow)
  }
}
