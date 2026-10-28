import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarRevealTests {
  @Test func switchingToAFarTabScrollsItIntoViewAtOnceLikeRN() throws {
    var tabs: [String: Any] = [:]
    let ids = (0..<120).map { "t\($0)" }
    for (i, id) in ids.enumerated() {
      tabs[id] = ["id": id, "windowId": "w", "profileId": "p", "url": "https://site\(i).example/", "title": "Tab \(i)"]
    }
    let root: [String: Any] = [
      "profileOrder": ["p"], "windowOrder": ["w"], "tabs": tabs,
      "windows": ["w": ["id": "w", "profileId": "p", "tabIds": ids, "activeTabIds": ["p": "t0"]]],
    ]
    let text = try #require(String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8))
    let state = try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let sidebar = SidebarView(windowId: "w")
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
    window.contentView = sidebar
    let host = SidebarHostState(profileId: "p")
    sidebar.update(state: state, host: host)
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.scroll.contentView.bounds.minY == 0)

    var next = state
    next.windows["w"]?.activeTabIds["p"] = "t110"
    sidebar.update(state: next, host: host)
    let row = try #require(sidebar.views["t:t110"])
    let clip = sidebar.scroll.contentView
    #expect(clip.bounds.minY > 0)
    #expect(row.frame.maxY <= clip.bounds.maxY && row.frame.minY >= clip.bounds.minY)
    #expect(clip.layer?.animationKeys()?.isEmpty ?? true)
  }
}
