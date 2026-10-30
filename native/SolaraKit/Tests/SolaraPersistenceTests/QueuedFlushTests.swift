import Foundation
import SolaraModel
@testable import SolaraPersistence
import SolaraStore
import Testing

@Suite struct QueuedFlushTests {
  @Test func durableFlushDoesNotWaitForQueuedPinChoiceSettlement() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let window = try store.dispatch(Command("createWindow", [["url": "https://queued.example/"]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("pinTabs", [[.string(tab)], true, true]))
    try store.dispatch(Command("applyState", [["pinChoices": ["default": [tab: 10]]]]))
    try store.dispatch(Command("beginTransaction"))
    try store.dispatch(Command("settlePinChoices", ["default", [tab: 10]]))
    #expect(store.queuedFromSyncCount == 1)
    #expect(writer.flush(timeout: 2) == .saved)
    #expect(store.queuedFromSyncCount == 1)
    #expect(try launch.database.load().sessionJSON()?["pinChoices"]?["default"]?[tab] == 10)
    try store.dispatch(Command("closeTransactions"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(writer.flush(timeout: 2) == .saved)
    #expect(try launch.database.load().sessionJSON()?["pinChoices"]?["default"]?[tab] == nil)
  }
}
