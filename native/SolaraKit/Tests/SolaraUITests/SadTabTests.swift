import AppKit
import Testing

@testable import SolaraUI

private func state(_ mode: String?) -> SadTabState {
  let m = mode.map { "\"\($0)\"" } ?? "null"
  let json = ##"{"mode":\##(m),"dark":true,"textPrimary":"#FFFFFF","textSecondary":"#FFFFFF99","panel":"#2A2729","panelBorder":"rgba(255,255,255,0.1)","panelShadowOpacity":0.3,"goButton":"#F2E8EF","goButtonText":"#1B1618"}"##
  return SadTabState.decode(json)!
}

@MainActor
@Suite struct SadTabTests {
  private func view(_ mode: String?) -> SadTabView {
    let view = SadTabView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.update(state(mode))
    return view
  }

  @Test func nothingShowsAndNothingIsHitWithoutAMode() {
    let v = view(nil)
    #expect(v.isHidden)
    #expect(v.hitTest(NSPoint(x: 400, y: 300)) == nil)
    #expect(v.controlFrames.isEmpty)
  }

  @Test func aCrashedTabCentresItsReloadButtonAndCoversThePane() {
    let v = view("crashed")
    #expect(!v.isHidden)
    let reload = try! #require(v.controlFrames["Reload"])
    #expect(reload.height == 28)
    #expect(abs(reload.midX - 400) <= 0.5)
    #expect(reload.minY > 300 && reload.maxY < 400)
    #expect(v.hitTest(NSPoint(x: 10, y: 10)) != nil)
  }

  @Test func anUnresponsivePageShowsTheCardWithItsButtonsAtTheRight() {
    let v = view("unresponsive")
    let frames = v.controlFrames
    let wait = try! #require(frames["Wait"])
    let exit = try! #require(frames["Exit Page"])
    #expect(abs(wait.maxX - 542) < 0.01)
    #expect(abs(exit.maxX - (wait.minX - 8)) < 0.01)
    #expect(exit.minY == wait.minY)
  }

  @Test func eachButtonSendsItsAction() {
    let v = view("unresponsive")
    var got: [SadTabAction] = []
    v.onAction = { got.append($0) }
    func press(_ name: String) {
      func find(_ view: NSView) -> PromptPressable? {
        if let b = view as? PromptPressable, b.accessibilityLabel() == name { return b }
        return view.subviews.lazy.compactMap(find).first
      }
      find(v)?.onPress?()
    }
    press("Exit Page")
    press("Wait")
    #expect(got == [.exit, .wait])
  }
}
