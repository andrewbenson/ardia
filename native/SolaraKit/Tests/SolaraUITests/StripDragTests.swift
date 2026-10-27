import AppKit
import Testing

@testable import SolaraUI

@Suite struct StripDragTests {
  private let slots = [["t1"], ["t2"], ["g1", "g2"], ["t4"]]

  @Test func anchorIsTheFirstStayingTabAtTheDropIndex() {
    #expect(StripDrop.slotAnchor(slots, from: 0, to: 2, moving: ["t1"]) { _ in nil } == "t4")
    #expect(StripDrop.slotAnchor(slots, from: 3, to: 0, moving: ["t4"]) { _ in nil } == "t1")
    #expect(StripDrop.slotAnchor(slots, from: 0, to: 1, moving: ["t1"]) { _ in nil } == "g1")
  }

  @Test func anchorAtTheEndIsTheTabAfterTheLane() {
    #expect(StripDrop.slotAnchor(slots, from: 0, to: 3, moving: ["t1"]) { $0 == "t4" ? "next" : nil } == "next")
    #expect(StripDrop.slotAnchor([["p1"], ["p2"]], from: 0, to: 1, moving: ["p1"]) { $0 == "p2" ? "t1" : nil } == "t1")
  }

  @Test func anchorSkipsMovingTabs() {
    #expect(StripDrop.slotAnchor(slots, from: 0, to: 1, moving: ["t1", "g1"]) { _ in nil } == "g2")
  }

  @Test func axisThresholdsMatchTheResponder() {
    let view = NSView()
    let x = StripDragSource(view: view, lane: .top, from: 0, width: 0, gap: 0, axis: .x)
    let y = StripDragSource(view: view, lane: .top, from: -1, width: 0, gap: 0, axis: .y)
    let any = StripDragSource(view: view, lane: .top, from: 0, width: 0, gap: 0)
    #expect(!x.claims(CGPoint(x: 4, y: 20)) && x.claims(CGPoint(x: 4.5, y: 0)))
    #expect(!y.claims(CGPoint(x: 0, y: 6)) && y.claims(CGPoint(x: 6, y: 7)) && !y.claims(CGPoint(x: 8, y: 7)))
    #expect(any.claims(CGPoint(x: 0, y: 6.5)) && !any.claims(CGPoint(x: 4, y: 6)))
  }

  @Test func liftEasesOutCubically() {
    var lift = StripTimedValue(0)
    lift.animate(to: 1, duration: 0.15, easing: .cubic)
    lift.step(now: 1)
    lift.step(now: 1.075)
    #expect(abs(lift.value - 0.875) < 1e-9)
    lift.step(now: 1.2)
    #expect(lift.value == 1 && !lift.running)
  }
}
