import Foundation
import Testing
@testable import SolaraEngine

@MainActor
final class FakeFaviconClient: EngineClient {
  var stored: Data?
  var fetched: Data?
  var bundled: [Bool: Data] = [:]
  var reads = 0
  var fetches = 0
  var writes = 0
  var fetchDelay = false
  var historyHandler: (@MainActor @Sendable (HistoryChange) -> Void)?

  func observeHistory(_ handler: @escaping @MainActor @Sendable (HistoryChange) -> Void) { historyHandler = handler }
  func watchHistory(engineProfile: String) async throws {}
  func queryHistory(engineProfile: String, maxUrls: Int, maxVisits: Int) async throws -> [EngineHistoryRow] { [] }

  func storedFavicon(page: String, engineProfile: String) async throws -> Data? {
    reads += 1
    return stored
  }

  func fetchFavicon(source: String, engineProfile: String) async -> Data? {
    fetches += 1
    if fetchDelay { try? await Task.sleep(for: .milliseconds(20)) }
    return fetched
  }

  func bundledFavicon(page: String, dark: Bool) async -> Data? { bundled[dark] }

  func storeFavicon(page: String, source: String, data: Data, engineProfile: String) async throws { writes += 1 }
  func emit(_ change: HistoryChange) { historyHandler?(change) }
}

@Suite @MainActor struct FaviconTests {
  @Test func lookupOrderAndAppearance() async {
    let client = FakeFaviconClient()
    client.stored = Data([1])
    client.fetched = Data([2])
    client.bundled = [false: Data([3]), true: Data([4])]
    let library = FaviconLibrary(client: client)
    let page = "https://example.test/a#part"
    #expect(await library.favicon(page: page, source: "https://example.test/icon", engineProfile: "", appearance: false)?.source == "chrome")
    #expect(client.fetches == 0)
    client.stored = nil
    library.invalidate(engineProfile: "")
    #expect(await library.favicon(page: page, source: "https://example.test/icon", engineProfile: "", appearance: false)?.data == Data([2]))
    #expect(client.writes == 1)
    client.fetched = nil
    library.invalidate(engineProfile: "")
    #expect(await library.favicon(page: page, source: "missing", engineProfile: "", appearance: false)?.data == Data([3]))
    #expect(await library.favicon(page: page, source: "missing", engineProfile: "", appearance: true)?.data == Data([4]))
  }

  @Test func boundedMissesAndHits() async {
    let client = FakeFaviconClient()
    let library = FaviconLibrary(client: client, limit: 3)
    for i in 0..<5 {
      _ = await library.favicon(page: "https://example.test/\(i)", engineProfile: "", appearance: false)
    }
    #expect(library.cachedCount == 3)
    #expect(client.reads == 5)
    _ = await library.favicon(page: "https://example.test/0", engineProfile: "", appearance: false)
    #expect(client.reads == 6)
  }

  @Test func missesExpireAndVisitsForgetThem() async {
    let client = FakeFaviconClient()
    var clock = Date(timeIntervalSince1970: 0)
    let library = FaviconLibrary(client: client, missLifetime: 30, now: { clock })
    let page = "https://late.test/"
    #expect(await library.favicon(page: page, engineProfile: "", appearance: false) == nil)
    #expect(await library.favicon(page: page, engineProfile: "", appearance: false) == nil)
    #expect(client.reads == 1)
    clock = clock.addingTimeInterval(31)
    #expect(await library.favicon(page: page, engineProfile: "", appearance: false) == nil)
    #expect(client.reads == 2)
    library.forgetMisses(engineProfile: "", pages: [page])
    #expect(await library.favicon(page: page, engineProfile: "", appearance: false) == nil)
    #expect(client.reads == 3)
  }

  @Test func deduplicatesConcurrentFetches() async {
    let client = FakeFaviconClient()
    client.fetched = Data([9])
    client.fetchDelay = true
    let library = FaviconLibrary(client: client)
    async let first = library.favicon(page: "https://a.test/", source: "https://a.test/icon", engineProfile: "p", appearance: false)
    async let second = library.favicon(page: "https://a.test/", source: "https://a.test/icon", engineProfile: "p", appearance: false)
    #expect(await first?.data == Data([9]))
    #expect(await second?.data == Data([9]))
    #expect(client.reads == 1)
    #expect(client.fetches == 1)
    #expect(client.writes == 1)
  }

  @Test func deletionInvalidatesOnlyMatchingPage() async {
    let client = FakeFaviconClient()
    client.stored = Data([5])
    let library = FaviconLibrary(client: client)
    _ = await library.favicon(page: "https://a.test/", engineProfile: "p", appearance: false)
    _ = await library.favicon(page: "https://b.test/", engineProfile: "p", appearance: false)
    library.invalidate(engineProfile: "p", pages: ["https://a.test/"])
    _ = await library.favicon(page: "https://a.test/", engineProfile: "p", appearance: false)
    _ = await library.favicon(page: "https://b.test/", engineProfile: "p", appearance: false)
    #expect(client.reads == 3)
  }

  @Test func catalogInvalidatesOnHistoryDeletion() async {
    let client = FakeFaviconClient()
    client.stored = Data([7])
    let catalog = LibraryCatalog(client: client)
    await catalog.start(engineProfiles: ["p"])
    _ = await catalog.favicons?.favicon(page: "https://a.test/", engineProfile: "p", appearance: false)
    client.emit(.deleted(profile: "p", all: false, urls: ["https://a.test/"]))
    _ = await catalog.favicons?.favicon(page: "https://a.test/", engineProfile: "p", appearance: false)
    #expect(client.reads == 2)
  }

  @Test func deletionWhileFetchIsPendingPreventsWrite() async {
    let client = FakeFaviconClient()
    client.fetched = Data([2])
    client.fetchDelay = true
    let library = FaviconLibrary(client: client)
    let task = Task { await library.favicon(page: "https://a.test/", source: "https://a.test/icon", engineProfile: "p", appearance: false) }
    for _ in 0..<100 where client.fetches == 0 { try? await Task.sleep(for: .milliseconds(1)) }
    library.invalidate(engineProfile: "p", pages: ["https://a.test/"])
    #expect(await task.value == nil)
    #expect(client.writes == 0)
  }

  @Test func privateProfileDoesNotReadOrWriteChrome() async {
    let client = FakeFaviconClient()
    client.stored = Data([1])
    client.fetched = Data([2])
    let library = FaviconLibrary(client: client)
    #expect(await library.favicon(page: "https://a.test/", source: "https://a.test/icon", engineProfile: "incognito:w@p", appearance: false)?.data == Data([2]))
    #expect(client.reads == 0)
    #expect(client.writes == 0)
  }
}
