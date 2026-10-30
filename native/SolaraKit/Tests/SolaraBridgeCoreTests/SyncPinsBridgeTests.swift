import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct SyncPinsBridgeTests {
  func seeded(_ redesign: Bool, clock: @escaping @Sendable () -> Double = { 1_000 }) -> StoreBridge {
    var state = BrowserState(settings: Settings.hydrated(from: nil))
    var window = BrowserWindow(id: "w", profileId: "default", incognito: false, frame: nil, createdAt: 1)
    window.tabIds = ["t", "u", "m"]
    window.activeTabIds["default"] = "m"
    state.windows["w"] = window
    state.windowOrder = ["w"]
    state.ui.focusOrder = ["w"]
    for id in window.tabIds {
      var tab = Tab(id: id, windowId: "w", profileId: "default", url: "https://\(id).example/", now: 1)
      tab.pinned = id != "m"
      tab.pinnedUrl = tab.url
      tab.unloaded = true
      state.tabs[id] = tab
    }
    state.groups["g"] = TabGroup(id: "g", windowId: "w", profileId: "default", name: "G", icon: nil, color: nil, collapsed: false, pinned: true, tabIds: ["m"], createdAt: 1)
    state.pinChoices["default"] = JSMap([("place:t", 10), ("place:u", 11)])
    var config = StoreConfig()
    config.syncOrigins = redesign
    return StoreBridge(store: Store(state: state, memory: StoreMemory(ids: IdSource(launch: "pins")), config: config, checksInvariants: true, clock: clock))
  }

  func payload(_ kind: String, _ visible: JSONValue = [], _ changed: JSONValue = [], base: JSONValue = [:], known: JSONValue = []) -> JSONValue {
    ["kind": .string(kind), "visible": visible, "changed": changed, "base": base, "known": known, "now": 1_000, "horizon": 10_000]
  }

  func apply(_ bridge: StoreBridge, _ body: JSONValue, profile: String = "default") -> JSONValue {
    let envelope: JSONValue = ["fromSync": true, "commands": [Command("syncPinsApply", [.string(profile), body]).json]]
    return bridge.dispatch(json: envelope.text(), sinceRev: bridge.store.rev)
  }

  @Test(arguments: [false, true]) func eachKindChangesStateThroughTheRealDecoder(_ redesign: Bool) throws {
    let pins = seeded(redesign)
    let pin: JSONValue = ["g": .null, "u": "https://t.example/remote", "t": "Remote", "i": .null, "ti": "Remote", "pos": "a"]
    let content = apply(pins, payload("pins", [["pin:t:t", pin]], ["pin:t:t"]))
    #expect(content["error"] == nil)
    #expect(content["result"] == true)
    #expect(pins.store.state.tabs["t"]?.customTitle == "Remote")

    let rows = seeded(redesign)
    let row = apply(rows, payload("rows", [["pinrow:t", 1]], ["pinrow:t"], base: ["pin:t:t": ["pos": "a"], "pin:t:u": ["pos": "b"]]))
    #expect(row["error"] == nil)
    #expect(row["result"] == true)
    #expect(rows.store.state.tabs["t"]?.pinnedAsRow == true)

    let order = seeded(redesign)
    try order.store.dispatch(Command("updateTab", ["t", ["pinnedAsRow": true]]))
    try order.store.dispatch(Command("updateTab", ["u", ["pinnedAsRow": true]]))
    let ordered = apply(order, payload("order", [["pord:g:g", ["a": .null]]], ["pord:g:g"]))
    #expect(ordered["error"] == nil)
    #expect(ordered["result"] == true)
    #expect(order.store.state.windows["w"]?.tabIds.first == "m")

    let looks = seeded(redesign)
    let looked = apply(looks, payload("looks", [["pgc:g", "none"]], ["pgc:g"]))
    #expect(looked["error"] == nil)
    #expect(looked["result"] == true)
    #expect(looks.store.state.groups["g"]?.color == "none")

    let homes = seeded(redesign)
    let homed = apply(homes, payload("homes", [["pgh:m", "https://m.example/remote"]], ["pgh:m"], base: ["pgh:m": "https://m.example/"]))
    #expect(homed["error"] == nil)
    #expect(homed["result"] == ["pgh:m"])
    #expect(homes.store.state.tabs["m"]?.pinnedUrl == "https://m.example/remote")

    let folders = seeded(redesign)
    let foldered = apply(folders, payload("tileFolders", [["tilefold:t", ["f": "f"]], ["tilefold:n:f", ["n": "Folder"]]], ["tilefold:t", "tilefold:n:f"]))
    #expect(foldered["error"] == nil)
    #expect(foldered["result"] == true)
    #expect(folders.store.state.tabs["t"]?.tileFolder == TileFolder(id: "f", name: "Folder"))
  }

  @Test(arguments: [false, true]) func newerLocalHomeSurvivesAndItsKeyIsNotAccepted(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    try bridge.store.dispatch(Command("updateTab", ["m", ["pinnedUrl": "https://b.example/"]]))
    let response = apply(bridge, payload("homes", [["pgh:m", "https://c.example/"]], ["pgh:m"], base: ["pgh:m": "https://m.example/"]))
    #expect(response["error"] == nil)
    #expect(response["result"] == [])
    #expect(bridge.store.state.tabs["m"]?.pinnedUrl == "https://b.example/")
  }

  @Test(arguments: [false, true]) func malformedInputAndUnavailableHomeDoNotReportSuccess(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    for body in [JSONValue.null, payload("unknown"), payload("pins", [[1, "wrong key"]], ["pin:t:t"]), payload("rows", [], [1])] {
      let before = bridge.store.state
      let response = apply(bridge, body)
      #expect(response["error"]?.string != nil)
      #expect(response["result"] == nil)
      #expect(bridge.store.state == before)
    }
    for key in ["base", "known", "now", "horizon"] {
      var body = payload("rows").object!
      body.removeValue(forKey: key)
      let response = apply(bridge, .object(body))
      #expect(response["error"]?.string != nil)
      #expect(response["result"] == nil)
    }
    var config = StoreConfig()
    config.syncOrigins = redesign
    let empty = StoreBridge(store: Store(config: config))
    let refused = apply(empty, payload("pins", [["pin:t:t", ["g": .null, "u": "https://t.example/", "pos": "a"]]], ["pin:t:t"]))
    #expect(refused["result"] == false)
    #expect(empty.store.state.tabs.isEmpty)
  }

  @Test(arguments: [false, true]) func rowOnlyContentDoesNotConsumeTheRowsApply(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    let result = apply(bridge, payload("pins", [["pinrow:t", 1]], ["pinrow:t"]))
    #expect(result["result"] == true)
    #expect(bridge.store.state.tabs["t"]?.pinnedAsRow != true)
    let row = apply(bridge, payload("rows", [["pinrow:t", 1]], ["pinrow:t"]))
    #expect(row["result"] == true)
    #expect(bridge.store.state.tabs["t"]?.pinnedAsRow == true)
  }

  @Test(arguments: [false, true]) func publicationQueuesDuringAUserTransactionAndKeepsANewerChoice(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    _ = bridge.dispatch(json: Command("beginTransaction").json.text(), sinceRev: bridge.store.rev)
    let settlement = Command("settlePinChoices", ["default", ["place:t": 10, "place:u": 11]])
    let envelope: JSONValue = ["fromSync": true, "commands": [settlement.json]]
    let response = bridge.dispatch(json: envelope.text(), sinceRev: bridge.store.rev)
    #expect(response["error"] == nil)
    #expect(response["busy"] == nil)
    #expect(response["result"] == true)
    #expect(bridge.store.queuedFromSyncCount == 1)
    #expect(bridge.store.state.pinChoices["default"]?["place:t"] == 10)
    try bridge.store.dispatch(Command("applyState", [["pinChoices": ["default": ["place:t": 20, "place:u": 11]]]]))
    _ = bridge.dispatch(json: Command("endTransaction").json.text(), sinceRev: bridge.store.rev)
    #expect(bridge.store.queuedFromSyncCount == 0)
    #expect(bridge.store.state.pinChoices["default"]?["place:t"] == 20)
    #expect(bridge.store.state.pinChoices["default"]?["place:u"] == nil)
  }

  @Test(arguments: [false, true]) func malformedSettlementIsRejectedBeforeQueueing(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    _ = bridge.dispatch(json: Command("beginTransaction").json.text(), sinceRev: bridge.store.rev)
    let settlement = Command("settlePinChoices", ["default", ["place:t": "invalid"]])
    let envelope: JSONValue = ["fromSync": true, "commands": [settlement.json]]
    let response = bridge.dispatch(json: envelope.text(), sinceRev: bridge.store.rev)
    #expect(response["error"]?.string != nil)
    #expect(response["result"] == nil)
    #expect(bridge.store.queuedFromSyncCount == 0)
    #expect(bridge.store.state.pinChoices["default"]?["place:t"] == 10)
    _ = bridge.dispatch(json: Command("endTransaction").json.text(), sinceRev: bridge.store.rev)
  }

  @Test(arguments: [false, true]) func knownGroupKeysKeepJavaScriptStringIdentity(_ redesign: Bool) throws {
    let decomposed = "e\u{301}"
    let composed = "\u{e9}"
    let pin: JSONValue = ["g": .string(decomposed), "u": "https://waiting.example/", "t": .null, "i": .null, "ti": "Waiting", "pos": "a"]
    let distinct = seeded(redesign)
    let pending = apply(distinct, payload("pins", [["pin:t:waiting", pin]], ["pin:t:waiting"], known: [.string("pin:g:" + composed)]))
    #expect(pending["result"] == true)
    #expect(distinct.store.state.pinSync["default"]?["waiting"]?["g"] == .string(decomposed))
    #expect(distinct.store.state.pinSync["default"]?["waiting"]?["w"] == 11_000)
    let exact = seeded(redesign)
    let settled = apply(exact, payload("pins", [["pin:t:waiting", pin]], ["pin:t:waiting"], known: [.string("pin:g:" + decomposed)]))
    #expect(settled["result"] == true)
    #expect(exact.store.state.pinSync["default"]?["waiting"] == nil)
  }

  @Test(arguments: [false, true]) func queuedPublicationDrainsWhenAnExpiredUserTransactionMakesTheApplyBusy(_ redesign: Bool) throws {
    let now = Mutex<Double>(1_000)
    let bridge = seeded(redesign, clock: { now.withLock { $0 } })
    _ = bridge.dispatch(json: Command("beginTransaction").json.text(), sinceRev: bridge.store.rev)
    let envelope: JSONValue = ["fromSync": true, "commands": [Command("settlePinChoices", ["default", ["place:t": 10, "place:u": 11]]).json]]
    _ = bridge.dispatch(json: envelope.text(), sinceRev: bridge.store.rev)
    #expect(bridge.store.queuedFromSyncCount == 1)
    now.withLock { $0 += Store.heldTransactionLimit + 1 }
    _ = apply(bridge, payload("rows", [["pinrow:t", 1]], ["pinrow:t"]))
    #expect(bridge.store.queuedFromSyncCount == 0)
    let retried = apply(bridge, payload("rows", [["pinrow:t", 1]], ["pinrow:t"]))
    #expect(retried["busy"] == nil)
    #expect(retried["result"] == true)
    #expect(bridge.store.state.tabs["t"]?.pinnedAsRow == true)
    #expect(bridge.store.state.pinChoices["default"] == nil)
  }

  @Test(arguments: [false, true]) func changedRecordsAreBusyDuringAHeldUserTransaction(_ redesign: Bool) throws {
    let bridge = seeded(redesign)
    _ = bridge.dispatch(json: Command("beginTransaction").json.text(), sinceRev: bridge.store.rev)
    let response = apply(bridge, payload("rows", [["pinrow:t", 1]], ["pinrow:t"]))
    #expect(response["busy"] == true)
    #expect(response["result"] == nil)
    #expect(bridge.store.state.tabs["t"]?.pinnedAsRow != true)
    _ = bridge.dispatch(json: Command("endTransaction").json.text(), sinceRev: bridge.store.rev)
    #expect(apply(bridge, payload("rows", [["pinrow:t", 1]], ["pinrow:t"]))["result"] == true)
    #expect(bridge.store.state.tabs["t"]?.pinnedAsRow == true)
  }
}
