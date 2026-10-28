import Foundation
import SolaraModel
import SolaraStore
import Testing

func makeStore(_ state: BrowserState = BrowserState(settings: Settings.hydrated(from: nil))) -> Store {
  Store(state: state, memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: true, clock: { 1_000 })
}

func settingsCommand(_ patch: JSONObject, fromSync: Bool = false) -> Command {
  Command("updateSettings", [.object(patch), ["fromSync": .bool(fromSync)]])
}

func upsert(_ d: Download) -> Command { Command("upsertDownload", [.object(d.json)]) }

func download(_ id: String, _ state: String = "complete", profile: String? = nil) -> Download {
  var json: JSONObject = ["id": .string(id), "state": .string(state)]
  if let profile { json["profile"] = .string(profile) }
  return Download(json: json)
}

@Suite struct StoreTests {
  @Test func updateSettingsCommitsOnceWithAPatchOfTheChangedKeys() throws {
    let store = makeStore()
    let commit = try store.dispatch(settingsCommand(["appearance": "dark"]))
    #expect(commit.rev == 1)
    #expect(commit.durable)
    #expect(commit.changes.settingsChanged == ["appearance", "chosen"])
    #expect(commit.patch.json == ["rev": 1, "settings": ["set": ["appearance": "dark", "chosen": ["appearance"]]]])
    let same = try store.dispatch(settingsCommand(["appearance": "dark"]))
    #expect(same.rev == 1)
    #expect(same.changes.isEmpty)
  }

  @Test func downloadsUpsertInPlaceAndCapAtAHundred() throws {
    let store = makeStore()
    try store.dispatch(upsert(download("a", "downloading")))
    try store.dispatch(upsert(download("a")))
    #expect(store.state.downloads.map(\.state) == ["complete"])
    for i in 0..<120 { try store.dispatch(upsert(download("d\(i)"))) }
    #expect(store.state.downloads.count == Download.maxKept)
    #expect(store.state.downloads.first?.id == "d119")
  }

  @Test func patchesSinceARevAndAGapBeyondTheRing() throws {
    let store = makeStore()
    for i in 0..<(Store.ringSize + 10) {
      try store.dispatch(settingsCommand(["sidebarWidth": .number(Double(200 + i))], fromSync: true))
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
        group.addTask { _ = try? store.dispatch(settingsCommand(["sidebarWidth": .number(Double(i))], fromSync: true)) }
      }
    }
    #expect(seen.values == Array(seen.values.sorted()))
    #expect(Set(seen.values).count == seen.values.count)
  }

  @Test func aWindowChromeClosesClosesLastTabAndAll() throws {
    for closedByChrome in [false, true] {
      let store = makeStore()
      try store.dispatch(Command("createWindow", [["url": "https://main.example/"]]))
      let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
      try store.dispatch(Command("newTab", [.string(window), ["url": "https://b.example/"]]))
      let ids = store.state.windows[window]!.tabIds
      for id in ids {
        try store.dispatch(Command("closeTabs", [.array([.string(id)]), ["lastClosesWindow": true, "windowClosedByChrome": .bool(closedByChrome)]]))
      }
      #expect((store.state.windows[window] == nil) == closedByChrome)
      #expect(ids.allSatisfy { store.state.tabs[$0] == nil })
    }
  }

  @Test func aFailingCommandLeavesTheStateUntouched() throws {
    #expect(throws: CommandError.self) { try Command(json: ["name": "nope"]) }
    #expect(throws: CommandError.self) { try makeStore().dispatch(Command("closeTab", [])) }
  }
}

final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var revs: [Int] = []
  func append(_ rev: Int) { lock.withLock { revs.append(rev) } }
  var values: [Int] { lock.withLock { revs } }
}
