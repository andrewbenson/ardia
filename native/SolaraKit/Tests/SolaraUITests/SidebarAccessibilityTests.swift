import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

@MainActor
private func all<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
  root.subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + all(type, in: $0) }
}

@MainActor
@Suite struct SidebarAccessibilityTests {
  @Test func tabRowsAreButtonsNamedForTheirTabAndPressToActivate() throws {
    let text = #"""
      {"profileOrder": ["p"],
       "windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "a"}}},
       "windowOrder": ["w1"],
       "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/", "title": "Alpha"},
                "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/", "title": "Beta"}}}
      """#
    let state = try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
    var actions: [SidebarAction] = []
    pager.onAction = { actions.append($0) }
    pager.update(state: state, host: SidebarHostState(profileId: "p"))
    pager.layoutSubtreeIfNeeded()
    let rows = all(TabRowView.self, in: pager)
    #expect(rows.map { $0.accessibilityLabel() ?? "" }.sorted() == ["Alpha", "Beta"])
    #expect(rows.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    let beta = try #require(rows.first { $0.accessibilityLabel() == "Beta" })
    #expect(beta.accessibilityPerformPress())
    #expect(actions.contains { if case .click(let id, let mods) = $0 { id == "b" && mods.none } else { false } })

    var host = SidebarHostState(profileId: "p")
    host.engines = ["a": "safari"]
    pager.update(state: state, host: host)
    pager.layoutSubtreeIfNeeded()
    let labels = all(TabRowView.self, in: pager).compactMap { $0.accessibilityLabel() }.sorted()
    #expect(labels == ["Alpha, Opens in WebKit", "Beta"])
  }
}
