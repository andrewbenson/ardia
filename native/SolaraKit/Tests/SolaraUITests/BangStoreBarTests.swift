import Foundation
import SolaraModel
import SolaraOmnibox
import Testing
@testable import SolaraUI

private actor BarBangFetches {
  private(set) var count = 0

  func reply(_ body: String) -> BangFetchReply {
    count += 1
    return BangFetchReply(status: 200, body: body, etag: "\"bar-v1\"", contentType: "application/json")
  }
}

private func barBangBody() -> String {
  let names = ["gh", "w", "yt", "solarabangsport"] + (0..<1000).map { "barbang\($0)" }
  return "[" + names.map {
    "{\"s\":\"Native \($0)\",\"ts\":[\"\($0)\"],\"u\":\"https://\($0).example/?q={searchTerms}\"}"
  }.joined(separator: ",") + "]"
}

@MainActor
@Suite struct BangStoreBarTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("solara-bar-bangs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func model(_ store: BangStore, variant: BarVariant = .hero) -> HeroBarModel {
    HeroBarModel(windowId: "bang-window", tabId: UUID().uuidString, profileId: "bang-profile", incognito: false,
      settings: { Settings(values: [:]) }, sources: NewTabSources(), bangStore: store, variant: variant)
  }

  @Test func anAlreadyOpenBarPublishesFetchedSuggestionsAndSubmitsTheFetchedBang() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fetches = BarBangFetches()
    let body = barBangBody()
    let store = BangStore(directory: directory, now: { 1_000_000 }, fetch: { _ in await fetches.reply(body) })
    let bars = [BarVariant.hero, .panel, .sidebar].map { model(store, variant: $0) }
    var opened: [String] = []
    for bar in bars {
      bar.events.open = { url, _ in opened.append(url) }
      bar.driverType("!solarabangsport cats")
      if case .search(_, _, _, _, let bang)? = bar.current { #expect(!bang) }
    }
    _ = await store.refreshOnce()
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      let ready = bars.allSatisfy {
        if case .search(_, let url, _, _, let bang)? = $0.current {
          return bang && url == "https://solarabangsport.example/?q=cats"
        }
        return false
      }
      if ready { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    for bar in bars {
      guard case .search(_, let url, _, _, let bang)? = bar.current else {
        Issue.record("Fetched bang did not become the current suggestion")
        continue
      }
      #expect(bang)
      #expect(url == "https://solarabangsport.example/?q=cats")
      bar.submit()
    }
    #expect(opened == Array(repeating: "https://solarabangsport.example/?q=cats", count: 3))
    #expect(await fetches.count == 1)
  }

  @Test func creatingBarsAndTypingOrdinaryTextDoesNotRefresh() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fetches = BarBangFetches()
    let store = BangStore(directory: directory, now: { 1_000_000 }, fetch: { _ in await fetches.reply(barBangBody()) })
    let fetcher = SuggestFetcher(fetch: { _ in throw URLError(.notConnectedToInternet) })
    let bar = HeroBarModel(windowId: "bang-window", tabId: UUID().uuidString, profileId: "bang-profile", incognito: false,
      settings: { Settings(values: [:]) }, sources: NewTabSources(), fetcher: fetcher, bangStore: store,
      initialText: "https://example.com/!path")
    try await Task.sleep(for: .milliseconds(25))
    #expect(await fetches.count == 0)
    bar.driverType("ordinary search")
    try await Task.sleep(for: .milliseconds(25))
    #expect(await fetches.count == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bangs-state.json").path))
  }

  @Test func anUnownedBarDoesNotStayAliveThroughStoreObservation() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BangStore(directory: directory, now: { 1_000_000 }, fetch: { _ in throw URLError(.notConnectedToInternet) })
    weak var released: HeroBarModel?
    do {
      let bar = model(store)
      released = bar
    }
    #expect(released == nil)
    _ = await store.refresh()
    await Task.yield()
    #expect(released == nil)
  }
}
