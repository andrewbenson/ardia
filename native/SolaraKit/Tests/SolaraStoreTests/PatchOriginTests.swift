import Foundation
import SolaraModel
import SolaraStore
import Testing

func syncingStore(launch: String = "test", clock: @escaping @Sendable () -> Double = { 1_000 }) -> Store {
  var config = StoreConfig()
  config.syncOrigins = true
  return Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: launch)), config: config, checksInvariants: true, clock: clock)
}

@Suite struct PatchOriginTests {
  @Test func aCommitMadeThroughTheBridgeIsTaggedAndANativeOneIsNot() throws {
    let store = syncingStore()
    let fromJS = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge)
    #expect(fromJS.patch.json["bridge"] == true)
    let fromUI = try store.dispatch(settingsCommand(["searchEngine": "bing"]))
    #expect(fromUI.patch.json["bridge"] == nil)
    let history = try #require(store.patches(since: 0))
    #expect(history.map { $0.json["bridge"] == true } == [true, false], "the ring keeps each patch's origin for a later catch-up")
  }

  @Test func aNativeCommandInsideAFromSyncWindowIsStillUntagged() throws {
    let store = syncingStore()
    _ = try store.dispatch([Command("beginFromSync", [])], origin: .bridge)
    let fromUI = try store.dispatch(settingsCommand(["searchEngine": "bing"]))
    _ = try store.dispatch([Command("endFromSync", [])], origin: .bridge)
    #expect(fromUI.patch.json["bridge"] == nil, "tagged by origin, not by the open window")
  }

  @Test func aSyncCommitIsTaggedWhetherItCameThroughTheBridgeOrFromSwift() throws {
    let store = syncingStore()
    let fromJS = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    #expect(fromJS.patch.json["sync"] == true)
    #expect(fromJS.patch.json["bridge"] == true)
    let fromSwift = try store.dispatch(settingsCommand(["appearance": "light"], fromSync: true), origin: .sync)
    #expect(fromSwift.patch.json["sync"] == true)
    let fromUI = try store.dispatch(settingsCommand(["searchEngine": "bing"]))
    #expect(fromUI.patch.json["sync"] == nil)
  }

  @Test func aSyncApplyDuringAUserTransactionIsBusyAndCommitsOnItsOwnWhenRetriedAfterIt() throws {
    let store = syncingStore()
    let seen = Commits()
    store.subscribe { seen.add($0) }
    try store.dispatch(Command("beginTransaction"), origin: .bridge)
    #expect(throws: StoreBusy.self, "the sync apply doesn't join the user's transaction") {
      try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    }
    #expect(store.queuedFromSyncCount == 0, "nothing precomputed is kept to replay later")
    #expect(store.state.settings["appearance"] != "dark")
    let edit = try store.dispatch(settingsCommand(["searchEngine": "bing"]), origin: .bridge)
    #expect(edit.patch.json["sync"] == nil, "the user's edit stays untagged")
    let end = try store.dispatch(Command("endTransaction"), origin: .bridge)
    let sync = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    #expect(sync.patch.json["sync"] == true)
    #expect(sync.rev > end.rev)
    #expect(sync.patch.json["settings"]?["set"]?["searchEngine"] == nil, "the sync commit carries only sync's change")
  }

  @Test func aDerivedPinTableChangeFromASyncApplyLandsInTheSyncCommitNotTheUsers() throws {
    let store = syncingStore()
    let seen = Commits()
    store.subscribe { seen.add($0) }
    let stale: JSONValue = [
      "pinChoices": ["default": ["gone-pin": 5]],
      "profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0], "work": ["id": "work", "name": "Work", "color": "blue", "icon": .null, "createdAt": 1]],
      "profileOrder": ["default", "work"],
    ]
    let apply = {
      try store.dispatch(Command("beginFromSync"), origin: .bridge, fromSync: true)
      try store.dispatch(Command("applyState", [stale, ["fromSync": true]]), origin: .bridge, fromSync: true)
      try store.dispatch(Command("endFromSync"), origin: .bridge, fromSync: true)
    }
    try store.dispatch(Command("beginTransaction"), origin: .bridge)
    #expect(throws: StoreBusy.self, "JS's beginFromSync is busy, so it sends neither the apply nor the end") { try apply() }
    try store.dispatch(settingsCommand(["searchEngine": "bing"]), origin: .bridge)
    try store.dispatch(Command("endTransaction"), origin: .bridge)
    try apply()
    let touching = seen.all.filter { $0.patch.json["pinChoices"] != nil }
    #expect(store.state.profiles["work"] != nil, "control: the retried sync apply ran")
    #expect(touching.allSatisfy { $0.patch.json["sync"] == true }, "every commit that touched the pin table is sync's")
    #expect(store.state.pinChoices["default"]?["gone-pin"] == nil, "the derived prune still ran")
  }

  @Test func endFromSyncIsNeverBusySoAWindowOpenedBeforeAUserTransactionStillCloses() throws {
    let store = syncingStore()
    try store.dispatch(Command("beginFromSync"), origin: .bridge, fromSync: true)
    try store.dispatch(Command("beginTransaction"), origin: .native)
    try store.dispatch(Command("endFromSync"), origin: .bridge, fromSync: true)
    try store.dispatch(Command("endTransaction"), origin: .native)
    #expect(store.memory.fromSyncDepth == 0)
  }

  @Test func aSyncApplyThatOpensItsOwnTransactionJoinsItInsteadOfWaitingBehindItself() throws {
    let store = syncingStore()
    try store.dispatch(Command("beginTransaction"), origin: .bridge, fromSync: true)
    let inside = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    #expect(!inside.changes.isEmpty)
    #expect(store.queuedFromSyncCount == 0)
    try store.dispatch(Command("endTransaction"), origin: .bridge, fromSync: true)
  }

  @Test func aUserTransactionLeftOpenPastItsLimitClosesAsTheUsersBeforeASyncApplyRuns() throws {
    final class Clock: @unchecked Sendable { var now: Double = 1_000 }
    let clock = Clock()
    let store = syncingStore(clock: { clock.now })
    try store.dispatch(Command("beginTransaction"), origin: .bridge)
    clock.now += Store.heldTransactionLimit + 1
    let sync = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    #expect(!sync.changes.isEmpty, "nothing to wait behind once the stale transaction is closed")
    #expect(store.queuedFromSyncCount == 0)
  }
  @Test func everySyncCommandIsBusyDuringAUserTransactionWhileSyncSessionsWaitInOrder() throws {
    let store = syncingStore()
    let seen = Commits()
    store.subscribe { seen.add($0) }
    let window = try store.dispatch(Command("createWindow", [["url": "https://a.example/"]])).result!.string!
    try store.dispatch(Command("beginTransaction"), origin: .bridge)
    #expect(throws: StoreBusy.self, "a workspace command is busy") {
      try store.dispatch(Command("newTab", [.string(window), ["url": "https://sync.example/"]]), origin: .bridge, fromSync: true)
    }
    #expect(throws: StoreBusy.self, "a command whose result the caller reads is busy, never queued without its result") {
      try store.dispatch(Command("createProfile", [["name": "Synced"]]), origin: .bridge, fromSync: true)
    }
    #expect(throws: StoreBusy.self) { try store.dispatch(Command("nextId", ["tab"]), origin: .sync) }
    #expect(throws: StoreBusy.self, "a sync session that needs its result now can't join the user's") {
      try store.transact(origin: .sync) { _ in }
    }
    try store.transactWhenFree { $0.updateSettings(["appearance": "dark"], fromSync: true) }
    try store.transactWhenFree { $0.updateSettings(["searchEngine": "bing"], fromSync: true) }
    #expect(store.queuedFromSyncCount == 2, "sessions that compute at replay wait")
    #expect(throws: StoreBusy.self, "a command behind them is busy too, so nothing jumps the queue") {
      try store.dispatch(settingsCommand(["appearance": "light"], fromSync: true), origin: .bridge, fromSync: true)
    }
    try store.dispatch(Command("endTransaction"), origin: .bridge)
    let replayed = seen.all.filter { $0.origin == .sync }
    #expect(replayed.count == 2)
    #expect(replayed.first?.patch.json["settings"]?["set"]?["appearance"] == "dark", "first in, first out")
    #expect(replayed.map(\.rev) == replayed.map(\.rev).sorted())
    #expect(store.queuedFromSyncCount == 0)
  }

  @Test func withTheSwitchOffSyncCallsJoinAUserTransactionAsBeforeAndNothingIsTagged() throws {
    let store = makeStore()
    try store.dispatch(Command("beginTransaction"), origin: .bridge)
    let joined = try store.dispatch([settingsCommand(["appearance": "dark"], fromSync: true)], origin: .bridge, fromSync: true)
    #expect(!joined.changes.isEmpty)
    #expect(joined.patch.json["sync"] == nil && joined.patch.json["bridge"] == nil)
    let fromSwift = try store.dispatch(settingsCommand(["appearance": "light"], fromSync: true), origin: .sync)
    #expect(fromSwift.patch.json["sync"] == nil)
    try store.transact(origin: .sync) { _ in }
    try store.dispatch(Command("endTransaction"), origin: .bridge)
    #expect(store.queuedFromSyncCount == 0)
  }

  @Test func aStaleSyncTransactionClosedByAUserCommandKeepsSyncsDerivedChangeSyncs() throws {
    final class Clock: @unchecked Sendable { var now: Double = 1_000 }
    let clock = Clock()
    let store = syncingStore(launch: "stale", clock: { clock.now })
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    let tab = store.state.windows[store.state.windowOrder[0]]!.tabIds[0]
    try store.dispatch(Command("togglePin", [.string(tab)]))
    let t = store.state.tabs[tab]!
    try store.dispatch(Command("applyState", [["pinChoices": [t.profileId: [(t.pinKey ?? t.id): 5]]]]))
    let seen = Commits()
    store.subscribe { seen.add($0) }
    try store.dispatch(Command("beginTransaction"), origin: .bridge, fromSync: true)
    try store.dispatch(Command("togglePin", [.string(tab)]), origin: .bridge, fromSync: true)
    clock.now += Store.heldTransactionLimit + 1
    try store.dispatch(settingsCommand(["searchEngine": "bing"]), origin: .native)
    let touching = seen.all.filter { $0.patch.json["pinChoices"] != nil }
    #expect(!touching.isEmpty, "control: the prune ran")
    #expect(touching.allSatisfy { $0.patch.json["sync"] == true }, "the prune derived from sync's unpin stays sync's")
  }
}

final class Commits: @unchecked Sendable {
  private let lock = NSLock()
  private var commits: [Commit] = []
  func add(_ commit: Commit) { lock.withLock { commits.append(commit) } }
  var all: [Commit] { lock.withLock { commits } }
}
