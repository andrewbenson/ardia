import Foundation
import GRDB
import SolaraModel
import SolaraPersistence
import SolaraStore
import Testing

func scratchFolder() throws -> DataFolder {
  let url = FileManager.default.temporaryDirectory.appending(path: "solarakit-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return DataFolder(url: url)
}

func write(_ text: String, to url: URL) throws {
  try Data(text.utf8).write(to: url)
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/sessions")

func copyFixture(_ name: String, into folder: DataFolder) throws {
  for file in ["session.json", "downloads.json"] {
    let source = fixtures.appending(path: name).appending(path: file)
    if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: folder.url.appending(path: file)) }
  }
}

let now = Date(timeIntervalSince1970: 1_793_016_000)
func context(_ launch: String = "test") -> LoadContext { LoadContext(memory: StoreMemory(ids: IdSource(launch: launch)), now: now.timeIntervalSince1970 * 1000) }

func open(_ folder: DataFolder) throws -> Launch { try Launcher.open(folder, appVersion: "1.0", now: now, context: context()) }

func store(for launch: Launch) -> Store {
  Store(state: launch.state, memory: launch.memory, checksInvariants: true, clock: { now.timeIntervalSince1970 * 1000 })
}

func document(_ state: BrowserState) -> String { Store(state: state).sessionDocument().json().canonical }

let legacySession = #"{"version":2,"profiles":{},"profileOrder":[],"settings":{"searchEngine":"duckduckgo","batterySaver":false,"futureKey":{"a":1}},"windows":[],"windowOrder":[],"focusedWindowId":null,"tabs":[],"groups":[],"splits":[],"closedTabs":[],"closedWindows":[]}"#

@Suite struct LaunchTests {
  @Test func firstLaunchImportsTheWholeSessionAndRecordsWhatItDid() throws {
    let folder = try scratchFolder()
    try copyFixture("nested-groups-folders-rows", into: folder)
    let launch = try open(folder)
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(launch.state.tabs.count == 10)
    #expect(launch.state.groups.count == 5)
    #expect(try launch.database.meta("workspace") == "1")
    #expect(try launch.database.meta("count_tabs_before") == "10")
    #expect(try launch.database.meta("count_deletedGroups_after") == "1")
    #expect(!FileManager.default.fileExists(atPath: folder.importing.path))
    let source = try Data(contentsOf: folder.session)
    let original = try Data(contentsOf: fixtures.appending(path: "nested-groups-folders-rows/session.json"))
    #expect(source == original)
  }

  @Test func theDatabaseLoadsTheSameWorkspaceAsTheSessionItCameFrom() throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted() where !name.hasPrefix(".") {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      let first = try open(folder)
      try first.database.close()
      let second = try open(folder)
      #expect(second.report.source == .database, "\(name)")
      #expect(document(second.state) == document(first.state), "\(name)")
      try second.database.close()
    }
  }

  @Test func theWriterKeepsRowsAndTheShadowSessionCurrent() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, rows: launch.rows, clock: { 42 })
    let window = store.state.windowOrder[0]
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://new.example/"]]))
    try store.dispatch(Command("createGroup", [JSONValue(Array(store.state.windows[window]!.tabIds.suffix(2))), ["name": "G"]]))
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5))
    #expect(writer.errors.isEmpty)
    let shadow = try JSONValue.parse(Data(contentsOf: folder.session))
    #expect(shadow["nativeExport"]?["rev"] == JSONValue(store.rev))
    var withoutMarker = shadow.object!
    withoutMarker.removeValue(forKey: "nativeExport")
    #expect(JSONValue.object(withoutMarker).canonical == store.sessionDocument().json().canonical)
    let expected = document(store.state)
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.report.source == .database)
    #expect(document(relaunch.state).count > 0)
    #expect(relaunch.state.tabs.values.contains { $0.url == "https://new.example/" })
    #expect(relaunch.state.groups.values.contains { $0.name == "G" })
    #expect(relaunch.state.settings["appearance"] == "dark")
    let expectedWindows = try JSONValue.parse(expected)["windows"]?.array?.count
    #expect(relaunch.state.windows.count == expectedWindows)
  }

  @Test func closingAndReopeningRowsKeepsTheirOrder() throws {
    let folder = try scratchFolder()
    try copyFixture("perf-seed", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, rows: launch.rows, clock: { 42 })
    let window = store.state.windowOrder[0]
    let tabs = store.state.windows[window]!.tabIds
    try store.dispatch(Command("closeTabs", [JSONValue(Array(tabs.prefix(3)))]))
    try store.dispatch(Command("reopenClosed", [.string(window)]))
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://late.example/"]]))
    #expect(writer.flush(timeout: 5))
    let expected = document(store.state)
    let tabOrder = store.state.tabs.keys
    try launch.database.close()
    let relaunch = try open(folder)
    #expect(relaunch.state.tabs.keys == tabOrder)
    #expect(document(relaunch.state) == expected)
  }

  @Test func anOlderBuildRewritingSessionJSONTriggersAReimportThatKeepsNewerKeys() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    let store = store(for: first)
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder, rows: first.rows)
    try store.dispatch(Command("updateSettings", [["onlyNative": true, "searchEngine": "bing"]]))
    #expect(writer.flush(timeout: 5))
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia","chosen":["searchEngine"],"inferred":[]}}"#, to: folder.session)
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("session.json"))
    #expect(second.report.movedAside.count == 1)
    #expect(second.state.settings["searchEngine"] == "ecosia")
    #expect(second.state.settings["onlyNative"] == true)
  }

  @Test func aMarkedSessionJSONDoesNotTriggerAReimport() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"},"nativeExport":{"rev":3,"at":1}}"#, to: folder.session)
    let second = try open(folder)
    #expect(second.report.source == .database)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aCorruptDatabaseMovesAsideAndReimports() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try write("this is not sqlite at all, not even close, padding padding padding padding padding padding", to: folder.database)
    let launch = try open(folder)
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(launch.report.movedAside.first?.contains("corrupt") == true)
    #expect(launch.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aDatabaseFromANewerBuildIsLeftAloneAndTheShadowImported() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
    try first.database.close()
    let second = try open(folder)
    #expect(second.report.movedAside.first?.contains("newer") == true)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aPhaseOneADatabaseGainsTheWorkspaceAndKeepsItsSettings() throws {
    let folder = try scratchFolder()
    try copyFixture("restore-session-off", into: folder)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "DELETE FROM meta WHERE key = 'workspace'")
      try db.execute(sql: "UPDATE setting SET value = '\"top\"' WHERE key = 'tabLayout'")
    }
    try first.database.close()
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected the workspace import"); return }
    #expect(reason.contains("workspace"))
    #expect(second.state.settings["tabLayout"] == "top")
    #expect(try second.database.meta("workspace") == "1")
  }

  @Test func restoreSessionOffParksPinsAndClosesWindowsAtEveryLaunch() throws {
    let folder = try scratchFolder()
    try copyFixture("restore-session-off", into: folder)
    let launch = try open(folder)
    #expect(launch.state.windows.isEmpty)
    #expect(launch.state.parkedPins["default"]?.tabs.isEmpty == false)
    #expect(launch.state.closedWindows.count == 2)
  }

  @Test func theDownloadsShadowCarriesTheMarkerAndNoPrivateDownloads() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let launch = try open(folder)
    #expect(launch.state.downloads.map(\.id) == ["saved-0", "saved-1"])
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, rows: launch.rows, clock: { 42 })
    try store.dispatch(Command("upsertDownload", [["id": "fresh", "state": "downloading", "profile": ""]]))
    #expect(writer.flush(timeout: 5))
    let shadow = try JSONValue.parse(Data(contentsOf: folder.downloads))
    #expect(shadow["downloads"]?.array?.map { $0["id"]?.string ?? "" } == ["fresh", "saved-0", "saved-1"])
    #expect(shadow["downloads"]?.array?.first?["state"] == "failed")
    #expect(shadow["nativeExport"] != nil)
  }

  @Test func settingsCommitsAreDurableAndFlushWithoutTheDelay() async throws {
    let folder = try scratchFolder()
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, rows: launch.rows)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try await Task.sleep(for: .milliseconds(150))
    #expect(writer.flushCount == 1)
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }
}
