import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct SyncAnchorTests {
  @Test func theAnchorIsSavedWithTheRowsAndReturnedAtLaunch() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor(#"{"journalG":3}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.persisted.syncAnchor == #"{"journalG":3}"#)
    #expect(relaunch.state.settings["appearance"] == "dark")
  }

  @Test func anAnchorSetBeforeASettingIsInTheSameOrAnEarlierTransaction() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor(#"{"journalG":4}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    #expect(writer.flush(timeout: 5) == .saved)
    let loaded = try launch.database.load()
    #expect(loaded.settings?["appearance"] == "light")
    #expect(loaded.syncAnchor == #"{"journalG":4}"#, "a setting is never on disk without the anchor noted before it")
  }

  @Test func aKillBeforeTheFlushLosesTheAnchorAndTheSettingTogether() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    #expect(writer.flush(timeout: 5) == .saved)
    writer.freeze()
    writer.setSyncAnchor(#"{"journalG":5}"#)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    let loaded = try launch.database.load()
    #expect(loaded.syncAnchor == nil)
    #expect(loaded.settings?["appearance"] != "dark")
  }

  @Test func anUnchangedAnchorWritesNothing() throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    writer.setSyncAnchor("a")
    #expect(writer.flush(timeout: 5) == .saved)
    let flushes = writer.flushCount
    writer.setSyncAnchor("a")
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.flushCount == flushes)
  }
}
