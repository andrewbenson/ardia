import Foundation
import Testing
import SolaraModel
import SolaraStore
@testable import SolaraEngine

@MainActor
final class HistoryHintsClient: EngineClient {
  var rows: [String: [EngineHistoryRow]] = [:]
  var icons: [String: Data] = [:]
  var iconReads: [String] = []
  var historyHandler: (@MainActor @Sendable (HistoryChange) -> Void)?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) { historyHandler = handler }
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { rows[engineProfile] ?? [] }
  func storedFavicon(page: String, engineProfile: String) async throws -> Data? {
    iconReads.append("\(engineProfile):\(page)")
    return icons[engineProfile]
  }
}

@Suite @MainActor struct HistoryHintsTests {
  let page = "https://example.test/"

  func row(_ title: String = "Example") -> EngineHistoryRow {
    EngineHistoryRow(url: page, title: title, visits: 1, visitTimes: [10])
  }

  func store(_ state: BrowserState = BrowserState()) -> Store {
    Store(state: state, checksInvariants: false)
  }

  @Test func noHintsUntilSnapshotIsReady() async {
    let client = HistoryHintsClient()
    client.rows[""] = [row()]
    let catalog = LibraryCatalog(client: client)
    let store = store()
    let provider = HistoryHintsProvider(catalog: catalog, store: store)
    provider.refresh()
    #expect(store.state.caches.historyHints.keys.isEmpty)
    await catalog.start(engineProfiles: [""])
    provider.refresh()
    #expect(store.state.caches.historyHints["default"] == [HistoryHint(url: page, title: "Example", favicon: nil)])
  }

  @Test func hintsCarryNoFaviconsAsTheJSHistoryViewDid() async {
    let client = HistoryHintsClient()
    client.rows[""] = [row()]
    client.icons[""] = Data([1, 2, 3])
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: [""])
    let store = store()
    let provider = HistoryHintsProvider(catalog: catalog, store: store)
    provider.start()
    defer { provider.stop() }
    #expect(store.state.caches.historyHints["default"] == [HistoryHint(url: page, title: "Example", favicon: nil)])
    #expect(client.iconReads.isEmpty)
  }

  @Test func sharedEngineProfilesShareHintsAndRemovedProfilesArePruned() async throws {
    let client = HistoryHintsClient()
    client.rows[""] = [row("Personal")]
    client.rows["work-data"] = [row("Work")]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["", "work-data"])
    var state = BrowserState()
    state.profiles["work"] = Profile(id: "work", name: "Work", color: "blue", icon: nil, createdAt: 1, dataId: "work-data")
    state.profiles["alias"] = Profile(id: "alias", name: "Alias", color: "blue", icon: nil, createdAt: 2, dataId: "work-data")
    state.profileOrder += ["work", "alias"]
    let store = store(state)
    let provider = HistoryHintsProvider(catalog: catalog, store: store)
    provider.start()
    defer { provider.stop() }
    let workHint = HistoryHint(url: page, title: "Work", favicon: nil)
    #expect(store.state.caches.historyHints["default"]?.first?.title == "Personal")
    #expect(store.state.caches.historyHints["work"] == [workHint])
    #expect(store.state.caches.historyHints["alias"] == [workHint])
    try store.transact { session in
      session.update { state in
        state.profiles["alias"] = nil
        state.profileOrder.removeAll { $0 == "alias" }
        state.profiles["work"]?.dataId = "default"
      }
    }
    for _ in 0..<100 where store.state.caches.historyHints["alias"] != nil { await Task.yield() }
    #expect(store.state.caches.historyHints["alias"] == nil)
    #expect(store.state.caches.historyHints["work"]?.first?.title == "Personal")
  }

  @Test func catalogEventsRefreshHintsWithoutJS() async {
    let client = HistoryHintsClient()
    client.rows[""] = [row()]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: [""])
    let store = store()
    let provider = HistoryHintsProvider(catalog: catalog, store: store)
    provider.start()
    defer { provider.stop() }
    client.historyHandler?(.deleted(profile: "", all: false, urls: [page]))
    await catalog.flushPending()
    for _ in 0..<100 where store.state.caches.historyHints["default"]?.isEmpty != true { await Task.yield() }
    #expect(store.state.caches.historyHints["default"] == [])
  }

  @Test func anUnchangedSnapshotCommitsNothing() async {
    let client = HistoryHintsClient()
    client.rows[""] = [row()]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: [""])
    let store = store()
    let provider = HistoryHintsProvider(catalog: catalog, store: store)
    provider.start()
    defer { provider.stop() }
    let rev = store.rev
    provider.refresh()
    provider.refresh()
    #expect(store.rev == rev)
  }
}
