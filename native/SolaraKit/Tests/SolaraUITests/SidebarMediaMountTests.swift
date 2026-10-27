import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func mediaState() throws -> BrowserState {
  let text = #"""
    {"profileOrder": ["p"],
     "windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b"], "activeTabIds": {"p": "b"}}},
     "windowOrder": ["w1"],
     "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/"},
              "b": {"id": "b", "windowId": "w1", "profileId": "p", "url": "https://b.example/"}}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

@MainActor
private func all<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
  root.subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + all(type, in: $0) }
}

@MainActor
@Suite struct SidebarMediaMountTests {
  @Test func hostStateDecodesTheMediaFields() throws {
    let json = ##"{"profileId":"p","dark":true,"theme":{},"border":[],"glow":{"color":"#fff","opacity":1,"radius":15},"selection":[],"loading":[],"playing":[],"sleeping":[],"addressBar":false,"tidy":false,"clear":false,"iconRing":false,"newTabAtTop":false,"incognito":false,"cleaned":0,"engines":{},"developer":[],"pip":["a"],"capture":{"b":"screen"},"badge":["#fff","#000"]}"##
    let host = try #require(SidebarHostState.decode(json))
    #expect(host.pip == ["a"])
    #expect(host.capture == ["b": TabCapture.screen])
    #expect(host.badge == ["#fff", "#000"])
    #expect(host.player == nil)
  }

  @Test func rowsGrowBadgesOnlyForTabsThatHaveOne() throws {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
    var host = SidebarHostState(profileId: "p")
    host.badge = ["rgba(255,255,255,0.9)", "#1B1618"]
    pager.update(state: try mediaState(), host: host)
    pager.layoutSubtreeIfNeeded()
    #expect(all(TabMediaBadgesView.self, in: pager).isEmpty)
    host.pip = ["a"]
    host.capture = ["b": .camera]
    pager.update(state: try mediaState(), host: host)
    pager.layoutSubtreeIfNeeded()
    let shown = all(TabMediaBadgesView.self, in: pager).filter { !$0.isHidden }
    #expect(shown.count == 2)
    #expect(shown.allSatisfy { $0.frame.size == CGSize(width: 16, height: 16) })
    host.pip = []
    host.capture = [:]
    pager.update(state: try mediaState(), host: host)
    #expect(all(TabMediaBadgesView.self, in: pager).filter { !$0.isHidden }.isEmpty)
  }
}
