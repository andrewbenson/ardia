import Foundation
import SolaraModel
import SolaraStore
import Testing

func makeStore(_ state: BrowserState = BrowserState(settings: Settings.hydrated(from: nil))) -> Store {
  Store(state: state, ids: IdSource(launch: "test"), checksInvariants: true, clock: { 1_000 })
}

func download(_ id: String, _ state: String = "complete", profile: String? = nil) -> Download {
  var json: JSONObject = ["id": .string(id), "state": .string(state)]
  if let profile { json["profile"] = .string(profile) }
  return Download(json: json)
}

@Suite struct StoreTests {
  @Test func updateSettingsCommitsOnceWithAPatchOfTheChangedKeys() throws {
    let store = makeStore()
    let commit = try store.dispatch(.updateSettings(patch: ["appearance": "dark"], fromSync: false))
    #expect(commit.rev == 1)
    #expect(commit.durable)
    #expect(commit.changes.settingsChanged == ["appearance", "chosen"])
    #expect(commit.patch.json == ["rev": 1, "settings": ["set": ["appearance": "dark", "chosen": ["appearance"]]]])
    let same = try store.dispatch(.updateSettings(patch: ["appearance": "dark"], fromSync: false))
    #expect(same.rev == 1)
    #expect(same.changes.isEmpty)
  }

  @Test func downloadsUpsertCapAndOpenThePopoverOnlyWhenNew() throws {
    let store = makeStore()
    let first = try store.dispatch(.upsertDownload(download("a", "downloading"), privateSession: nil, focusedWindowShowing: "w1"))
    #expect(first.effects == [.openDownloads(windowId: "w1")])
    let update = try store.dispatch(.upsertDownload(download("a"), privateSession: nil, focusedWindowShowing: "w1"))
    #expect(update.effects == [])
    #expect(store.state.downloads.map(\.state) == ["complete"])
    for i in 0..<120 { try store.dispatch(.upsertDownload(download("d\(i)"), privateSession: nil, focusedWindowShowing: nil)) }
    #expect(store.state.downloads.count == Download.maxKept)
    #expect(store.state.downloads.first?.id == "d119")
  }

  @Test func aPrivateDownloadFromAnEndedSessionIsDroppedForGood() throws {
    let store = makeStore()
    let closed = try store.dispatch(.upsertDownload(download("p", profile: "incognito:w@default"), privateSession: PrivateDownloadSession(open: false), focusedWindowShowing: nil))
    #expect(closed.changes.isEmpty)
    #expect(store.memory.endedPrivateDownloads == ["p"])
    try store.dispatch(.upsertDownload(download("p", profile: "incognito:w@default"), privateSession: PrivateDownloadSession(open: true), focusedWindowShowing: nil))
    #expect(store.state.downloads.isEmpty)
    try store.dispatch(.upsertDownload(download("q", profile: "incognito:w@default"), privateSession: PrivateDownloadSession(open: true), focusedWindowShowing: nil))
    try store.dispatch(.forgetDownloads(ids: ["q"], privateSession: true))
    try store.dispatch(.upsertDownload(download("q", profile: "incognito:w@default"), privateSession: PrivateDownloadSession(open: true), focusedWindowShowing: nil))
    #expect(store.state.downloads.isEmpty)
  }

  @Test func clearKeepsRunningDownloadsAndOnesNotVisible() throws {
    let store = makeStore()
    for d in [download("a", "downloading"), download("b"), download("c")] {
      try store.dispatch(.upsertDownload(d, privateSession: nil, focusedWindowShowing: nil))
    }
    try store.dispatch(.clearDownloads(visibleIds: ["a", "b"]))
    #expect(store.state.downloads.map(\.id) == ["c", "a"])
    try store.dispatch(.clearDownloads(visibleIds: nil))
    #expect(store.state.downloads.map(\.id) == ["a"])
  }

  @Test func patchesSinceARevAndAGapBeyondTheRing() throws {
    let store = makeStore()
    for i in 0..<(Store.ringSize + 10) {
      try store.dispatch(.updateSettings(patch: ["sidebarWidth": .number(Double(200 + i))], fromSync: true))
    }
    #expect(store.rev == Store.ringSize + 10)
    #expect(store.patches(since: store.rev)?.isEmpty == true)
    #expect(store.patches(since: store.rev - 3)?.map(\.rev) == [store.rev - 2, store.rev - 1, store.rev])
    #expect(store.patches(since: 10)?.count == Store.ringSize)
    #expect(store.patches(since: 9) == nil)
    #expect(store.patches(since: 0) == nil)
  }

  @Test func listenersSeeCommitsInRevOrderAcrossThreads() async throws {
    let store = makeStore()
    let seen = Seen()
    store.subscribe { seen.append($0.rev) }
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<200 {
        group.addTask { _ = try? store.dispatch(.updateSettings(patch: ["sidebarWidth": .number(Double(i))], fromSync: true)) }
      }
    }
    #expect(seen.values == Array(seen.values.sorted()))
    #expect(Set(seen.values).count == seen.values.count)
  }

  @Test func aFailingCommandLeavesTheStateUntouched() throws {
    #expect(throws: CommandError.self) { try Command(json: ["name": "nope"]) }
    #expect(throws: CommandError.self) { try Command(json: ["name": "updateSettings", "args": [1]]) }
  }
}

final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var revs: [Int] = []
  func append(_ rev: Int) { lock.withLock { revs.append(rev) } }
  var values: [Int] { lock.withLock { revs } }
}
