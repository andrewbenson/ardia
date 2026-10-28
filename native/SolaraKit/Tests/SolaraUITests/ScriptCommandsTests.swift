import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
final class FakeWriter: WorkspaceWriter {
  var state: BrowserState
  var calls: [String] = []

  init(_ state: BrowserState) { self.state = state }

  func createWindow(url: String?, incognito: Bool?, profileId: String?) -> String? {
    calls.append("createWindow \(url ?? "-") \(incognito.map(String.init) ?? "-") \(profileId ?? "-")")
    return "new"
  }
  func newTab(_ windowId: String, url: String?, index: Int?) -> String? {
    calls.append("newTab \(windowId) \(url ?? "-") \(index.map(String.init) ?? "-")")
    return "t9"
  }
  func navigate(_ tabId: String, _ url: String) { calls.append("navigate \(tabId) \(url)") }
  func closeTab(_ tabId: String) { calls.append("closeTab \(tabId)") }
  func closeWindow(_ windowId: String) { calls.append("closeWindow \(windowId)") }
  func activate(_ tabId: String) { calls.append("activate \(tabId)") }
  func focusWindow(_ windowId: String) { calls.append("focusWindow \(windowId)") }
  func activateIndex(_ windowId: String, _ index: Int) { calls.append("activateIndex \(windowId) \(index)") }
  func switchProfile(_ windowId: String, _ profileId: String) { calls.append("switchProfile \(windowId) \(profileId)") }
}

struct OmniboxEnv: WebAddressing {
  func resolveInput(_ input: String, searchUrlPrefix: String) -> String { SolaraOmnibox.resolveInput(input, search: searchUrlPrefix) }
  func searchUrlPrefix(_ settings: Settings) -> String { SolaraOmnibox.searchUrlPrefix(settings) }
  func parseURL(_ url: String) -> ParsedURL? {
    WhatwgURL(url).map { ParsedURL(protocol: $0.protocol, host: $0.host, hostname: $0.hostname) }
  }
}

@MainActor
final class FakePages: ScriptPages {
  var pooled: Set<String> = []
  var answer: Any?
  var calls: [String] = []

  func has(_ tabId: String) -> Bool { pooled.contains(tabId) }
  func call(_ tabId: String, _ method: String, _ args: [Any], done: @escaping (Any?, String?) -> Void) {
    calls.append("\(method) \(tabId)")
    done(answer, nil)
  }
}

@MainActor
@Suite struct ScriptCommandsTests {
  private func state(allowJS: Bool = false) throws -> BrowserState {
    let root: [String: Any] = [
      "profileOrder": ["p", "q"], "windowOrder": ["w", "x"],
      "profiles": ["p": ["id": "p", "name": "P"], "q": ["id": "q", "name": "Q"]],
      "settings": ["allowJavaScriptFromAppleEvents": allowJS],
      "ui": ["focusedWindowId": "w", "focusOrder": ["w", "x"]],
      "tabs": [
        "a": ["id": "a", "windowId": "w", "profileId": "p", "url": "https://a/", "title": "A", "pinned": true],
        "b": ["id": "b", "windowId": "w", "profileId": "p", "url": "https://b/", "title": "B"],
        "c": ["id": "c", "windowId": "w", "profileId": "p", "url": "https://c/", "title": "C"],
        "d": ["id": "d", "windowId": "x", "profileId": "p", "url": "https://d/", "title": "D"],
      ],
      "windows": [
        "w": ["id": "w", "profileId": "p", "tabIds": ["a", "b", "c"], "activeTabIds": ["p": "b"]],
        "x": ["id": "x", "profileId": "p", "tabIds": ["d"], "activeTabIds": ["p": "d"]],
      ],
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func run(_ request: [String: Any], _ writer: FakeWriter, _ pages: FakePages = FakePages()) -> (handled: Bool, reply: ScriptReply?) {
    var reply: ScriptReply?
    let handled = ScriptCommandRunner(writer: writer, pages: pages).run(request) { reply = $0 }
    return (handled, reply)
  }

  private func result(_ reply: ScriptReply?) -> [String: Any]? {
    if case .result(let r) = reply { return r }
    return nil
  }

  private func failure(_ reply: ScriptReply?) -> String? {
    if case .failure(let m) = reply { return m }
    return nil
  }

  @Test func newTabSkipsPastPinnedTabs() throws {
    let writer = FakeWriter(try state())
    let r = run(["command": "newTab", "windowId": "w", "url": "https://n/", "index": 0], writer)
    #expect(writer.calls == ["newTab w https://n/ 1"])
    #expect(result(r.reply)?["tabId"] as? String == "t9")
    _ = run(["command": "newTab", "windowId": "w", "index": 5], writer)
    #expect(writer.calls.last == "newTab w - 3")
  }

  @Test func refusesJavaScriptUrlsUnlessAllowed() throws {
    let writer = FakeWriter(try state())
    for url in [
      "javascript:alert(1)", "  JavaScript:alert(1)", "java\tscript:x", "\u{0001}javascript:x",
      "javascript\n:x",
    ] {
      let r = run(["command": "setURL", "tabId": "a", "url": url], writer)
      #expect(result(r.reply)?["refused"] as? String == "javaScriptFromAppleEvents", "\(url)")
    }
    #expect(writer.calls.isEmpty)
    let allowed = FakeWriter(try state(allowJS: true))
    _ = run(["command": "setURL", "tabId": "a", "url": "javascript:1"], allowed)
    #expect(allowed.calls == ["navigate a javascript:1"])
  }

  @Test func agreesWithTheJavaScriptOnPrefixesChromiumKeeps() throws {
    let settings = try state().settings
    #expect(!ScriptCommandRunner.runsJavaScript("\u{FEFF}javascript:x", settings: settings))
    #expect(!ScriptCommandRunner.runsJavaScript("\u{00A0}javascript:x", settings: settings))
  }

  @Test func scriptedUrlsReachTheStoreResolved() throws {
    let store = Store(state: try state(), env: OmniboxEnv(), checksInvariants: false)
    let writer = StoreWorkspaceWriter(store: store, showWindow: { _ in })
    let runner = ScriptCommandRunner(writer: writer, pages: FakePages())
    for prefix in ["\u{FEFF}", "\u{00A0}"] {
      let input = "\(prefix)javascript:alert(1)"
      var replies: [ScriptReply] = []
      #expect(runner.run(["command": "newWindow", "url": input]) { replies.append($0) })
      #expect(runner.run(["command": "newTab", "windowId": "w", "url": input]) { replies.append($0) })
      #expect(runner.run(["command": "setURL", "tabId": "a", "url": input]) { replies.append($0) })
      #expect(replies.count == 3)
      let created = replies.compactMap { reply -> [String: Any]? in if case .result(let r) = reply { return r } else { return nil } }
      let window = try #require(created[0]["windowId"] as? String)
      let tab = try #require(created[1]["tabId"] as? String)
      let reached = [store.state.activeTab(window)?.url, store.state.tabs[tab]?.url, store.state.tabs["a"]?.url]
      #expect(reached.allSatisfy { $0?.hasPrefix("https://") == true }, "\(reached)")
    }
  }

  @Test func refusesAJavaScriptSearchTemplate() throws {
    var s = try state()
    s.settings = try BrowserState(stateJSON: try JSONValue.parse(#"{"settings":{"searchEngine":"js","customSearchEngines":[{"id":"js","name":"JS","url":"javascript:alert('%s')"}]}}"#).object ?? [:]).settings
    let writer = FakeWriter(s)
    let r = run(["command": "setURL", "tabId": "a", "url": "plain words"], writer)
    #expect(result(r.reply)?["refused"] as? String == "javaScriptFromAppleEvents")
  }

  @Test func reportsMissingTargetsWithTheJavaScriptMessages() throws {
    let writer = FakeWriter(try state())
    #expect(failure(run(["command": "closeTab", "tabId": "zz"], writer).reply) == "That tab no longer exists.")
    #expect(failure(run(["command": "closeWindow", "windowId": "zz"], writer).reply) == "That window no longer exists.")
    #expect(failure(run(["command": "setActiveTabIndex", "windowId": "w", "index": 4], writer).reply) == "There's no tab at that index.")
    #expect(failure(run(["command": "focusProfile", "profileId": "zz"], writer).reply) == "That profile no longer exists.")
    #expect(writer.calls.isEmpty)
  }

  @Test func focusTabBringsItsWindowForward() throws {
    let writer = FakeWriter(try state())
    _ = run(["command": "focusTab", "tabId": "d"], writer)
    #expect(writer.calls == ["activate d", "focusWindow x"])
    _ = run(["command": "focusTab", "tabId": "a"], writer)
    #expect(writer.calls.suffix(1) == ["activate a"])
    _ = run(["command": "setActiveTabIndex", "windowId": "w", "index": 2], writer)
    #expect(writer.calls.last == "activateIndex w 1")
    _ = run(["command": "focusProfile", "profileId": "q"], writer)
    #expect(writer.calls.last == "switchProfile w q")
  }

  @Test func pageCommandsUsePooledPagesAndForwardTheRest() throws {
    let writer = FakeWriter(try state(allowJS: true))
    let pages = FakePages()
    #expect(run(["command": "back", "tabId": "a"], writer, pages).handled == false)
    pages.pooled = ["a"]
    #expect(run(["command": "back", "tabId": "a"], writer, pages).handled)
    #expect(run(["command": "reload", "tabId": "a"], writer, pages).handled)
    pages.answer = #"{"value":"42"}"#
    let executed = run(["command": "execute", "tabId": "a", "code": "6*7"], writer, pages)
    #expect(result(executed.reply)?["value"] as? String == "42")
    pages.answer = #"{"error":"ReferenceError: x"}"#
    #expect(failure(run(["command": "execute", "tabId": "a", "code": "x"], writer, pages).reply) == "ReferenceError: x")
    pages.answer = nil
    #expect(failure(run(["command": "execute", "tabId": "a", "code": "1"], writer, pages).reply) == "The page didn't answer.")
    #expect(pages.calls == ["goBack a", "reload a", "evaluate a", "evaluate a", "evaluate a"])
  }

  @Test func executeIsRefusedWhenTurnedOff() throws {
    let pages = FakePages()
    pages.pooled = ["a"]
    let r = run(["command": "execute", "tabId": "a", "code": "1"], FakeWriter(try state()), pages)
    #expect(result(r.reply)?["refused"] as? String == "javaScriptFromAppleEvents")
    #expect(pages.calls.isEmpty)
  }
}
