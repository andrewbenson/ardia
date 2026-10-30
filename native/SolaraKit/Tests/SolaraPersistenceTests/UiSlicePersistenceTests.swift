import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore
import Testing

@Suite struct UiSlicePersistenceTests {
  @Test func transientUiDoesNotRewriteTheDatabaseOrShadowFiles() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    writer.markShadowDirty()
    #expect(writer.flush(timeout: 5) == .saved)
    let session = try Data(contentsOf: folder.session)
    let downloads = try Data(contentsOf: folder.downloads)
    let rows = try launch.database.load().workspace
    let revision = try launch.database.meta("rev")
    try store.dispatch(Command("setAppDark", [false]))
    try store.dispatch(Command("setFind", [.string(tab), ["query": "text"]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(tab)]))
    try store.dispatch(Command("openPanel", [.string(window), "typed"]))
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    #expect(writer.flush(timeout: 5) == .saved)
    #expect(writer.errors.isEmpty)
    #expect(try Data(contentsOf: folder.session) == session)
    #expect(try Data(contentsOf: folder.downloads) == downloads)
    #expect(try launch.database.load().workspace == rows)
    #expect(try launch.database.meta("rev") == revision)
    writer.freeze()
    try launch.database.close()
    try FileManager.default.removeItem(at: folder.url)
  }

  @Test func transientUiDoesNotChangeRowsOrShadowBytes() throws {
    let store = Store()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let before = store.sessionDocument()
    let rows = WorkspaceRows(before)
    try store.dispatch(Command("setAppDark", [false]))
    try store.dispatch(Command("setFind", [.string(tab), ["open": true, "query": "text", "count": 4]]))
    try store.dispatch(Command("setSelectionAnchor", [.string(window), .string(tab)]))
    try store.dispatch(Command("openPanel", [.string(window), "typed"]))
    try store.dispatch(Command("setDownloadsOpen", [.string(window), true]))
    let after = store.sessionDocument()
    #expect(after.json().text() == before.json().text())
    #expect(WorkspaceRows(after) == rows)
    #expect(after.json()["appDark"] == nil)
    #expect(after.json()["find"] == nil)
    for key in ["selection", "selectionAnchors", "windowUi"] { #expect(after.json()[key] == nil) }
  }
}
