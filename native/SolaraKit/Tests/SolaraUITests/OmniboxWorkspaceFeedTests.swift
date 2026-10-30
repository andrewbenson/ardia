import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

@Suite(.serialized)
@MainActor
struct OmniboxWorkspaceFeedTests {
  private func state(_ title: String = "Initial", profileId: String = "default", windowId: String = "window") -> BrowserState {
    var state = BrowserState()
    var window = BrowserWindow(id: windowId, profileId: profileId, incognito: profileId.hasPrefix("incognito:"), frame: nil, createdAt: 0)
    window.tabIds = ["tab"]
    window.activeTabIds[profileId] = "tab"
    state.windows[windowId] = window
    var tab = Tab(id: "tab", windowId: windowId, profileId: profileId, url: "https://example.com/", now: 0)
    tab.title = title
    state.tabs[tab.id] = tab
    return state
  }

  @Test func subscribesBeforeAtomicInitialReadAndRejectsQueuedOlderCommit() async throws {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { store })
    var atReady: [String] = []
    feed.onStatus = { status in
      if status.ready { atReady = sources.tabs("default").map(\.title) }
    }
    feed.didSubscribe = { store in
      _ = try! store.dispatch(Command("updateTab", [.string("tab"), .object(["title": .string("During subscribe")])]))
    }
    feed.reconcile()
    #expect(atReady == ["During subscribe"])
    #expect(sources.omniboxBenchSnapshot(profileId: "default")["sourceMode"] as? String == "native-store")
    feed.receive(state: state("Stale"), revision: 0, generation: feed.generation)
    await Task.yield()
    #expect(sources.tabs("default").map(\.title) == ["During subscribe"])
    feed.stop()
  }

  @Test func subscribedCommitsApplyAndDetectOwnershipLossBeforePolling() async throws {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    var owned = true
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { owned }, resolve: { store })
    feed.reconcile()
    _ = try store.dispatch(Command("updateTab", [.string("tab"), .object(["title": .string("Committed")])]))
    for _ in 0..<20 {
      if sources.tabs("default").first?.title == "Committed" { break }
      await Task.yield()
    }
    #expect(sources.tabs("default").map(\.title) == ["Committed"])
    owned = false
    _ = try store.dispatch(Command("updateTab", [.string("tab"), .object(["title": .string("Closed ownership")])]))
    for _ in 0..<20 {
      if !feed.status.ready { break }
      await Task.yield()
    }
    #expect(feed.status.mode == "js-feed" && !feed.status.ready)
    #expect(sources.tabs("default").isEmpty)
    feed.stop()
  }

  @Test func outOfOrderSnapshotsAndUnrelatedCommitsDoNotRegressOrRepublish() {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { store })
    feed.reconcile()
    let ticket = feed.generation
    feed.receive(state: state("Latest"), revision: 8, generation: ticket)
    let sourceRevision = sources.revision
    feed.receive(state: state("Old"), revision: 4, generation: ticket)
    feed.receive(state: state("Latest"), revision: 9, generation: ticket)
    #expect(sources.tabs("default").map(\.title) == ["Latest"])
    #expect(sources.revision == sourceRevision)
    feed.stop()
  }

  @Test func unresolvedHandleFallsBackWithinTwoSecondsAndKeepsJSInCharge() {
    let sources = NewTabSources()
    var resolutions = 0
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { resolutions += 1; return nil }, clock: { 10 })
    feed.reconcile(now: 10)
    #expect(feed.status.mode == "js-feed" && !feed.status.ready)
    feed.setTabs([TabRow(id: "fallback", url: "", title: "JS", favicon: nil)], profileId: "default", epoch: 0)
    feed.reconcile(now: 12)
    #expect(feed.status.epoch == 1)
    #expect(sources.tabs("default").map(\.title) == ["JS"])
    let epoch = feed.status.epoch
    feed.reconcile(now: 100)
    #expect(feed.status.epoch == epoch)
    #expect(resolutions >= 3)
    feed.stop()
  }

  @Test func resolverCanBecomeReadyAfterTimeoutWithoutDiscardingFallbackEarly() {
    let sources = NewTabSources()
    var store: Store?
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { store }, clock: { 10 })
    feed.reconcile(now: 10)
    feed.reconcile(now: 12)
    let fallbackEpoch = feed.status.epoch
    feed.setTabs([TabRow(id: "fallback", url: "", title: "Fallback", favicon: nil)], profileId: "default", epoch: fallbackEpoch)
    #expect(sources.tabs("default").map(\.title) == ["Fallback"])
    store = Store(state: state("Resolved late"), checksInvariants: false)
    feed.reconcile(now: 20)
    #expect(feed.status.mode == "native-store" && feed.status.ready)
    #expect(feed.status.epoch > fallbackEpoch)
    #expect(sources.tabs("default").map(\.title) == ["Resolved late"])
    feed.stop()
  }

  @Test func ownershipLossRequiresFreshJSPublicationAndRejectsOldNativeDelivery() {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    var owned = true
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { owned }, resolve: { store })
    feed.reconcile()
    let nativeTicket = feed.generation
    let nativeEpoch = feed.status.epoch
    feed.setTabs([TabRow(id: "late", url: "", title: "Late JS", favicon: nil)], profileId: "default", epoch: nativeEpoch)
    #expect(sources.tabs("default").map(\.title) == ["Initial"])
    owned = false
    feed.reconcile()
    #expect(sources.tabs("default").isEmpty)
    #expect(sources.omniboxBenchSnapshot(profileId: "default")["sourceMode"] as? String == "js-feed")
    feed.setTabs([TabRow(id: "stale", url: "", title: "Stale JS", favicon: nil)], profileId: "default", epoch: nativeEpoch)
    feed.receive(state: state("Late native"), revision: 99, generation: nativeTicket)
    #expect(sources.tabs("default").isEmpty)
    feed.setTabs([TabRow(id: "fresh", url: "", title: "Fresh JS", favicon: nil)], profileId: "default", epoch: feed.status.epoch)
    #expect(sources.tabs("default").map(\.title) == ["Fresh JS"])
    owned = true
    feed.reconcile()
    #expect(sources.tabs("default").map(\.title) == ["Initial"])
    feed.stop()
  }

  @Test func delayedObserverInstallationReplaysTheCurrentFallbackEpoch() {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    var owned = true
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { owned }, resolve: { store })
    feed.reconcile()
    let missedNative = feed.status
    owned = false
    feed.reconcile()
    let fallback = feed.status
    var received: [OmniboxSourceStatus] = []
    feed.observeStatus { received.append($0) }
    #expect(missedNative.mode == "native-store" && missedNative.ready)
    #expect(fallback.mode == "js-feed" && !fallback.ready)
    #expect(received.last == fallback)
    #expect(fallback.epoch > missedNative.epoch)
    feed.stop()
  }

  @Test func resolverReplacementRejectsPreviousStoreGeneration() {
    let sources = NewTabSources()
    let first = Store(state: state("First"), checksInvariants: false)
    let second = Store(state: state("Second"), checksInvariants: false)
    var current = first
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { current })
    feed.reconcile()
    let ticket = feed.generation
    current = second
    feed.reconcile()
    feed.receive(state: state("Obsolete"), revision: 100, generation: ticket)
    #expect(sources.tabs("default").map(\.title) == ["Second"])
    feed.stop()
  }

  @Test func privateWindowCloseReleasesRowsAndCatalogState() {
    let profileId = "incognito:window@default"
    let sources = NewTabSources()
    let store = Store(state: state("Private", profileId: profileId), checksInvariants: false)
    let feed = OmniboxWorkspaceFeed(sources: sources, ownsWorkspace: { true }, resolve: { store })
    feed.reconcile()
    #expect(sources.tabs(profileId).count == 1)
    feed.receive(state: BrowserState(), revision: 1, generation: feed.generation)
    #expect(sources.tabs(profileId).isEmpty)
    #expect(sources.omniboxBenchSnapshot(profileId: profileId)["sourceMode"] as? String == "unpublished")
    feed.forget(windowId: "window")
    feed.stop()
  }

  @Test func stableReadyStoreStillPollsWithoutAnyCommits() async throws {
    let sources = NewTabSources()
    let store = Store(state: state(), checksInvariants: false)
    var resolutions = 0
    var wakeups = 0
    let feed = OmniboxWorkspaceFeed(
      sources: sources, ownsWorkspace: { true }, resolve: { resolutions += 1; return store },
      clock: { wakeups += 1; return ProcessInfo.processInfo.systemUptime })
    feed.start()
    defer { feed.stop() }
    let initial = resolutions
    let initialWakeups = wakeups
    let epoch = feed.status.epoch
    let revision = sources.revision
    try await Task.sleep(for: .milliseconds(1200))
    #expect(resolutions == initial)
    #expect(wakeups == initialWakeups)
    #expect(feed.status.epoch == epoch)
    #expect(sources.revision == revision)
    print("stable idle: resolutions=\(initial)->\(resolutions), reconciliations=\(initialWakeups)->\(wakeups)")
  }

  @Test func lifecycleNotifiesLateResolutionImmediatelyAfterDeadline() async throws {
    let previousResolver = NativeStoreHandle.resolve
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    NativeStoreHandle.resolve = nil
    NativeStoreHandle.ownsWorkspace = true
    let sources = NewTabSources()
    let feed = OmniboxWorkspaceFeed(
      sources: sources, ownsWorkspace: { NativeStoreHandle.ownsWorkspace }, resolve: { NativeStoreHandle.store })
    defer {
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
      NativeStoreHandle.ownsWorkspace = previousOwnership
    }
    feed.start()
    for _ in 0..<100 where feed.status.epoch == 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(feed.status.mode == "js-feed" && !feed.status.ready)
    #expect(feed.status.epoch == 1)
    let store = Store(state: state("Late lifecycle"), checksInvariants: false)
    NativeStoreHandle.resolve = { store }
    #expect(feed.status.mode == "native-store" && feed.status.ready)
    #expect(sources.tabs("default").map(\.title) == ["Late lifecycle"])
  }

  @Test func lifecycleNotifiesReplacementImmediatelyWithoutCommits() {
    let previousResolver = NativeStoreHandle.resolve
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    let first = Store(state: state("First lifecycle"), checksInvariants: false)
    let second = Store(state: state("Second lifecycle"), checksInvariants: false)
    NativeStoreHandle.resolve = { first }
    NativeStoreHandle.ownsWorkspace = true
    let sources = NewTabSources()
    let feed = OmniboxWorkspaceFeed(
      sources: sources, ownsWorkspace: { NativeStoreHandle.ownsWorkspace }, resolve: { NativeStoreHandle.store })
    defer {
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
      NativeStoreHandle.ownsWorkspace = previousOwnership
    }
    feed.start()
    #expect(sources.tabs("default").map(\.title) == ["First lifecycle"])
    let ticket = feed.generation
    NativeStoreHandle.resolve = { second }
    #expect(sources.tabs("default").map(\.title) == ["Second lifecycle"])
    feed.receive(state: state("Obsolete lifecycle"), revision: 100, generation: ticket)
    #expect(sources.tabs("default").map(\.title) == ["Second lifecycle"])
  }

  @Test func lifecycleNotifiesOwnershipLossImmediatelyWithoutCommits() {
    let previousResolver = NativeStoreHandle.resolve
    let previousOwnership = NativeStoreHandle.ownsWorkspace
    let store = Store(state: state("Owned lifecycle"), checksInvariants: false)
    NativeStoreHandle.resolve = { store }
    NativeStoreHandle.ownsWorkspace = true
    let sources = NewTabSources()
    let feed = OmniboxWorkspaceFeed(
      sources: sources, ownsWorkspace: { NativeStoreHandle.ownsWorkspace }, resolve: { NativeStoreHandle.store })
    defer {
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
      NativeStoreHandle.ownsWorkspace = previousOwnership
    }
    feed.start()
    let epoch = feed.status.epoch
    NativeStoreHandle.ownsWorkspace = false
    #expect(feed.status.mode == "js-feed" && !feed.status.ready)
    #expect(feed.status.epoch > epoch)
    #expect(sources.tabs("default").isEmpty)
    NativeStoreHandle.ownsWorkspace = true
    #expect(sources.tabs("default").map(\.title) == ["Owned lifecycle"])
  }

  @Test func stoppedDuringInitialReplayRemainsStopped() async throws {
    let previousResolver = NativeStoreHandle.resolve
    let store = Store(state: state(), checksInvariants: false)
    var resolutions = 0
    let feed = OmniboxWorkspaceFeed(
      sources: NewTabSources(), ownsWorkspace: { true }, resolve: { resolutions += 1; return store })
    feed.onStatus = { [weak feed] status in
      if status.ready { feed?.stop() }
    }
    defer {
      feed.onStatus = nil
      feed.stop()
      NativeStoreHandle.resolve = previousResolver
    }
    feed.start()
    let initial = resolutions
    NativeStoreHandle.resolve = { store }
    try await Task.sleep(for: .milliseconds(600))
    #expect(resolutions == initial)
  }
}
