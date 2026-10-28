import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct SelectionBarTests {
  private func state(top: Double, bottom: Double, center: Double, key: String = "k") -> SelectionBarState {
    SelectionBarState(key: key, top: top, bottom: bottom, center: center, dark: false, icon: "#000000A6", textPrimary: "#000000D9", tooltip: "Search Google", label: "Search Google")
  }

  private func view(_ s: SelectionBarState?) -> SelectionBarView {
    let v = SelectionBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    v.update(s)
    return v
  }

  @Test func itSitsAboveTheSelectionWhenThereIsRoom() {
    let v = view(state(top: 200, bottom: 220, center: 400))
    let f = try! #require(v.barFrame)
    #expect(v.above && f.minY == 200 - 6 - 32 && f.height == 32)
    #expect(abs(f.midX - 400) <= 0.25)
    #expect(f.width > 60 && f.width < 100)
  }

  @Test func itDropsBelowNearTheTopAndClampsToTheEdges() {
    let v = view(state(top: 20, bottom: 40, center: 2))
    let f = try! #require(v.barFrame)
    #expect(!v.above && f.minY == 46 && f.minX == 8)
    v.update(state(top: 580, bottom: 640, center: 799))
    let g = try! #require(v.barFrame)
    #expect(g.minY == 580 - 38 && abs(g.maxX - 792) < 0.01)
  }

  @Test func itStaysAboveTheBottomEdgeAndHidesOffThePage() {
    let v = view(state(top: 30, bottom: 590, center: 400))
    #expect(abs((v.barFrame?.minY ?? 0) - 564) < 0.01)
    v.update(state(top: 650, bottom: 700, center: 400))
    #expect(v.barFrame == nil && v.buttonFrame == nil)
    v.update(state(top: -80, bottom: -10, center: 400))
    #expect(v.barFrame == nil)
  }

  @Test func onlyTheBarTakesClicks() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let v = view(state(top: 200, bottom: 220, center: 400))
    host.addSubview(v)
    v.frame = host.bounds
    let f = v.barFrame!
    #expect(v.hitTest(NSPoint(x: f.midX, y: 600 - f.midY)) != nil)
    #expect(v.hitTest(NSPoint(x: 10, y: 590)) == nil)
  }
}
