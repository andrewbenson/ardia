import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Testing

@Suite struct SyncPinsFrozenMembersTests {
  func seeded(_ redesign: Bool) throws -> StoreBridge {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 1)
    window.tabIds = ["home", "u", "m"]
    window.activeTabIds["default"] = "home"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusOrder = ["w"]
    for id in window.tabIds {
      var tab = Tab(id: id, windowId: "w", profileId: "default", url: "https://\(id).example/", now: 1)
      if id != "home" {
        tab.pinned = id == "u"
        tab.pinnedUrl = tab.url
        tab.unloaded = true
      }
      state.tabs[id] = tab
    }
    state.groups["g"] = TabGroup(id: "g", windowId: "w", profileId: "default", name: "G", icon: nil, color: nil, collapsed: false, pinned: true, tabIds: ["m"], createdAt: 1)
    var config = StoreConfig()
    config.syncOrigins = redesign
    let bridge = StoreBridge(store: Store(state: state, memory: StoreMemory(ids: IdSource(launch: "frozen")), config: config, checksInvariants: true, clock: { 1_000 }))
    let work = try bridge.store.dispatch(Command("createProfile", [["name": "Work"]])).result!.string!
    _ = try bridge.store.dispatch(Command("createWindow", [["profileId": .string(work), "url": "https://other.example/"]]))
    return bridge
  }

  func pin(_ id: String, group: JSONValue = .null, title: JSONValue = .null, pos: String) -> JSONValue {
    ["g": group, "u": .string("https://\(id).example/"), "t": title, "i": .null, "ti": "", "pos": .string(pos)]
  }

  func frozen(visible: [JSONValue], changed: [String]) -> JSONValue {
    ["kind": "pins", "visible": .array(visible), "changed": .array(changed.map(JSONValue.string)), "base": [:], "known": ["pin:g:g"], "now": 1_000, "horizon": 10_000]
  }

  var renamedTile: JSONValue {
    frozen(
      visible: [
        ["pin:t:u", pin("u", title: "Renamed", pos: "a")],
        ["pin:g:g", ["n": "G", "i": .null, "c": .null, "pos": "b"]],
        ["pin:t:m", pin("m", group: "g", pos: "c")],
      ],
      changed: ["pin:t:u"])
  }

  func apply(_ bridge: StoreBridge, _ body: JSONValue) -> JSONValue {
    let envelope: JSONValue = ["fromSync": true, "commands": [Command("syncPinsApply", ["default", body]).json]]
    return bridge.dispatch(json: envelope.text(), sinceRev: bridge.store.rev)
  }

  func addMember(_ bridge: StoreBridge) throws -> String {
    let n = try bridge.store.dispatch(Command("newTab", ["w", ["url": "https://n.example/", "background": true]])).result!.string!
    try bridge.store.dispatch(Command("addTabsToGroup", ["g", [.string(n)]]))
    return n
  }

  @Test(arguments: [false, true]) func aMemberAddedAfterTheViewFrozeIsParkedWithItsGroup(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    _ = try addMember(bridge)
    try bridge.store.dispatch(Command("closeWindow", ["w"]))
    let content = apply(bridge, renamedTile)
    #expect(content["error"] == nil)
    let parked = try #require(bridge.store.state.parkedPins["default"])
    #expect(parked.tabs.filter { $0.groupId == "g" }.map(\.snapshot.url).sorted() == ["https://m.example/", "https://n.example/"])
    #expect(parked.tabs.first { $0.id == "u" }?.snapshot.customTitle == "Renamed")
  }

  @Test(arguments: [false, true]) func aMemberAddedAfterTheViewFrozeKeepsItsGroup(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    let n = try addMember(bridge)
    let content = apply(bridge, renamedTile)
    #expect(content["error"] == nil)
    #expect(bridge.store.state.groups["g"]?.tabIds == ["m", n])
    #expect(bridge.store.state.tabs["u"]?.customTitle == "Renamed")
  }

  var groupDeleted: JSONValue {
    frozen(visible: [["pin:t:u", pin("u", pos: "a")]], changed: ["pin:g:g", "pin:t:m"])
  }

  @Test(arguments: [false, true]) func aGroupDeletedElsewhereLeavesAMemberAddedAfterTheViewFrozeAsATile(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    let n = try addMember(bridge)
    let content = apply(bridge, groupDeleted)
    #expect(content["error"] == nil)
    #expect(bridge.store.state.groups["g"] == nil)
    #expect(bridge.store.state.tabs[n]?.pinned == true)
    #expect(bridge.store.state.tabs[n]?.pinnedUrl == "https://n.example/")
  }

  @Test(arguments: [false, true]) func aGroupDeletedElsewhereParksAMemberAddedAfterTheViewFrozeAsATile(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    _ = try addMember(bridge)
    try bridge.store.dispatch(Command("closeWindow", ["w"]))
    let content = apply(bridge, groupDeleted)
    #expect(content["error"] == nil)
    let parked = try #require(bridge.store.state.parkedPins["default"])
    let tile = parked.tabs.first { $0.snapshot.url == "https://n.example/" }
    #expect(tile?.snapshot.pinned == true)
    #expect(tile?.groupId == nil)
    #expect(!parked.groups.contains { $0.id == "g" })
  }

  @Test(arguments: [false, true]) func aMemberUnpinnedElsewhereStillLeavesWhileALocalMemberJoins(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    let k = try addMember(bridge)
    let n = try bridge.store.dispatch(Command("newTab", ["w", ["url": "https://late.example/", "background": true]])).result!.string!
    try bridge.store.dispatch(Command("addTabsToGroup", ["g", [.string(n)]]))
    let view = frozen(
      visible: [
        ["pin:t:u", pin("u", pos: "a")],
        ["pin:g:g", ["n": "G", "i": .null, "c": .null, "pos": "b"]],
        [.string("pin:t:\(k)"), pin(k, group: "g", pos: "c")],
      ],
      changed: ["pin:t:m"])
    let content = apply(bridge, view)
    #expect(content["error"] == nil)
    #expect(bridge.store.state.groups["g"]?.tabIds == [k, n])
  }

  @Test(arguments: [false, true]) func aMemberMovedElsewhereLandsInItsNewGroupWhileALocalMemberJoinsTheOld(_ redesign: Bool) throws {
    let bridge = try seeded(redesign)
    let k = try addMember(bridge)
    let n = try bridge.store.dispatch(Command("newTab", ["w", ["url": "https://late.example/", "background": true]])).result!.string!
    try bridge.store.dispatch(Command("addTabsToGroup", ["g", [.string(n)]]))
    let view = frozen(
      visible: [
        ["pin:t:u", pin("u", pos: "a")],
        ["pin:g:g", ["n": "G", "i": .null, "c": .null, "pos": "b"]],
        ["pin:g:h", ["n": "H", "i": .null, "c": .null, "pos": "c"]],
        ["pin:t:m", pin("m", group: "h", pos: "d")],
        [.string("pin:t:\(k)"), pin(k, group: "g", pos: "e")],
      ],
      changed: ["pin:t:m", "pin:g:h"])
    let content = apply(bridge, view)
    #expect(content["error"] == nil)
    #expect(bridge.store.state.groups["h"]?.tabIds == ["m"])
    #expect(bridge.store.state.groups["g"]?.tabIds == [k, n])
  }
}
