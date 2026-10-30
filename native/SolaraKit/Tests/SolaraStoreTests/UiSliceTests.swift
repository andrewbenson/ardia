import SolaraModel
import SolaraStore
import Testing

@Suite struct UiSliceTests {
  @Test func appDarkChangesThePatchAndEqualWritesDoNotCommit() throws {
    let store = makeStore()
    let commit = try store.dispatch(Command("setAppDark", [false]))
    #expect(store.state.stateJSON["ui"]?["appDark"] == false)
    #expect(commit.patch.json["ui"]?["appDark"] == false)
    #expect(commit.rev == 1)
    #expect(!commit.durable)
    let same = try store.dispatch(Command("setAppDark", [false]))
    #expect(same.rev == commit.rev)
    #expect(same.changes.isEmpty)
    #expect(same.patch.json["ui"] == nil)
  }

  @Test func findMergesClosedDefaultsAndIgnoresUnknownTabs() throws {
    let store = makeStore()
    let ignored = try store.dispatch(Command("setFind", ["missing", ["query": "missing"]]))
    #expect(ignored.rev == 0)
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let first = try store.dispatch(Command("setFind", [.string(tab), ["open": true, "query": "text"]]))
    #expect(first.patch.json["find"]?["upsert"]?.array?.first?["state"] == ["open": true, "query": "text", "count": .null, "active": 0])
    let other = try store.dispatch(Command("newTab", [.string(window)])).result!.string!
    try store.dispatch(Command("setFind", [.string(other), ["query": "other"]]))
    let second = try store.dispatch(Command("setFind", [.string(tab), ["count": 3, "active": 2, "focusRequest": 7, "replace": true]]))
    #expect(second.patch.json["find"]?["upsert"]?.array?.first?["state"] == ["open": true, "query": "text", "count": 3, "active": 2, "focusRequest": 7, "replace": true])
    #expect(second.patch.json["find"] == ["upsert": [["tabId": .string(tab), "state": store.state.stateJSON["find"]![tab]!]], "remove": []])
    #expect(store.state.stateJSON["find"]?[other]?["query"] == "other")
    #expect(store.state.stateJSON["find"]?[tab] == second.patch.json["find"]?["upsert"]?.array?.first?["state"])
    try store.dispatch(Command("setFind", [.string(tab), ["count": .null]]))
    #expect(store.state.stateJSON["find"]?[tab]?["count"] == .null)
    try store.dispatch(Command("setFind", [.string(tab), ["$unset": ["focusRequest", "replace"]]]))
    #expect(store.state.stateJSON["find"]?[tab]?["focusRequest"] == nil)
    #expect(store.state.stateJSON["find"]?[tab]?["replace"] == nil)
  }

  @Test func applyStateCannotReplaceNativeAppearanceOrFind() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setAppDark", [false]))
    try store.dispatch(Command("setFind", [.string(tab), ["query": "native"]]))
    let ui = store.state.stateJSON["ui"]!.object!
    var stale = ui
    stale["appDark"] = true
    try store.dispatch(Command("applyState", [["ui": .object(stale), "find": [:]]]))
    #expect(store.state.stateJSON["ui"]?["appDark"] == false)
    #expect(store.state.stateJSON["find"]?[tab]?["query"] == "native")
  }

  @Test(arguments: ["closeTab", "closeWindow", "deleteProfile", "applyState"])
  func findIsPrunedInTheTabRemovalCommit(_ command: String) throws {
    let store = makeStore()
    let profile = try store.dispatch(Command("createProfile", [["name": "Other"]])).result!.string!
    let window = try store.dispatch(Command("createWindow", [["profileId": .string(profile)]])).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    try store.dispatch(Command("setFind", [.string(tab), ["open": true]]))
    let args: [JSONValue] = command == "applyState" ? [["tabs": [:], "windows": [:]]] : [.string(command == "deleteProfile" ? profile : command == "closeWindow" ? window : tab)]
    let commit = try store.dispatch(Command(command, args))
    #expect(store.state.tabs[tab] == nil)
    #expect(store.state.stateJSON["find"] == [:])
    #expect(commit.patch.json["find"] == ["upsert": [], "remove": [.string(tab)]])
    #expect(commit.patch.json["tabs"]?["remove"]?.array?.contains(.string(tab)) == true)
  }

  @Test func hydrateClearsFindForRetainedTabsAndKeepsNativeAppearance() throws {
    let store = makeStore()
    let window = try store.dispatch(Command("createWindow")).result!.string!
    let tab = store.state.windows[window]!.tabIds[0]
    let document = store.sessionDocument().json()
    try store.dispatch(Command("setFind", [.string(tab), ["query": "text"]]))
    try store.dispatch(Command("setAppDark", [false]))
    let commit = try store.dispatch(Command("hydrate", [document]))
    #expect(store.state.tabs[tab] != nil)
    #expect(store.state.stateJSON["find"] == [:])
    #expect(commit.patch.json["find"] == ["upsert": [], "remove": [.string(tab)]])
    #expect(store.state.stateJSON["ui"]?["appDark"] == false)
  }
}
