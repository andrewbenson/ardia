import AppKit
import SolaraModel
import SolaraStore
import Testing

@testable import SolaraUI

private func pagedState() throws -> BrowserState {
  let text = #"""
    {"profileOrder": ["p", "q", "r"],
     "windows": {"w1": {"id": "w1", "profileId": "p", "tabIds": ["a", "b", "c"], "activeTabIds": {"p": "a", "q": "b", "r": "c"}}},
     "windowOrder": ["w1"],
     "tabs": {"a": {"id": "a", "windowId": "w1", "profileId": "p", "url": "https://a.example/"},
              "b": {"id": "b", "windowId": "w1", "profileId": "q", "url": "https://b.example/"},
              "c": {"id": "c", "windowId": "w1", "profileId": "r", "url": "https://c.example/"}}}
    """#
  return try BrowserState(stateJSON: try JSONValue.parse(text).object ?? [:])
}

private func host(_ profileId: String) -> SidebarHostState {
  var out = SidebarHostState(profileId: profileId)
  out.pages = ["p", "q", "r"].map {
    SidebarPageLook(profileId: $0, dark: true, theme: [:], border: [], glow: out.glow, tidy: false, incognito: false)
  }
  return out
}

@MainActor
private func shown(_ pager: SidebarPagerView) -> [String] {
  pager.describePages().compactMap { page in
    guard let id = page["id"] as? String, page["hidden"] as? Bool == false, let x = page["x"] as? CGFloat else { return nil }
    return "\(id)@\(Int(x))"
  }
}

@MainActor
@Suite struct SidebarPagerTests {
  private func pager() throws -> SidebarPagerView {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    pager.update(state: try pagedState(), host: host("p"))
    return pager
  }

  @Test func atRestOnlyTheCurrentProfileShows() throws {
    let pager = try pager()
    #expect(shown(pager) == ["p@0"])
  }

  @Test func neighbouringPagesSlideWithThePager() throws {
    let pager = try pager()
    pager.setPagerPosition(0.5)
    #expect(shown(pager) == ["p@-100", "q@100"])
    pager.setPagerPosition(1.75)
    #expect(shown(pager) == ["q@-150", "r@50"])
  }

  @Test func theEdgesRubberBandPastTheFirstAndLastProfile() throws {
    let pager = try pager()
    pager.setPagerPosition(-0.2)
    #expect(shown(pager) == ["p@40"])
  }

  @Test func aCommitMidSpringKeepsThePagerPosition() throws {
    let pager = try pager()
    pager.setPagerPosition(0.6)
    pager.update(state: try pagedState(), host: host("q"))
    #expect(shown(pager) == ["p@-120", "q@80"])
    pager.setPagerPosition(1)
    #expect(shown(pager) == ["q@0"])
  }

  @Test func aSwitchThatBypassesThePagerShowsTheNewProfile() throws {
    let pager = try pager()
    pager.setPagerPosition(0)
    pager.update(state: try pagedState(), host: host("r"))
    #expect(shown(pager) == ["r@0"])
  }

  @Test func withoutPagesOnlyTheCurrentProfileIsLaidOut() throws {
    let pager = SidebarPagerView(windowId: "w1")
    pager.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    pager.update(state: try pagedState(), host: SidebarHostState(profileId: "q"))
    pager.setPagerPosition(0.5)
    #expect(shown(pager) == ["q@0"])
  }
}
