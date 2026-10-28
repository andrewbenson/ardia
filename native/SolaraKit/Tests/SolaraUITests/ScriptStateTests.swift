import Foundation
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@Suite struct ScriptStateTests {
  private func state(_ root: [String: Any]) throws -> BrowserState {
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
  }

  private func label(_ url: String, _ title: String = "", custom: String? = nil) throws -> String {
    var tab: [String: Any] = ["id": "t", "windowId": "w", "profileId": "p", "url": url, "title": title]
    if let custom { tab["customTitle"] = custom }
    let s = try state([
      "profileOrder": ["p"], "windowOrder": ["w"], "profiles": ["p": ["id": "p", "name": "P"]], "tabs": ["t": tab],
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ["t"], "activeTabIds": ["p": "t"]]],
    ])
    return ScriptState.tabLabel(try #require(s.tabs["t"]))
  }

  @Test func tabLabelsMatchTheJavaScript() throws {
    #expect(try label("https://www.example.com/a", "T") == "example.com")
    #expect(try label("https://example.com/a", "T", custom: "Mine") == "Mine")
    #expect(try label("") == "New Tab")
    #expect(try label("https://xn--bcher-kva.example/", "B") == "bücher.example")
    #expect(try label("file:///Users/me/My%20Doc.pdf") == "My Doc.pdf")
    #expect(try label("file:///Users/me/a.pdf", "PDF") == "PDF")
    #expect(try label("chrome://settings/passwords", "S") .hasSuffix("://settings"))
    #expect(try label("about:blank", "Blank") == "Blank")
    #expect(try label("not a url") == "not a url")
    #expect(try label("data:text/html,hi", "D") == "D")
  }

  @Test func buildsTheStateTheShellReads() throws {
    let s = try state([
      "profileOrder": ["p", "q"], "windowOrder": ["w", "i"],
      "profiles": ["p": ["id": "p", "name": "Personal"], "q": ["id": "q", "name": "Work"]],
      "settings": ["defaultProfileId": "p"],
      "tabs": [
        "a": ["id": "a", "windowId": "w", "profileId": "p", "url": "https://a.example/", "title": "A", "pinned": true],
        "b": ["id": "b", "windowId": "w", "profileId": "p", "url": "https://www.b.example/", "title": "B", "customTitle": "Bee"],
        "c": ["id": "c", "windowId": "w", "profileId": "q", "url": "https://c.example/", "title": "C"],
        "d": ["id": "d", "windowId": "i", "profileId": "incognito-1", "url": "", "title": ""],
      ],
      "windows": [
        "w": ["id": "w", "profileId": "p", "tabIds": ["a", "b", "c"], "activeTabIds": ["p": "b", "q": "c"]],
        "i": ["id": "i", "profileId": "incognito-1", "incognito": true, "tabIds": ["d"], "activeTabIds": ["incognito-1": "d"]],
      ],
    ])
    let built = ScriptState.build(s, loading: ["a"])
    let windows = try #require(built["windows"] as? [[String: Any]])
    #expect(windows.count == 2)
    #expect(windows[0]["title"] as? String == "Personal — Bee & 1 Tab")
    #expect(windows[0]["activeTabId"] as? String == "b")
    let tabs = try #require(windows[0]["tabs"] as? [[String: Any]])
    #expect(tabs.map { $0["id"] as? String } == ["a", "b"])
    #expect(tabs.map { $0["title"] as? String } == ["A", "Bee"])
    #expect(tabs.map { $0["loading"] as? Bool } == [true, false])
    #expect(tabs.map { $0["pinned"] as? Bool } == [true, false])
    #expect(windows[1]["incognito"] as? Bool == true)
    let profiles = try #require(built["profiles"] as? [[String: Any]])
    #expect(profiles.map { $0["name"] as? String } == ["Personal", "Work"])
  }
}
