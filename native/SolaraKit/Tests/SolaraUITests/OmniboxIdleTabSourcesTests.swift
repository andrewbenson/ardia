import Foundation
import SolaraModel
import SolaraOmnibox
import Testing
@testable import SolaraUI

@Suite @MainActor struct OmniboxIdleTabSourcesTests {
  private func fixture() throws -> JSONValue {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("SolaraOmniboxTests/Fixtures/idle-tabs.json")
    return try JSONValue.parse(Data(contentsOf: path))
  }

  private func state(_ input: JSONValue) throws -> BrowserState {
    var state = BrowserState()
    state.settings = Settings(values: ["shareTabsAcrossWindows": input["shared"]!])
    for value in input["tabs"]!.array! {
      let tab = try Tab(json: value.object!)
      state.tabs[tab.id] = tab
    }
    for value in input["windows"]!.array! {
      let window = try BrowserWindow(json: value.object!)
      state.windows[window.id] = window
    }
    for (windowId, value) in input["peeks"]!.object! {
      state.peeks[windowId] = try Peek(json: value.object!)
    }
    return state
  }

  private func json(_ suggestions: [Suggestion]) -> JSONValue {
    .array(suggestions.map { row in
      guard case let .page(url, title, favicon, tabId, bookmarked, visited) = row else { return .null }
      #expect(!bookmarked && !visited)
      return ["kind": .string("page"), "url": .string(url), "title": .string(title), "favicon": JSONValue(favicon), "tabId": JSONValue(tabId)]
    })
  }

  @Test func idleSuggestionsMatchActualJavaScriptComputation() throws {
    for input in try fixture()["cases"]!.array! {
      let state = try state(input)
      let sources = NewTabSources()
      sources.applyWorkspace(OmniboxWorkspaceSources(state))
      let windowId = input["windowId"]!.string!
      let profileId = input["profileId"]!.string!
      let active = sources.activeTabId(windowId: windowId, profileId: profileId)
      #expect(active == input["active"]!.string)
      let result = sources.openTabs(windowId: windowId, profileId: profileId, excluding: active)
      #expect(json(result) == input["expected"]!, "\(input["name"]!)")
      let fallback = NewTabSources()
      fallback.setIdleTabs(OmniboxIdleTabSources(tabs: state.tabs.values,
        peeks: Dictionary(uniqueKeysWithValues: state.peeks.map { ($0.key, $0.value.tabId) }), shared: state.settings.bool("shareTabsAcrossWindows"),
        activeTabIds: Dictionary(uniqueKeysWithValues: state.windows.map { ($0.key, Dictionary(uniqueKeysWithValues: $0.value.activeTabIds.map { ($0.key, $0.value) })) })))
      #expect(json(fallback.openTabs(windowId: windowId, profileId: profileId, excluding: active)) == input["expected"]!)
      let decoded = try #require(OmniboxIdleTabSources.decode(input["fallbackPayload"]!.text()))
      fallback.setIdleTabs(decoded)
      #expect(fallback.activeTabId(windowId: windowId, profileId: profileId) == active)
      #expect(json(fallback.openTabs(windowId: windowId, profileId: profileId, excluding: active)) == input["expected"]!)
      sources.resetWorkspace()
      #expect(sources.openTabs(windowId: windowId, profileId: profileId, excluding: nil).isEmpty)
      #expect(sources.activeTabId(windowId: windowId, profileId: profileId) == nil)
    }
  }

  @Test(arguments: ["", "{}", "[]", "null", "{\"tabs\":[],\"windows\":[],\"peeks\":{},\"shared\":1}",
    "{\"tabs\":[null],\"windows\":[],\"peeks\":{},\"shared\":false}",
    "{\"tabs\":[],\"windows\":[null],\"peeks\":{},\"shared\":false}",
    "{\"tabs\":[],\"windows\":[],\"peeks\":{\"w\":null},\"shared\":false}"])
  func malformedFallbackIsRejected(json: String) {
    #expect(OmniboxIdleTabSources.decode(json) == nil)
  }

  @Test func idleMetadataChangesInvalidateProjectionWithoutQueryRowChanges() {
    var state = BrowserState()
    var tab = Tab(id: "tab", windowId: "window", profileId: "default", url: "https://example.com/", now: 0)
    tab.title = "Title"
    state.tabs[tab.id] = tab
    let initial = OmniboxWorkspaceSources(state)
    for field in ["lastActiveAt", "customTitle", "pinned", "pinKey", "peek", "shared", "active"] {
      var changed = state
      switch field {
      case "lastActiveAt": changed.tabs[tab.id]!.lastActiveAt = 20
      case "customTitle": changed.tabs[tab.id]!.customTitle = "Custom"
      case "pinned": changed.tabs[tab.id]!.pinned = true
      case "pinKey": changed.tabs[tab.id]!.pinKey = "family"
      case "peek": changed.peeks["window"] = Peek(tabId: tab.id, sourceId: "source", sourcePage: "", from: nil)
      case "shared": changed.settings["shareTabsAcrossWindows"] = true
      default:
        var window = BrowserWindow(id: "window", profileId: "default", incognito: false, frame: nil, createdAt: 0)
        window.activeTabIds["default"] = tab.id
        changed.windows[window.id] = window
      }
      let projection = OmniboxWorkspaceSources(changed)
      #expect(initial.profiles == projection.profiles)
      #expect(initial != projection, "\(field)")
    }
  }

  @Test func idleStringsPreserveRawUTF16ForPublication() {
    var state = BrowserState()
    var tab = Tab(id: "tab", windowId: "window", profileId: "default", url: "https://example.com/", now: 0)
    tab.customTitle = "caf\u{e9}"
    state.tabs[tab.id] = tab
    let initial = OmniboxWorkspaceSources(state)
    state.tabs[tab.id]!.customTitle = "cafe\u{301}"
    let changed = OmniboxWorkspaceSources(state)
    #expect(initial != changed)
    let sources = NewTabSources()
    sources.applyWorkspace(initial)
    sources.applyWorkspace(changed)
    guard case let .page(_, title, _, _, _, _)? = sources.openTabs(windowId: "window", profileId: "default", excluding: nil).first else {
      Issue.record("missing idle row")
      return
    }
    #expect(Array(title.utf16) == Array("cafe\u{301}".utf16))
  }

  #if SOLARA_PROBES
  @Test func idleKeysAndWhitespaceReuseThePrimedProjection() {
    var state = BrowserState()
    state.tabs["t"] = Tab(id: "t", windowId: "closed", profileId: "p", url: "https://closed.example/", now: 10)
    let sources = NewTabSources()
    sources.applyWorkspace(OmniboxWorkspaceSources(state))
    let model = HeroBarModel(windowId: "visible", tabId: "current", profileId: "p", incognito: false,
      settings: { Settings(values: [:]) }, sources: sources, variant: .panel, opensTab: true)
    #expect(sources.idleProjectionCount == 1)
    model.key(HeroKey(.arrowDown))
    model.key(HeroKey(.arrowDown))
    _ = model.items
    _ = model.current
    _ = model.selectedIndex
    model.textChanged(" ", edit: nil)
    model.textChanged("git", edit: nil)
    #expect(sources.idleProjectionCount == 1)
  }

  @Test func idleCacheSeparatesRawContextAndReusesEachContext() {
    let sources = NewTabSources()
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    let tabs = [
      Tab(id: composed, windowId: composed, profileId: composed, url: "https://first.example/", now: 10),
      Tab(id: decomposed, windowId: decomposed, profileId: composed, url: "https://second.example/", now: 20),
      Tab(id: "other", windowId: composed, profileId: decomposed, url: "https://other.example/", now: 30),
    ]
    let projection = OmniboxIdleTabSources(tabs: tabs, peeks: [:], shared: true)
    sources.setIdleTabs(projection)
    let contexts: [(String, String, String?)] = [
      (composed, composed, nil), (decomposed, composed, nil), (composed, decomposed, nil),
      (composed, composed, composed), (composed, composed, decomposed), (composed, composed, ""),
    ]
    for (window, profile, excluding) in contexts {
      #expect(sources.openTabs(windowId: window, profileId: profile, excluding: excluding)
        == projection.openTabs(windowId: window, profileId: profile, excluding: excluding))
    }
    #expect(sources.idleProjectionCount == contexts.count)
    for (window, profile, excluding) in contexts.reversed() {
      #expect(sources.openTabs(windowId: window, profileId: profile, excluding: excluding)
        == projection.openTabs(windowId: window, profileId: profile, excluding: excluding))
    }
    #expect(sources.idleProjectionCount == contexts.count)
  }

  @Test func idleCacheInvalidatesOnlyWhenItsSourceChanges() {
    let sources = NewTabSources()
    var state = BrowserState()
    state.tabs["t"] = Tab(id: "t", windowId: "w", profileId: "p", url: "https://example.com/", now: 10)
    let initial = OmniboxWorkspaceSources(state)
    sources.applyWorkspace(initial)
    let read = { sources.openTabs(windowId: "w", profileId: "p", excluding: nil) }
    _ = read()
    #expect(sources.idleProjectionCount == 1)
    sources.applyWorkspace(initial)
    sources.setIdleTabs(initial.idleTabs)
    sources.setTabs([], profileId: "p")
    sources.setHistory([], profileId: "p")
    sources.setBookmarks([], profileId: "p")
    sources.setActions([], windowId: "w")
    sources.setExtensions([], windowId: "w")
    _ = read()
    #expect(sources.idleProjectionCount == 1)
    for field in ["lastActiveAt", "title", "url", "favicon", "customTitle", "pinKey", "pinned", "peek", "shared", "active"] {
      var changed = state
      switch field {
      case "lastActiveAt": changed.tabs["t"]!.lastActiveAt = 20
      case "title": changed.tabs["t"]!.title = "Changed"
      case "url": changed.tabs["t"]!.url = "https://changed.example/"
      case "favicon": changed.tabs["t"]!.favicon = "icon:changed"
      case "customTitle": changed.tabs["t"]!.customTitle = "Custom"
      case "pinKey": changed.tabs["t"]!.pinKey = "family"
      case "pinned": changed.tabs["t"]!.pinned = true
      case "peek": changed.peeks["w"] = Peek(tabId: "t", sourceId: "source", sourcePage: "", from: nil)
      case "shared": changed.settings["shareTabsAcrossWindows"] = true
      default:
        var window = BrowserWindow(id: "w", profileId: "p", incognito: false, frame: nil, createdAt: 0)
        window.activeTabIds["p"] = "t"
        changed.windows["w"] = window
      }
      let before = sources.idleProjectionCount
      let projection = OmniboxWorkspaceSources(changed)
      sources.applyWorkspace(projection)
      #expect(read() == projection.idleTabs.openTabs(windowId: "w", profileId: "p", excluding: nil))
      #expect(sources.idleProjectionCount == before + 1, "\(field)")
      sources.setIdleTabs(projection.idleTabs)
      _ = read()
      #expect(sources.idleProjectionCount == before + 1)
    }
    let beforeFallback = sources.idleProjectionCount
    sources.setIdleTabs(initial.idleTabs)
    _ = read()
    #expect(sources.idleProjectionCount == beforeFallback + 1)
    sources.resetWorkspace()
    #expect(read().isEmpty)
    #expect(sources.idleProjectionCount == beforeFallback + 2)
    sources.resetWorkspace()
    #expect(read().isEmpty)
    #expect(sources.idleProjectionCount == beforeFallback + 2)
  }
  #endif

}
