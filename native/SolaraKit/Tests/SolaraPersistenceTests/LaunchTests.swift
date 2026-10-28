import Foundation
import GRDB
import SolaraModel
@testable import SolaraPersistence
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

let refusedFixtures: Set<String> = [
  "unparseable-session", "wrong-version", "wrong-shape-window-null", "wrong-shape-profile-string", "refuse-main-window-null", "refuse-main-window-string",
  "refuse-main-window-tabids-string",
]

func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }

func names(in folder: DataFolder) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []).sorted() }

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
    for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted() where !name.hasPrefix(".") && !refusedFixtures.contains(name) {
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
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
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
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
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
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder, persisted: first.persisted)
    try store.dispatch(Command("updateSettings", [["onlyNative": true, "searchEngine": "bing"]]))
    #expect(writer.flush(timeout: 5))
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia","chosen":["searchEngine"],"inferred":[]}}"#, to: folder.session)
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("session.json"))
    #expect(second.report.movedAside.filter { $0.hasPrefix("solara.sqlite.superseded-") }.count == 1)
    #expect(second.state.settings["searchEngine"] == "ecosia")
    #expect(second.state.settings["onlyNative"] == true)
  }

  @Test func aMarkedSessionJSONDoesNotTriggerAReimport() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"},"nativeExport":{"rev":3,"at":1,"scope":"everything"}}"#, to: folder.session)
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
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
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
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try await Task.sleep(for: .milliseconds(150))
    #expect(writer.flushCount == 1)
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }

  @Test func aWrongShapedValueCostsOnlyThatValue() throws {
    let refused: Set<String> = ["wrong-shape-window-null", "wrong-shape-profile-string"]
    let wrong = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasPrefix("wrong-shape-") && !refused.contains($0) }.sorted()
    #expect(wrong.count >= 14)
    for name in wrong {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      let launch = try open(folder)
      #expect(launch.state.windows.count == 1, "\(name)")
      #expect(launch.state.tabs.count == 3, "\(name)")
      #expect(launch.state.profiles.count == 2, "\(name)")
      #expect(launch.state.settings["searchEngine"] == "duckduckgo", "\(name)")
      #expect(launch.state.settings["appearance"] == "dark", "\(name)")
      #expect(launch.state.downloads.count == 1, "\(name)")
      #expect(!launch.report.notes.isEmpty, "\(name)")
      try launch.database.close()
    }
  }

  @Test func anUnreadableNestedValueIsKeptAsWritten() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-tab-tilefolder-string", into: folder)
    let launch = try open(folder)
    #expect(launch.state.tabs["p"]?.extra["tileFolder"] == "legacy")
    #expect(document(launch.state).contains(#""tileFolder":"legacy""#))
    try launch.database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    #expect(again.state.tabs["p"]?.extra["tileFolder"] == "legacy")
  }

  @Test func aLaunchThatChangesNothingWritesNoShadowAndKeepsTheOriginals() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-closed-tabs-null", into: folder)
    let session = contents(folder.session)
    let downloads = contents(folder.downloads)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 5))
    #expect(contents(folder.session) == session)
    #expect(contents(folder.downloads) == downloads)
    #expect(contents(folder.preNativeSession) == session)
    #expect(contents(folder.preNativeDownloads) == downloads)
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    #expect(writer.flush(timeout: 5))
    #expect(contents(folder.session) != session)
    try launch.database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    #expect(contents(folder.preNativeSession) == session)
    #expect(contents(folder.preNativeDownloads) == downloads)
  }

  @Test func theOriginalsComeBackWhenSessionJSONIsGone() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let first = try open(folder)
    let tabs = first.state.tabs.count
    try first.database.close()
    try FileManager.default.removeItem(at: folder.database)
    try FileManager.default.removeItem(at: folder.session)
    let second = try open(folder)
    #expect(second.state.tabs.count == tabs)
  }

  @Test func anUnreadableSessionIsRefusedAndNothingIsCreated() throws {
    let folder = try scratchFolder()
    try copyFixture("unparseable-session", into: folder)
    #expect(throws: ImportRefused.self) { try open(folder) }
    #expect(!FileManager.default.fileExists(atPath: folder.database.path))
    #expect(String(decoding: contents(folder.importLog) ?? Data(), as: UTF8.self).contains("refused"))
  }

  @Test func losingMostWindowsIsRefused() throws {
    let folder = try scratchFolder()
    let session = #"{"version":2,"windows":[null,null,null,{"id":"w1","profileId":"default","incognito":false,"tabIds":["a"],"activeTabIds":{"default":"a"},"sidebarOpen":true,"createdAt":1}],"tabs":[{"id":"a","windowId":"w1","profileId":"default","url":"https://a/","title":"","pinned":false,"muted":false,"zoom":1,"createdAt":1,"lastActiveAt":1}]}"#
    try write(session, to: folder.session)
    #expect(throws: ImportRefused.self) { try open(folder) }
  }

  @Test func anOrphanedWALIsMovedAsideBeforeTheImportLandsOnItsPath() throws {
    let folder = try scratchFolder()
    var config = Configuration()
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let old = try DatabaseQueue(path: folder.database.path, configuration: config)
    try old.write { db in
      try db.execute(sql: "CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT)")
      for i in 0..<200 { try db.execute(sql: "INSERT INTO setting VALUES (?, ?)", arguments: ["old\(i)", String(repeating: "x", count: 500)]) }
    }
    let wal = try Data(contentsOf: URL(fileURLWithPath: folder.database.path + "-wal"))
    #expect(wal.count > 0)
    try old.close()
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: folder.database.path + suffix) }
    try wal.write(to: URL(fileURLWithPath: folder.database.path + "-wal"))
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    #expect(launch.state.settings["searchEngine"] == "duckduckgo")
    #expect(try launch.database.meta("workspace") == "1")
    let oldRows = try launch.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM setting WHERE key LIKE 'old%'") }
    #expect(oldRows == 0)
    #expect(names(in: folder).contains { $0.hasPrefix("solara.sqlite-wal.orphan-") })
  }

  @Test func movingADatabaseAsideTakesItsSidecarsAlong() throws {
    let folder = try scratchFolder()
    try write("main", to: folder.database)
    try write("wal", to: URL(fileURLWithPath: folder.database.path + "-wal"))
    try write("shm", to: URL(fileURLWithPath: folder.database.path + "-shm"))
    let name = try Launcher.moveAside(folder.database, label: "corrupt", now: now)
    #expect(names(in: folder) == [name, name + "-shm", name + "-wal"].sorted())
  }

  @Test func anUnreadableSettingRowIsSkippedNotFatal() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    let broken = try first.database.pool.write { db -> String in
      let key = try String.fetchOne(db, sql: "SELECT key FROM setting WHERE key != 'searchEngine' ORDER BY position LIMIT 1")!
      try db.execute(sql: "UPDATE setting SET value = '{' WHERE key = ?", arguments: [key])
      return key
    }
    try first.database.close()
    let second = try open(folder)
    #expect(second.report.source == .database)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
    #expect(second.report.notes.contains("skipped unreadable setting \(broken)"))
  }

  @Test func aDatabaseThatCannotBeLoadedIsMovedAsideAndReimported() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "DROP TABLE download")
    }
    try first.database.close()
    let second = try open(folder)
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("could not be read"))
    #expect(second.report.movedAside.first?.contains("unreadable") == true)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func theWriterStartsFromWhatIsOnDiskNotFromTheStore() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try store.dispatch(Command("upsertDownload", [["id": "early", "state": "complete", "profile": ""]]))
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 5))
    let stored = try launch.database.load()
    #expect(stored.settings?["appearance"] == "dark")
    #expect(stored.downloads.map(\.id) == ["early"])
  }

  @Test func aSupersededReimportCarriesTheDocuments() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try open(folder)
    try first.database.pool.write { db in try db.execute(sql: "INSERT INTO document (name, value) VALUES ('onboarding', '{\"done\":true}')") }
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"}}"#, to: folder.session)
    let second = try open(folder)
    guard case .imported = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(try second.database.load().documents["onboarding"] == #"{"done":true}"#)
  }

  @Test func onlyTheLastFewMovedAsideCopiesAreKept() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    for day in 1...6 {
      let name = "solara.sqlite.superseded-2026-10-0\(day)T000000"
      try write("x", to: folder.url.appending(path: name))
      try write("x", to: folder.url.appending(path: name + "-wal"))
    }
    let launch = try open(folder)
    try launch.database.close()
    let kept = names(in: folder).filter { $0.hasPrefix("solara.sqlite.superseded-") }
    #expect(kept == ["04", "05", "06"].flatMap { ["solara.sqlite.superseded-2026-10-\($0)T000000", "solara.sqlite.superseded-2026-10-\($0)T000000-wal"] }.sorted())
    #expect(FileManager.default.fileExists(atPath: folder.preNativeSession.path))
  }

  @Test func aPhaseOneADatabaseKeepsItsOwnDownloads() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let first = try open(folder)
    try first.database.pool.write { db in
      try db.execute(sql: "DELETE FROM meta WHERE key = 'workspace'")
      try db.execute(sql: "DELETE FROM download")
      try db.execute(sql: #"INSERT INTO download (id, position, payload) VALUES ('only-in-db', 0, '{"id":"only-in-db","url":"https://only-in-db/","state":"complete","profile":""}')"#)
    }
    try first.database.close()
    let second = try open(folder)
    #expect(second.state.downloads.map { $0.json["url"] } == ["https://only-in-db/"])
  }

  @Test func unknownFieldsAndAbsentKeysSurviveTheDatabase() throws {
    let folder = try scratchFolder()
    try copyFixture("absent-and-unknown-fields", into: folder)
    try open(folder).database.close()
    let again = try open(folder)
    #expect(again.report.source == .database)
    let doc = try JSONValue.parse(document(again.state))
    let tab = doc["tabs"]?.array?.first { $0["id"] == "a" }?.object
    #expect(tab?.contains("customIcon") == false)
    #expect(tab?.contains("openerId") == false)
    #expect(doc["windows"]?.array?.first?["extraWindowKey"] == true)
  }

  @Test func theQuitFlushFitsItsDeadlineOnALargeSession() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let launch = try open(folder)
    let store = store(for: launch)
    try store.dispatch(Command("createWindow", [[:]]))
    let window = try #require(store.state.windowOrder.first, "the launch came back with no windows: \(launch.report)")
    for i in 0..<2000 { try store.dispatch(Command("newTab", [.string(window), ["url": .string("https://site\(i % 50).example/\(i)"), "background": true]])) }
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    #expect(writer.flush(timeout: 30))
    try store.dispatch(Command("updateTab", [.string(store.state.windows[window]!.tabIds[5]), ["title": "changed"]]))
    let started = Date()
    let cpuSeconds = writer.queue.sync {
      let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      writer.writeEverythingDurably()
      return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1_000_000_000
    }
    let seconds = Date().timeIntervalSince(started)
    print("quit flush of \(store.state.tabs.count) tabs took \(Int(seconds * 1000)) ms, \(Int(cpuSeconds * 1000)) ms of CPU")
    #expect(writer.errors.isEmpty)
    #expect(try launch.database.meta("rev") == String(store.rev))
    #expect(cpuSeconds < 0.3)
    #expect(seconds < 5)
  }

  @Test func phaseOneAOwnsOnlySettingsAndDownloadsAndNeverWritesSessionJSON() throws {
    let folder = try scratchFolder()
    try copyFixture("downloads-and-staging", into: folder)
    let session = contents(folder.session)
    let launch = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    #expect(launch.state.tabs.isEmpty)
    #expect(launch.state.windows.isEmpty)
    #expect(launch.state.downloads.count == 2)
    #expect(try launch.database.meta("workspace") == nil)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, scope: .settingsAndDownloads, clock: { 42 })
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    try store.dispatch(Command("upsertDownload", [["id": "fresh", "state": "complete", "profile": ""]]))
    #expect(writer.flush(timeout: 5))
    #expect(contents(folder.session) == session)
    let shadow = try JSONValue.parse(contents(folder.downloads) ?? Data())
    #expect(shadow["nativeExport"] != nil)
    #expect(shadow["downloads"]?.array?.count == 3)
    try launch.database.close()
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    #expect(again.report.source == .database)
    #expect(again.state.settings["appearance"] == "dark")
    #expect(again.state.downloads.count == 3)
    #expect(again.state.tabs.isEmpty)
    try again.database.close()
    let phaseOneB = try open(folder)
    guard case .imported(let reason) = phaseOneB.report.source else { Issue.record("expected the workspace import"); return }
    #expect(reason.contains("workspace"))
    #expect(phaseOneB.state.settings["appearance"] == "dark")
    #expect(!phaseOneB.state.tabs.isEmpty)
  }

  @Test func aRunWithoutTheNativeStoreLooksLikeAnOlderBuildAndKeepsItsSession() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    let fallbackRun = #"{"version":2,"settings":{"searchEngine":"brave","chosen":["searchEngine"],"inferred":[]}}"#
    try write(fallbackRun, to: folder.session)
    let next = try open(folder)
    guard case .imported = next.report.source else { Issue.record("expected a re-import"); return }
    #expect(next.state.settings["searchEngine"] == "brave")
    let copies = names(in: folder).filter { $0.hasPrefix("session.json.pre-reimport-") }
    #expect(copies.count == 1)
    #expect(contents(folder.url.appending(path: copies[0])) == Data(fallbackRun.utf8))
  }

  @Test func aBusyDatabaseFailsTheLaunchWithoutMovingAnythingAside() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    for day in 1...5 { try write("x", to: folder.url.appending(path: "solara.sqlite.unreadable-2026-10-0\(day)T000000")) }
    var unsafe = Configuration()
    unsafe.allowsUnsafeTransactions = true
    let holder = try DatabaseQueue(path: folder.database.path, configuration: unsafe)
    try holder.inDatabase { db in try db.execute(sql: "BEGIN EXCLUSIVE") }
    #expect(throws: DatabaseError.self) { try open(folder) }
    try holder.inDatabase { db in try db.execute(sql: "ROLLBACK") }
    try holder.close()
    #expect(FileManager.default.fileExists(atPath: folder.database.path))
    #expect(names(in: folder).filter { $0.hasPrefix("solara.sqlite.unreadable-") }.count == 5)
    let launch = try open(folder)
    #expect(launch.report.source == .database)
    #expect(names(in: folder).filter { $0.hasPrefix("solara.sqlite.unreadable-") }.count == 3)
  }

  @Test func aWrongTypedScalarIsKeptAsWrittenThroughTheDatabase() throws {
    for (name, expected) in [
      ("scalar-zoom-string", #""zoom":"1.5""#), ("scalar-created-string", #""createdAt":"1700000000000""#),
      ("scalar-title-null", #""title":null"#), ("scalar-frame-strings", #""frame":["0",0,100,100]"#),
    ] {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      try open(folder).database.close()
      let again = try open(folder)
      #expect(again.report.source == .database, "\(name)")
      #expect(document(again.state).contains(expected), "\(name)")
    }
    let folder = try scratchFolder()
    try copyFixture("scalar-title-absent", into: folder)
    try open(folder).database.close()
    let doc = try JSONValue.parse(document(try open(folder).state))
    #expect(doc["tabs"]?.array?.first?.object?.contains("title") == false)
  }

  @Test func childRowsOfAnUnreadableWindowStayInPlace() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let first = try open(folder)
    let window = try #require(first.state.windowOrder.first, "the launch came back with no windows: \(first.report)")
    let tabs = first.state.windows[window]!.tabIds
    try first.database.pool.write { db in try db.execute(sql: #"UPDATE "window" SET payload = 'not json' WHERE id = ?"#, arguments: [window]) }
    try first.database.close()
    let second = try open(folder)
    let store = store(for: second)
    let writer = PersistenceWriter(store: store, database: second.database, folder: folder, persisted: second.persisted, clock: { 42 })
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5))
    let kept = try second.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM tab WHERE window_id = ?", arguments: [window]) }
    #expect(kept == tabs.count)
  }

  @Test func theOriginalsAreNotReadOnceADatabaseHasExisted() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try open(folder).database.close()
    try FileManager.default.removeItem(at: folder.session)
    try write("not sqlite, not even close, padding padding padding padding padding padding padding", to: folder.database)
    let launch = try open(folder)
    #expect(launch.state.tabs.isEmpty)
  }

  @Test func archivesAndSettingsCountTowardARefusal() throws {
    let nulls = #"{"version":2,"closedTabs":[null,null,null,{"kind":"tab","id":"c","tab":{"url":"https://c/"},"windowId":"w","index":0,"closedAt":1}]}"#
    let folder = try scratchFolder()
    try write(nulls, to: folder.session)
    #expect(throws: ImportRefused.self) { try open(folder) }
    let other = try scratchFolder()
    try write(#"{"version":2,"settings":"dark"}"#, to: other.session)
    #expect(throws: ImportRefused.self) { try open(other) }
  }

  @Test func aClosedWindowWithAnUnreadableTabIsDroppedWhole() throws {
    let folder = try scratchFolder()
    try copyFixture("wrong-shape-closed-window-tab-number", into: folder)
    let launch = try open(folder)
    #expect(launch.state.closedWindows.isEmpty)
  }

  @Test func onlyOneProcessHoldsTheDataFolder() throws {
    let folder = try scratchFolder()
    var first = try FolderLock.acquire(folder)
    #expect(first != nil)
    #expect(FolderLock.holder(folder) == getpid())
    let path = folder.url.appending(path: FolderLock.fileName).path
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    other.arguments = ["-I", "-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept OSError:\n sys.exit(3)\nsys.exit(0)", path]
    try other.run()
    other.waitUntilExit()
    #expect(other.terminationStatus == 3)
    first = nil
    #expect(try FolderLock.acquire(folder) != nil)
  }

  @Test func unreadableWindowsOrProfilesRefuseTheImport() throws {
    for name in ["refuse-main-window-null", "refuse-main-window-string", "refuse-main-window-tabids-string", "wrong-shape-window-null", "wrong-shape-profile-string"] {
      let folder = try scratchFolder()
      try copyFixture(name, into: folder)
      #expect(throws: ImportRefused.self, "\(name)") { try open(folder) }
      #expect(!FileManager.default.fileExists(atPath: folder.database.path), "\(name)")
    }
  }

  @Test func aPermissionErrorFailsTheLaunchAndKeepsTheDatabase() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try open(folder).database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"brave"}}"#, to: folder.session)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path) }
    #expect(throws: (any Error).self) { try open(folder) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path)
    #expect(FileManager.default.fileExists(atPath: folder.database.path))
    #expect(!names(in: folder).contains { $0.hasPrefix("solara.sqlite.unreadable-") })
  }

  @Test func aNumericFlagReadsAsJSWouldAndIsWrittenBackAsIs() throws {
    let folder = try scratchFolder()
    try copyFixture("scalar-sidebar-number", into: folder)
    let launch = try open(folder)
    #expect(launch.state.windows.values.first?.sidebarOpen == true)
    #expect(document(launch.state).contains(#""sidebarOpen":1"#))
  }

  @Test func aWindowsOrTabsValueThatIsNoListIsRefused() throws {
    for session in [#"{"version":2,"windows":"w1","tabs":[]}"#, #"{"version":2,"windows":[],"tabs":"a"}"#] {
      let folder = try scratchFolder()
      try write(session, to: folder.session)
      #expect(throws: ImportRefused.self) { try open(folder) }
    }
  }

  @Test func aSettingsAndDownloadsRunBetweenTwoFullRunsKeepsItsWorkspaceChanges() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let full = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    let fullStore = store(for: full)
    let writer = PersistenceWriter(store: fullStore, database: full.database, folder: folder, persisted: full.persisted, scope: .everything, clock: { 42 })
    try fullStore.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5))
    try full.database.close()
    let narrow = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .settingsAndDownloads)
    try narrow.database.close()
    var session = try JSONValue.parse(contents(folder.session) ?? Data()).object!
    var tabs = session["tabs"]!.array!
    var added = tabs[0].object!
    added["id"] = "added-in-1a"
    added["url"] = "https://added-in-1a.example/"
    tabs.append(.object(added))
    session["tabs"] = .array(tabs)
    var windows = session["windows"]!.array!
    var window = windows[0].object!
    window["tabIds"] = .array(window["tabIds"]!.array! + ["added-in-1a"])
    added["windowId"] = window["id"]!
    tabs[tabs.count - 1] = .object(added)
    session["tabs"] = .array(tabs)
    windows[0] = .object(window)
    session["windows"] = .array(windows)
    session["nativeExport"] = ["rev": 3, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    guard case .imported(let reason) = again.report.source else { Issue.record("expected the workspace re-import"); return }
    #expect(reason.contains("settings-and-downloads"))
    #expect(again.state.tabs["added-in-1a"] != nil)
    #expect(again.state.settings["appearance"] == "dark")
    try again.database.close()
    let steady = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    #expect(steady.report.source == .database)
    #expect(steady.state.tabs["added-in-1a"] != nil)
  }

  @Test func aFirstFullImportFromAOneAMarkedSessionIsNotRepeated() throws {
    let folder = try scratchFolder()
    var session = try JSONValue.parse(Data(contentsOf: fixtures.appending(path: "broken-splits/session.json"))).object!
    session["nativeExport"] = ["rev": 2, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything).database.close()
    let again = try Launcher.open(folder, appVersion: "1.0", now: now, context: context(), scope: .everything)
    #expect(again.report.source == .database)
  }

  @Test func aWorkspaceReimportKeepsACopyOfTheDatabaseFirst() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    try open(folder).database.close()
    var session = try JSONValue.parse(contents(folder.session) ?? Data()).object!
    session["nativeExport"] = ["rev": 9, "at": 1, "scope": "settingsAndDownloads"]
    try write(JSONValue.object(session).text(), to: folder.session)
    let again = try open(folder)
    #expect(names(in: folder).contains { $0.hasPrefix("solara.sqlite.pre-reimport-") })
    try again.database.close()
  }

  @Test func aFrozenWriterWritesNothing() throws {
    let folder = try scratchFolder()
    try copyFixture("broken-splits", into: folder)
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted, clock: { 42 })
    let session = contents(folder.session)
    writer.freeze()
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(writer.flush(timeout: 5))
    #expect(contents(folder.session) == session)
    #expect(try launch.database.load().settings?["appearance"] != "dark")
  }
}
