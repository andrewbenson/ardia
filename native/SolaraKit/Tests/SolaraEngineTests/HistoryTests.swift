import Foundation
import Testing
@testable import SolaraEngine

@MainActor
final class FakeEngineClient: EngineClient {
  var calls: [String] = []
  var rows: [String: [EngineHistoryRow]] = [:]
  var onQuery: (() -> Void)?
  var handler: ((HistoryChange) -> Void)?
  var reads = 0

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) {
    calls.append("observe")
    self.handler = handler
  }

  func watchHistory(engineProfile: String) async throws {
    calls.append("watch:\(engineProfile)")
  }

  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] {
    calls.append("query:\(engineProfile):\(maxUrls):\(maxVisits)")
    reads += 1
    let result = rows[engineProfile] ?? []
    onQuery?()
    return result
  }

  func emit(_ change: HistoryChange) { handler?(change) }
}

@Suite @MainActor struct HistoryTests {
  @Test func watchesBeforeQueryAndReplaysEventsDuringLoad() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://old", title: "Old", visits: 1, visitTimes: [10])]
    client.onQuery = { client.emit(.visit(profile: "p", url: "https://new", title: "New", visits: 1, at: 20)) }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    #expect(client.calls == ["observe", "watch:p", "query:p:5000:50"])
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://new", "https://old"])
    #expect(catalog.history(engineProfile: "p").ready)
  }

  @Test func filtersOrdersLimitsAndSetsFloorBeforeFiltering() async {
    let client = FakeEngineClient()
    client.rows["p"] = (0..<5000).map { index in
      EngineHistoryRow(url: index == 0 ? "chrome://newtab" : "https://\(index)", title: "\(index)", visits: 60, visitTimes: Array(0..<60).map { Double(index * 100 + $0) })
    }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    let snapshot = catalog.history(engineProfile: "p")
    #expect(snapshot.entries.count == 4999)
    #expect(snapshot.entries.first?.url == "https://4999")
    #expect(snapshot.entries.first?.visitTimes.count == 50)
    #expect(snapshot.floor == 59)
  }

  @Test func batchesChangesAndIncrementsRevisionOnlyForChangedViews() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    let initial = catalog.history(engineProfile: "p").revision
    client.emit(.visit(profile: "p", url: "https://a", title: "A", visits: 1, at: 10))
    client.emit(.visit(profile: "p", url: "https://b", title: "B", visits: 1, at: 20))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").revision == initial + 1)
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://b", "https://a"])
    client.emit(.visit(profile: "p", url: "https://a", title: "A", visits: 1, at: 10))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").revision == initial + 1)
  }

  @Test func fullDeletionRequeriesAndLeavesCatalogReady() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = []
    client.emit(.deleted(profile: "p", all: true, urls: []))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.isEmpty)
    #expect(catalog.history(engineProfile: "p").revision == 2)
  }

  @Test func fullDeletionDuringQueryTriggersAnotherQuery() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://stale", title: "Stale", visits: 1, visitTimes: [10])]
    client.onQuery = {
      guard client.reads == 1 else { return }
      client.rows["p"] = []
      client.emit(.deleted(profile: "p", all: true, urls: []))
    }
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.isEmpty)
  }

  @Test func importedRowsForUnknownURLsRequery() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = [.init(url: "https://b", title: "B", visits: 2, visitTimes: [20]), .init(url: "https://a", title: "A", visits: 1, visitTimes: [10])]
    client.emit(.modified(profile: "p", rows: [.init(url: "https://b", title: "B", visits: 2)]))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.map(\.url) == ["https://b", "https://a"])
    client.emit(.modified(profile: "p", rows: [.init(url: "https://a", title: "A2", visits: 3)]))
    await catalog.flushPending()
    #expect(client.reads == 2)
    #expect(catalog.history(engineProfile: "p").entries.last?.title == "A2")
  }

  @Test func timeRangeDeletionRequeriesWithoutURLList() async {
    let client = FakeEngineClient()
    client.rows["p"] = [.init(url: "file:///a", title: "A", visits: 1, visitTimes: [10])]
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    client.rows["p"] = [.init(url: "file:///a", title: "A", visits: 1, visitTimes: [5])]
    client.emit(.deleted(profile: "p", all: true, urls: []))
    await catalog.flushPending()
    #expect(catalog.history(engineProfile: "p").entries.first?.lastVisit == 5)
    #expect(client.reads == 2)
  }

  @Test func observerReceivesInitialAndUpdatedSnapshots() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    var updates = catalog.observe(engineProfile: "p").makeAsyncIterator()
    #expect(await updates.next()?.ready == false)
    await catalog.start(engineProfiles: ["p"])
    #expect(await updates.next()?.revision == 1)
  }

  @Test func profileIsolationAndUnknownProfileStayUnready() async {
    let client = FakeEngineClient()
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p", "incognito:w@p", "q", "p"])
    #expect(client.calls.filter { $0.hasPrefix("query:") }.count == 2)
    #expect(!catalog.history(engineProfile: "incognito:w@p").ready)
    #expect(!catalog.history(engineProfile: "missing").ready)
  }
}
