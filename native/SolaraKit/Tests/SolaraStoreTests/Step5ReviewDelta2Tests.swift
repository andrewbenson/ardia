import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct Step5ReviewDelta2Tests {
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

  @Test func aQueuedWholeSliceApplyQueuedBeforeALaterUserEditInTheSameTransactionDoesNotUndoTheUsersEdit() throws {
    let (other, g, first) = try pinnedArea("d2")
    try other.dispatch(Command("moveGroup", [.string(g), ["pinned": true, "beforeId": .string(first)]]))
    let o = other.state.stateJSON
    let slices: JSONValue = ["windows": o["windows"] ?? .null, "tabs": o["tabs"] ?? .null, "groups": o["groups"] ?? .null]
    let (store, _, _) = try pinnedArea("d2")
    let w = store.state.windowOrder[0]
    try store.dispatch(Command("beginTransaction"), origin: .native)
    #expect(throws: StoreBusy.self, "control: the sync write doesn't join the user's transaction") {
      try store.dispatch(Command("beginFromSync"), origin: .bridge, fromSync: true)
      try store.dispatch([Command("applyState", [slices])], origin: .bridge, fromSync: true)
      try store.dispatch(Command("endFromSync"), origin: .bridge, fromSync: true)
    }
    #expect(store.queuedFromSyncCount == 0, "control: none of its precomputed slices wait to replay")
    try store.dispatch(Command("newTab", [.string(w), ["url": "https://user.example/", "background": true]]), origin: .native)
    let userTab = try #require(store.state.windows[w]!.tabIds.first { store.state.tabs[$0]?.url == "https://user.example/" })
    try store.dispatch(Command("endTransaction"), origin: .native)
    #expect(store.state.tabs[userTab] != nil, "the tab the user opened during the transaction survives sync's queued write")
    #expect(store.state.windows[w]?.tabIds.contains(userTab) == true, "and stays in its window")
  }
}
