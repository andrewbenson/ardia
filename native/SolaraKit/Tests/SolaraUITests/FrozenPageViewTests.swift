import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct FrozenPageViewTests {
  @Test func theWashFollowsTheAppearanceLikeRN() {
    let view = FrozenPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    #expect(view.washColor == NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4))
    view.dark = true
    #expect(view.washColor == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
    #expect(view.washLayerColor == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25).cgColor)
  }

  @Test func aPictureReportsPaintedOnce() {
    let view = FrozenPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    var painted = 0
    view.onPainted = { painted += 1 }
    let image = NSImage(size: NSSize(width: 10, height: 10))
    view.show(image)
    view.show(image)
    #expect(painted == 1)
    #expect(view.pictureContents != nil)
    view.show(nil)
    #expect(view.pictureContents == nil)
    #expect(painted == 1)
  }

  @Test func pressingBringsTheTabBack() {
    let view = FrozenPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    var pressed = 0
    view.onPress = { pressed += 1 }
    #expect(view.accessibilityPerformPress())
    #expect(pressed == 1)
    #expect(view.accessibilityLabel() == "Bring this tab to this window")
  }
}
