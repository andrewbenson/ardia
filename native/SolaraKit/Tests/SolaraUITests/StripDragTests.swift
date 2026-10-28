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

@Suite struct StripDockCrossTests {
  private let gap = StripMetrics.gap
  private let top = StripDragGeometry((0..<3).map { StripDragSlot(tabIds: ["t\($0)"], width: 173) }, gap: StripMetrics.gap)
  private let dock = StripDragGeometry(["p1", "p2"].map { StripDragSlot(tabIds: [$0], width: StripMetrics.pinnedCell) }, gap: StripMetrics.pinnedSpacing)
  private var dockLeft: CGFloat { -(StripMetrics.dockWidth(2) + StripMetrics.dockGap) }

  @Test func theDockShrinksByACellOrByItsLastCellAndGap() {
    #expect(StripLayout.dockShrink(2) == 36)
    #expect(StripLayout.dockShrink(1) == 38.5)
  }

  @Test func slotStartIsALeftEdgeOrPastTheLastSlot() {
    #expect(StripLayout.slotStart(top, 1, gap: gap) == 177)
    #expect(StripLayout.slotStart(top, 3, gap: gap) == 531)
    #expect(StripLayout.slotStart(StripDragGeometry([], gap: gap), 0, gap: gap) == 0)
  }

  @Test func dockCellLeftExtendsPastTheLastCell() {
    #expect(StripLayout.dockCellLeft(dock, 1) == 36)
    #expect(StripLayout.dockCellLeft(dock, 2) == 72)
    #expect(StripLayout.dockCellLeft(StripDragGeometry([], gap: 2), 0) == 0)
  }

  @Test func aTabCrossesIntoTheDockOnlyPastItsGap() {
    #expect(StripLayout.tabInIndex(top: top, dock: dock, dockLeft: dockLeft, from: 0, dx: -4, grab: 86.5) == nil)
    #expect(StripLayout.tabInIndex(top: top, dock: dock, dockLeft: dockLeft, from: 0, dx: -74, grab: 86.5) == 2)
    #expect(StripLayout.tabInIndex(top: top, dock: dock, dockLeft: dockLeft, from: 0, dx: -140, grab: 86.5) == 0)
    #expect(StripLayout.tabInIndex(top: top, dock: dock, dockLeft: dockLeft, from: 1, dx: -286.5, grab: 86.5) == 1)
  }

  @Test func aTileCrossesOutPastTheDockAndLandsBetweenTabs() {
    #expect(StripLayout.pinOutIndex(top: top, dock: dock, dockLeft: dockLeft, from: 1, dx: 20) == nil)
    #expect(StripLayout.pinOutIndex(top: top, dock: dock, dockLeft: dockLeft, from: 1, dx: 40) == 0)
    #expect(StripLayout.pinOutIndex(top: top, dock: dock, dockLeft: dockLeft, from: 0, dx: 74.5 + 36 + 60) == 1)
  }

  @Test func anIncomingTabOpensAGapAtTheNearestSlotEdgePastPinnedGroups() {
    #expect(StripLayout.incomingIndex(top, x: 80) { _ in false } == 0)
    #expect(StripLayout.incomingIndex(top, x: 90) { _ in false } == 1)
    #expect(StripLayout.incomingIndex(top, x: 600) { _ in false } == 3)
    #expect(StripLayout.incomingIndex(top, x: 10) { $0 == "t0" || $0 == "t1" } == 2)
  }

  @Test func anOpenGapMovesEverySlotFromItOnByAChipAndAGap() {
    let rooms = [0, 1, 0, 0.5]
    #expect(StripLayout.incomingShift(rooms, through: 0, chip: 173, gap: gap) == 0)
    #expect(StripLayout.incomingShift(rooms, through: 2, chip: 173, gap: gap) == 177)
    #expect(StripLayout.incomingShift(rooms, through: 3, chip: 173, gap: gap) == 265.5)
  }

  @Test func theHeldTileStopsAtTheDockEnd() {
    #expect(StripLayout.tileHold(dx: -50, limit: -20) == 0)
    #expect(StripLayout.tileHold(dx: 10, limit: -20) == -30)
  }
}

@Suite struct StripDragMotionTests {
  @Test func aDragSpringStartsItsClockWhenStartedNotOnTheNextFrame() {
    var started = StripSpringValue(0)
    started.animate(to: -127, .slide, at: 1)
    started.step(now: 1 + 1.0 / 60)
    var deferred = StripSpringValue(0)
    deferred.animate(to: -127, .slide)
    deferred.step(now: 1)
    deferred.step(now: 1 + 1.0 / 60)
    #expect(abs(started.value - deferred.value) < 1e-9)
    #expect(abs(started.value - -56.1) < 0.2)
  }
}
