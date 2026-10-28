import Foundation
import SolaraModel
import SolaraStore
import Testing

final class ReviewClock: @unchecked Sendable { var now: Double = 1_000 }

@Suite struct Step5ReviewTests {
  func pinnedWithChoice(_ clock: ReviewClock) throws -> (Store, String, Commits) {
    let store = syncingStore(launch: "rv", clock: { clock.now })
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    let window = store.state.windowOrder[0]
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("togglePin", [.string(tab)]))
    let t = store.state.tabs[tab]!
    try store.dispatch(Command("applyState", [["pinChoices": [t.profileId: [(t.pinKey ?? t.id): 5]]]]))
    #expect(store.state.pinChoices[t.profileId]?[t.pinKey ?? t.id] != nil, "control: the choice is live")
    let seen = Commits()
    store.subscribe { seen.add($0) }
    return (store, tab, seen)
  }

  @Test func syncWorkspaceCommandDuringUserTransactionIsNotQueuedAndItsDerivedPruneIsUntagged() throws {
    let clock = ReviewClock()
    let (store, tab, seen) = try pinnedWithChoice(clock)
    try store.dispatch(Command("beginTransaction"), origin: .native)
    #expect(throws: StoreBusy.self, "rule 2: a sync apply during a user transaction doesn't join it") {
      try store.dispatch([Command("togglePin", [.string(tab)])], origin: .bridge, fromSync: true)
    }
    try store.dispatch(Command("endTransaction"), origin: .native)
    try store.dispatch([Command("togglePin", [.string(tab)])], origin: .bridge, fromSync: true)
    let touching = seen.all.filter { $0.patch.json["pinChoices"] != nil }
    #expect(!touching.isEmpty, "control: the prune ran")
    #expect(touching.allSatisfy { $0.patch.json["sync"] == true }, "rule 1: the prune derived from sync's unpin is sync's")
  }

  @Test func staleUserTransactionClosedBySyncCommandHandsTheUsersDerivedChangeToSync() throws {
    let clock = ReviewClock()
    let (store, tab, seen) = try pinnedWithChoice(clock)
    let profile = store.state.tabs[tab]!.profileId
    try store.dispatch(Command("beginTransaction"), origin: .native)
    try store.dispatch(Command("togglePin", [.string(tab)]), origin: .native)
    clock.now += Store.heldTransactionLimit + 1
    try store.dispatch([Command("updateProfile", [.string(profile), ["name": "From Sync"]])], origin: .bridge, fromSync: true)
    let touching = seen.all.filter { $0.patch.json["pinChoices"] != nil }
    #expect(!touching.isEmpty, "control: the prune ran")
    #expect(touching.allSatisfy { $0.patch.json["sync"] == nil }, "rule a: the prune derived from the user's unpin stays the user's")
  }
}

@Suite struct Step5ReviewQueueTests {
  func pinnedArea(_ launch: String) throws -> (Store, group: String, first: String) {
    let store = syncingStore(launch: launch, clock: { 1_793_016_000_000 })
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    let w = store.state.windowOrder[0]
    for u in ["b", "c", "m"] { try store.dispatch(Command("newTab", [.string(w), ["url": .string("https://\(u).example/"), "background": true]])) }
    let ids = store.state.windows[w]!.tabIds
    try store.dispatch(Command("placeTabs", [JSONValue(Array(ids.prefix(3))), ["pinned": true, "row": true, "beforeId": .null]]))
    let g = try #require(try store.dispatch(Command("groupTabs", [JSONValue([ids[3]]), ["pinned": true, "name": "G"]])).result?.string)
    return (store, g, ids[0])
  }

  func syncedReorder() throws -> JSONValue {
    let (other, g, first) = try pinnedArea("rv3")
    try other.dispatch(Command("moveGroup", [.string(g), ["pinned": true, "beforeId": .string(first)]]))
    let s = other.state.stateJSON
    return ["windows": s["windows"] ?? .null, "tabs": s["tabs"] ?? .null, "groups": s["groups"] ?? .null]
  }

  func orderChoices(_ store: Store) -> [String] {
    store.state.pinChoices.values.flatMap { $0.keys.filter { $0.hasPrefix("order:") } }
  }

  func jsShapedSyncApply(_ store: Store, _ slices: JSONValue) throws {
    try store.dispatch(Command("beginFromSync"), origin: .bridge)
    try store.dispatch([Command("applyState", [slices])], origin: .bridge, fromSync: true)
    try store.dispatch(Command("endFromSync"), origin: .bridge)
  }

  @Test func controlASyncReorderOutsideATransactionRecordsNoOrderChoice() throws {
    let slices = try syncedReorder()
    let (store, _, _) = try pinnedArea("rv3")
    let before = orderChoices(store)
    try jsShapedSyncApply(store, slices)
    #expect(store.state.stateJSON["windows"] == slices["windows"], "control: the reorder applied")
    #expect(orderChoices(store) == before)
  }

  @Test func aQueuedSyncReorderReplaysOutsideItsFromSyncWindowAndIsRecordedAsALocalChoice() throws {
    let slices = try syncedReorder()
    let (store, _, _) = try pinnedArea("rv3")
    let before = orderChoices(store)
    try store.dispatch(Command("beginTransaction"), origin: .native)
    #expect(throws: StoreBusy.self, "control: JS's call shape is busy during the user's transaction") { try jsShapedSyncApply(store, slices) }
    try store.dispatch(Command("endFromSync"), origin: .bridge)
    try store.dispatch(Command("endTransaction"), origin: .native)
    try jsShapedSyncApply(store, slices)
    #expect(store.state.stateJSON["windows"] == slices["windows"], "control: the reorder applied after the transaction")
    #expect(orderChoices(store) == before, "sync's reorder must not become a local order choice")
  }

  @Test func aSyncUpdateProfileRunsAfterTheQueuedApplyStateThatCreatesTheProfile() throws {
    let store = syncingStore()
    let profiles: JSONValue = [
      "profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0], "work": ["id": "work", "name": "Work", "color": "blue", "icon": .null, "createdAt": 1]],
      "profileOrder": ["default", "work"],
    ]
    try store.dispatch(Command("beginTransaction"), origin: .native)
    #expect(throws: StoreBusy.self) { try store.dispatch([Command("applyState", [profiles, ["fromSync": true]])], origin: .bridge, fromSync: true) }
    #expect(throws: StoreBusy.self) { try store.dispatch([Command("updateProfile", ["work", ["name": "Renamed"]])], origin: .bridge, fromSync: true) }
    try store.dispatch(Command("endTransaction"), origin: .native)
    try store.dispatch([Command("applyState", [profiles, ["fromSync": true]])], origin: .bridge, fromSync: true)
    try store.dispatch([Command("updateProfile", ["work", ["name": "Renamed"]])], origin: .bridge, fromSync: true)
    #expect(store.state.profiles["work"] != nil, "control: the retried apply ran")
    #expect(store.state.profiles["work"]?.name == "Renamed", "sync's later command lands after its earlier one")
  }
}
