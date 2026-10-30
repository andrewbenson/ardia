import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct LaunchBackdropTests {
  @Test func matchesProductionJavaScriptForProfilesLooksAndAppearances() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/launch-backdrop.json")
    let fixture = try JSONValue.parse(Data(contentsOf: fixtureURL))
    let cases = try #require(fixture["cases"]?.array)
    for entry in cases {
      let name = entry["name"]?.string ?? ""
      var state = BrowserState()
      state.profiles["default"] = try Profile(json: #require(entry["profile"]?.object))
      state.windows["window"] = BrowserWindow(id: "window", profileId: "default", incognito: false, frame: nil, createdAt: 0)
      state.windowOrder = ["window"]
      state.ui = FocusState(focusedWindowId: "window", focusOrder: ["window"])
      state.settings["appearance"] = entry["appDark"] == .bool(true) ? "dark" : "light"
      state.settings["spacesFollowAppearance"] = entry["spacesFollowAppearance"]
      let actual = Store(state: state).sessionDocument().launchBackdrop
      #expect(backdropEquivalent(actual, entry["expected"] ?? .null), Comment(rawValue: name))
    }
  }

  @Test func exportsCurrentProfileAndSettingsInsteadOfTheBridgeCache() throws {
    let store = Store()
    try store.dispatch(Command("createWindow", [["url": "https://example.com/"]]))
    let windowId = try #require(store.state.windowOrder.first)
    try store.dispatch(Command("setFocusedWindow", [.string(windowId)]))
    let first = store.sessionDocument().launchBackdrop
    #expect(first != .null)
    try store.dispatch(Command("setLaunchBackdrop", [["outdated": true]]))
    #expect(store.sessionDocument().launchBackdrop == first)
    try store.updateAppAppearance(true)
    #expect(store.sessionDocument().launchBackdrop["dark"] == .bool(true))
    #expect(store.sessionDocument().launchBackdrop != first)
    try store.updateAppAppearance(false)
    #expect(store.sessionDocument().launchBackdrop == first)
    try store.dispatch(Command("updateSettings", [["appearance": "dark"]]))
    #expect(store.sessionDocument().launchBackdrop["dark"] == .bool(true))
    try store.dispatch(Command("updateSettings", [["appearance": "light"]]))
    try store.updateAppAppearance(true)
    #expect(store.sessionDocument().launchBackdrop["dark"] == .bool(false))
  }

  @Test func excludesPrivateAndSmallWindowsAndHonorsTheLaunchSwitch() throws {
    var state = BrowserState()
    var window = BrowserWindow(id: "window", profileId: "default", incognito: false, frame: nil, createdAt: 0)
    state.windows[window.id] = window
    state.windowOrder = [window.id]
    state.ui = FocusState(focusedWindowId: window.id, focusOrder: [window.id])
    #expect(Store(state: state).sessionDocument().launchBackdrop != .null)
    window.incognito = true
    state.windows[window.id] = window
    #expect(Store(state: state).sessionDocument().launchBackdrop == .null)
    window.incognito = false
    window.kind = "small"
    state.windows[window.id] = window
    #expect(Store(state: state).sessionDocument().launchBackdrop == .null)
    window.kind = nil
    state.windows[window.id] = window
    var config = StoreConfig()
    config.earlyLaunchTab = false
    #expect(Store(state: state, config: config).sessionDocument().launchBackdrop == .null)
  }
}

private func backdropEquivalent(_ a: JSONValue, _ b: JSONValue) -> Bool {
  switch (a, b) {
  case (.number(let x), .number(let y)): abs(x - y) < 1e-10
  case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy(backdropEquivalent)
  case (.object(let x), .object(let y)): Set(x.keys) == Set(y.keys) && x.allSatisfy { key, value in backdropEquivalent(value, y[key] ?? .null) }
  default: a == b
  }
}
