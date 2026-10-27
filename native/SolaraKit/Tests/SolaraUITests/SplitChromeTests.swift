import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
  abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
}

private func splitState(sizes: [Double] = [0.5, 0.5]) throws -> BrowserState {
  let text = #"""
    {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "a"}}},
     "windowOrder": ["w1"],
     "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/", "title": "a"},
              "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/", "title": "b"}},
     "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": \#(sizes)}}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

@Suite struct SplitDropTests {
  let left = CGRect(x: 0, y: 0, width: 600, height: 700)
  let right = CGRect(x: 607, y: 0, width: 600, height: 700)

  @Test func zonesSitWhereRnPutsThem() {
    #expect(near(SplitDrop.zoneRect(left, .left, .rest), CGRect(x: 15, y: 215.95, width: 79.44, height: 268.1)))
    #expect(near(SplitDrop.zoneRect(left, .right, .grown), CGRect(x: 459, y: 136.15, width: 129, height: 427.7)))
    #expect(near(SplitDrop.zoneRect(left, .left, .active, pointerX: 300), CGRect(x: 100.305, y: 108.5, width: 144.6, height: 483)))
    #expect(near(SplitDrop.zoneRect(right, .right, .active, pointerX: 1100), CGRect(x: 1045.085, y: 108.5, width: 144.6, height: 483)))
  }

  @Test func hitsMatchRn() {
    let panes = [(tabId: "a", rect: left), (tabId: "b", rect: right)]
    #expect(SplitDrop.zoneHit(panes, 80, 350, current: nil) == SplitDropTarget(tabId: "a", side: .left))
    #expect(SplitDrop.zoneHit(panes, 560, 350, current: nil) == SplitDropTarget(tabId: "a", side: .right))
    #expect(SplitDrop.zoneHit(panes, 300, 350, current: SplitDropTarget(tabId: "a", side: .left)) == SplitDropTarget(tabId: "a", side: .left))
    #expect(SplitDrop.zoneHit([(tabId: "a", rect: left)], 300, 50, current: nil) == nil)
  }

  @Test func rnSpringConfigConverts() {
    let pop = SpringParams.rn(speed: 14, bounciness: 14)
    #expect(abs(pop.stiffness - 384.58) < 0.01)
    #expect(abs(pop.damping - 18.2) < 0.01)
  }
}

@Suite @MainActor struct SplitChromeTests {
  @Test func dividersAndPanesFollowTheSplit() throws {
    let view = SplitChromeView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    #expect(view.panes["a"] == CGRect(x: 0, y: 0, width: 500, height: 700))
    #expect(view.panes["b"] == CGRect(x: 507, y: 0, width: 500, height: 700))
    let dividers = view.subviews.compactMap { $0 as? SplitDividerView }
    #expect(dividers.count == 1)
    #expect(dividers.first?.frame == CGRect(x: 498, y: 0, width: 11, height: 700))
  }

  @Test func aFullscreenTabHidesTheDividers() throws {
    let view = SplitChromeView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.setChrome(theme: .fallback, fullscreenTab: "b")
    view.layoutSubtreeIfNeeded()
    #expect(view.panes["b"] == view.bounds)
    #expect(view.subviews.compactMap { $0 as? SplitDividerView }.isEmpty)
  }

  @Test func hitTestingPassesEverythingButTheDividers() throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 1007, height: 700))
    let view = SplitChromeView(windowId: "w1")
    view.frame = host.bounds
    host.addSubview(view)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    #expect(view.hitTest(CGPoint(x: 200, y: 300)) == nil)
    #expect(view.hitTest(CGPoint(x: 503, y: 300)) is SplitDividerView)
  }
}

@Suite(.serialized) @MainActor struct SplitPanesTests {
  @Test func eachLeafRegistersItsPageContainerUnderTheToolbar() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    let a = try #require(view.container("a"))
    #expect(TabSlots.shared.container(for: .pane("w1", "a")) === a)
    #expect(a.superview?.frame == CGRect(x: 0, y: 0, width: 500, height: 700))
    #expect(a.frame == CGRect(x: 0, y: 41, width: 500, height: 659))
    #expect(TabSlots.shared.container(for: .pane("w1", "b")) === view.container("b"))
  }

  @Test func leavingTheSplitRemovesOnlyItsOwnSlots() throws {
    let view = SplitPanesView(windowId: "w1")
    view.frame = CGRect(x: 0, y: 0, width: 1007, height: 700)
    view.update(state: try splitState())
    view.layoutSubtreeIfNeeded()
    let other = NSView()
    TabSlots.shared.set(.pane("w1", "b"), container: other)
    var state = try splitState()
    state.splits = Table()
    view.update(state: state)
    view.layoutSubtreeIfNeeded()
    #expect(TabSlots.shared.container(for: .pane("w1", "a")) == nil)
    #expect(TabSlots.shared.container(for: .pane("w1", "b")) === other)
    TabSlots.shared.remove(.pane("w1", "b"), container: other)
  }
}

@Suite struct SplitEmptyStateTests {
  @Test func suggestsRecentTabsOutsideTheSplitInTheSameProfile() throws {
    let text = #"""
      {"windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b", "c", "d", "e", "f"], "activeTabIds": {"p": "a"}}},
       "windowOrder": ["w1"],
       "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "", "title": ""},
                "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/", "title": "B", "lastActiveAt": 9},
                "c": {"id": "c", "windowId": "w1", "profileId": "p", "url": "https://www.c.example/x", "title": "C page", "lastActiveAt": 5},
                "d": {"id": "d", "windowId": "w1", "profileId": "q", "url": "https://d.example/", "title": "D", "lastActiveAt": 7},
                "e": {"id": "e", "windowId": "w1", "profileId": "p", "url": "https://e.example/", "title": "E", "lastActiveAt": 8},
                "f": {"id": "f", "windowId": "w1", "profileId": "p", "url": "", "title": "", "lastActiveAt": 10}},
       "splits": {"s1": {"id": "s1", "windowId": "w1", "tabIds": ["a", "b"], "orientation": "horizontal", "sizes": [0.5, 0.5]}}}
      """#
    let state = try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
    let list = SplitEmptyState.suggestions(state, tabId: "a")
    #expect(list.map(\.tabId) == ["e", "c"])
    #expect(list.last?.label == "c.example")
    #expect(list.last?.detail == "C page")
  }
}
