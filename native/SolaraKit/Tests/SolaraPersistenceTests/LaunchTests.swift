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

let legacySession = #"{"version":2,"profiles":{},"profileOrder":[],"settings":{"searchEngine":"duckduckgo","batterySaver":false,"futureKey":{"a":1}},"windows":[],"windowOrder":[],"focusedWindowId":null,"tabs":[],"groups":[],"splits":[],"closedTabs":[],"closedWindows":[]}"#
let legacyDownloads = #"{"version":2,"downloads":[{"id":"x1","state":"downloading","url":"https://a/1"},{"id":"x2","state":"complete","profile":"incognito:w@default"},{"id":"x3","state":"complete","staging":"/s","stagingId":"u","destination":"/d/f"}]}"#

@Suite struct LaunchTests {
  @Test func firstLaunchImportsSettingsAndDownloads() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try write(legacyDownloads, to: folder.downloads)
    let launch = try Launcher.open(folder, appVersion: "1.0", now: Date(timeIntervalSince1970: 1_700_000_000))
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    let settings = launch.state.settings
    #expect(settings["searchEngine"] == "duckduckgo")
    #expect(settings["batterySaverWhen"] == "never")
    #expect(settings["futureKey"] == ["a": 1])
    #expect(settings.chosen == ["searchEngine", "futureKey", "batterySaverWhen", "hideToolbarWhileScrolling", "migrations"])
    #expect(launch.state.downloads.map(\.id) == ["saved-0", "saved-1"])
    #expect(launch.state.downloads.map(\.state) == ["failed", "complete"])
    #expect(launch.state.downloads[1].json["stagingId"] == "u")
    #expect(try launch.database.meta("imported_from") == "session.json")
    #expect(try launch.database.meta("count_downloads") == "2")
    #expect(FileManager.default.fileExists(atPath: folder.importLog.path))
    #expect(!FileManager.default.fileExists(atPath: folder.importing.path))
    let source = try String(contentsOf: folder.session, encoding: .utf8)
    #expect(source == legacySession)
  }

  @Test func secondLaunchReadsTheDatabaseWhenTheFilesAreUnchanged() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try write(legacyDownloads, to: folder.downloads)
    let first = try Launcher.open(folder, appVersion: "1.0")
    try first.database.close()
    let second = try Launcher.open(folder, appVersion: "1.0")
    #expect(second.report.source == .database)
    #expect(second.state == first.state)
  }

  @Test func anOlderBuildRewritingSessionJSONTriggersAReimportThatKeepsNewerKeys() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try Launcher.open(folder, appVersion: "1.0")
    let store = Store(state: first.state, checksInvariants: true)
    let writer = PersistenceWriter(store: store, database: first.database, folder: folder)
    try store.dispatch(.updateSettings(patch: ["onlyNative": true, "searchEngine": "bing"], fromSync: false))
    #expect(writer.flush())
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia","chosen":["searchEngine"],"inferred":[]}}"#, to: folder.session)
    let second = try Launcher.open(folder, appVersion: "1.0")
    guard case .imported(let reason) = second.report.source else { Issue.record("expected a re-import"); return }
    #expect(reason.contains("session.json"))
    #expect(second.report.movedAside.count == 1)
    #expect(second.state.settings["searchEngine"] == "ecosia")
    #expect(second.state.settings["onlyNative"] == true)
  }

  @Test func aMarkedSessionJSONDoesNotTriggerAReimport() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try Launcher.open(folder, appVersion: "1.0")
    try first.database.close()
    try write(#"{"version":2,"settings":{"searchEngine":"ecosia"},"nativeExport":{"rev":3,"at":1}}"#, to: folder.session)
    let second = try Launcher.open(folder, appVersion: "1.0")
    #expect(second.report.source == .database)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aCorruptDatabaseMovesAsideAndReimports() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    try write("this is not sqlite at all, not even close, padding padding padding padding padding padding", to: folder.database)
    let launch = try Launcher.open(folder, appVersion: "1.0")
    guard case .imported = launch.report.source else { Issue.record("expected an import"); return }
    #expect(launch.report.movedAside.first?.contains("corrupt") == true)
    #expect(launch.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func aDatabaseFromANewerBuildIsLeftAloneAndTheShadowImported() throws {
    let folder = try scratchFolder()
    try write(legacySession, to: folder.session)
    let first = try Launcher.open(folder, appVersion: "1.0")
    try first.database.pool.write { db in
      try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
    }
    try first.database.close()
    let second = try Launcher.open(folder, appVersion: "1.0")
    #expect(second.report.movedAside.first?.contains("newer") == true)
    #expect(second.state.settings["searchEngine"] == "duckduckgo")
  }

  @Test func theWriterFlushesRowsAndAMarkedDownloadsShadow() throws {
    let folder = try scratchFolder()
    let launch = try Launcher.open(folder, appVersion: "1.0")
    let store = Store(state: launch.state, checksInvariants: true, clock: { 42 })
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, clock: { 42 })
    try store.dispatch(.upsertDownload(Download(json: ["id": "a", "state": "downloading"]), privateSession: nil, focusedWindowShowing: nil))
    try store.dispatch(.upsertDownload(Download(json: ["id": "p", "state": "complete", "offTheRecord": true]), privateSession: PrivateDownloadSession(open: true), focusedWindowShowing: nil))
    #expect(writer.flush())
    #expect(writer.errors.isEmpty)
    let shadow = try JSONValue.parse(Data(contentsOf: folder.downloads))
    #expect(shadow == ["version": 2, "downloads": [["id": "a", "state": "failed"]], "nativeExport": ["rev": 2, "at": 42]])
    let rows = try launch.database.load()
    #expect(rows.downloads.map(\.id) == ["a"])
    try launch.database.close()
    let relaunch = try Launcher.open(folder, appVersion: "1.0")
    #expect(relaunch.report.source == .database)
    #expect(relaunch.state.downloads.map(\.id) == ["saved-0"])
  }

  @Test func settingsCommitsAreDurableAndFlushWithoutTheDelay() async throws {
    let folder = try scratchFolder()
    let launch = try Launcher.open(folder, appVersion: "1.0")
    let store = Store(state: launch.state, checksInvariants: true)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder)
    try store.dispatch(.updateSettings(patch: ["appearance": "dark"], fromSync: false))
    try await Task.sleep(for: .milliseconds(100))
    #expect(writer.flushCount == 1)
    #expect(try launch.database.load().settings?["appearance"] == "dark")
  }
}
