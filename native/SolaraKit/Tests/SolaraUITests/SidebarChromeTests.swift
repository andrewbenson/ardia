import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct SidebarChromeTests {
  func state(addressBar: Bool = false, downloads: Bool = true, dots: Int = 3, profiles: Int = 3) -> SidebarChromeState {
    SidebarChromeState(
      controls: StripControlsState(title: "Work", incognito: false, profiles: profiles, nameColor: "#336699", downloadsOpen: false, downloadsTooltip: "Downloads"),
      downloads: downloads, addressBar: addressBar, dark: false, theme: [:],
      dots: (0..<dots).map { SidebarChromeDot(id: "p\($0)", name: "P\($0)", slot: $0 < 2 ? Double($0) : nil) }, savedWidth: 220)
  }

  @Test func rubberBandMatchesRN() {
    #expect(SidebarResizeMath.rubberBand(300) == 300)
    #expect(abs(SidebarResizeMath.rubberBand(490) - (400 + 36 * (1 - exp(-1)))) < 1e-9)
    #expect(abs(SidebarResizeMath.unstretch(SidebarResizeMath.rubberBand(450)) - 450) < 1e-6)
    #expect(SidebarResizeMath.clamp(120) == 160)
    #expect(abs(SidebarResizeMath.backOut(0)) < 1e-9 && SidebarResizeMath.backOut(1) == 1)
    #expect(SidebarResizeMath.backOut(0.6) > 1)
    #expect(SidebarResizeMath.live(200.26) == 200.5)
  }

  @Test func headerControlsSitWhereRNPutsThem() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    #expect(view.headerHeight == 46)
    #expect(view.footerHeight == 41)
    #expect(view.indicator.frame.minX == 84 && view.indicator.frame.minY == 10.5)
    #expect(view.headerDownloads.frame == NSRect(x: 220 - 7 - 34, y: 10, width: 34, height: 34))
    #expect(view.footerDownloads.isHidden)
    #expect(view.resize.frame == NSRect(x: 216, y: 46, width: 4, height: 554))
  }

  @Test func addressModeMovesDownloadsToFooter() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(addressBar: true, dots: 0))
    #expect(view.headerHeight == 80)
    #expect(view.footerHeight == 41)
    #expect(view.indicator.isHidden && view.headerDownloads.isHidden)
    #expect(view.footerDownloads.frame == NSRect(x: 6, y: 600 - 5 - 34, width: 34, height: 34))
  }

  @Test func noFooterWithoutDotsOrFooterDownloads() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state(downloads: false, dots: 0))
    #expect(view.footerHeight == 0)
    #expect(view.headerDownloads.isHidden)
  }

  @Test func dotsCenterAndFollowThePager() {
    let view = SidebarChromeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    view.update(state())
    let info = view.describe()["dots"] as! [[String: Any]]
    let rects = info.map { $0["rect"] as! [Double] }
    #expect(rects[0] == [92, 564, 12, 28])
    view.setPagerPosition(0.5)
    let opacities = (view.describe()["dots"] as! [[String: Any]]).map { $0["opacity"] as! Double }
    #expect(abs(opacities[0] - 0.525) < 1e-6 && abs(opacities[1] - 0.525) < 1e-6 && abs(opacities[2] - 0.2) < 1e-6)
  }

  @Test func passesThroughBelowTheHeader() {
    let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
    let view = SidebarChromeView(frame: host.bounds)
    host.addSubview(view)
    view.update(state(downloads: false))
    #expect(view.hitTest(NSPoint(x: 20, y: 20)) === view)
    #expect(view.hitTest(NSPoint(x: 20, y: 300)) == nil)
    #expect(view.hitTest(NSPoint(x: 20, y: 590)) === view)
    #expect(view.hitTest(NSPoint(x: 218, y: 300)) === view.resize)
  }
}
