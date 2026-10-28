import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct StripPeekTests {
  private func view() -> StripPeekView {
    let view = StripPeekView(frame: NSRect(x: 0, y: 0, width: 1200, height: 80))
    view.bandLeft = 78
    view.peek.schedule = { _, run in
      run()
      return nil
    }
    view.setEnabled(true)
    return view
  }

  @Test func thePanelSitsUnderTheBandAndSlidesFromAboveIt() {
    #expect(StripPeekMetrics.panel(windowWidth: 1200) == CGRect(x: 6, y: 4, width: 1188, height: 46))
    #expect(StripPeekMetrics.row(in: CGSize(width: 1188, height: 46)) == CGRect(x: 0, y: 2, width: 1188, height: 42))
    #expect(StripPeekMetrics.offset(0) == -54)
    #expect(StripPeekMetrics.offset(1) == 0)
  }

  @Test func theBandRunsFromTheTrafficLightsToThePanelsRightEdge() {
    #expect(StripPeekMetrics.holds(CGPoint(x: 80, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 40, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 1196, y: 2), windowWidth: 1200, bandLeft: 78))
    #expect(StripPeekMetrics.holds(CGPoint(x: 10, y: 40), windowWidth: 1200, bandLeft: 78))
    #expect(!StripPeekMetrics.holds(CGPoint(x: 10, y: 51), windowWidth: 1200, bandLeft: 78))
  }

  @Test func thePointerInTheBandSlidesThePanelInOverRNs180msOutCubic() {
    let view = view()
    view.pointer(at: CGPoint(x: 300, y: 2))
    #expect(view.live)
    view.step(by: 0.09)
    #expect(abs(view.slideValue - 0.875) < 1e-9)
    view.step(by: 0.09)
    #expect(view.slideValue == 1)
  }

  @Test func leavingThePanelSlidesItOutAndEndsTheLiveState() {
    let view = view()
    view.pointer(at: CGPoint(x: 300, y: 2))
    view.step(by: 0.2)
    view.pointer(at: CGPoint(x: 300, y: 30))
    #expect(view.live)
    view.pointer(at: CGPoint(x: 300, y: 70))
    view.step(by: 0.2)
    #expect(view.slideValue == 0)
    #expect(!view.live)
  }

  @Test func aHeldPeekStaysOutUntilRechecked() {
    let view = view()
    var held = true
    view.peek.held = { held }
    view.pointer(at: CGPoint(x: 300, y: 2))
    view.step(by: 0.2)
    view.pointer(at: nil)
    #expect(view.live)
    held = false
    view.peek.recheck()
    view.step(by: 0.2)
    #expect(!view.live)
  }
}
