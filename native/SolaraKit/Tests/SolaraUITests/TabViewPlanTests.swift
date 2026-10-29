import AppKit
import Testing
@testable import SolaraUI

struct TabViewPlanTests {
  func want(_ t: String, _ w: String = "w1", _ shown: TabViewWanted.Shown = .card, warm: Bool = false, frozen: Bool = false) -> TabViewWanted {
    TabViewWanted(tabId: t, windowId: w, shown: shown, warm: warm, frozen: frozen)
  }

  @Test func aShownTabIsCreatedInItsWindowThenAttachedToTheCard() {
    let ops = TabViewPlan.plan(wanted: [want("a")], slots: [.card("w1")], current: [:], visible: [:])
    #expect(ops == [.create("a", "w1"), .attach("a", .card("w1"), adopt: false), .visible("a", true)])
  }

  @Test func peekBeatsPaneBeatsCard() {
    let slots: Set<TabSlotKey> = [.card("w1"), .pane("w1", "a"), .peek("w1")]
    #expect(TabViewPlan.slot(for: want("a", "w1", .peek), in: slots) == .peek("w1"))
    #expect(TabViewPlan.slot(for: want("a", "w1", .pane), in: slots) == .pane("w1", "a"))
    #expect(TabViewPlan.slot(for: want("a", "w1", .card), in: slots) == .card("w1"))
    #expect(TabViewPlan.slot(for: want("a", "w1", .pane), in: [.card("w1")]) == .card("w1"))
  }

  @Test func aTabSwitchIsOneReparentInsideTheWindowsCard() {
    let ops = TabViewPlan.plan(wanted: [want("a", "w1", .none), want("b")], slots: [.card("w1")], current: ["a": .slot(.card("w1")), "b": .hidden("w1")], visible: ["a": true, "b": false])
    #expect(ops == [.hide("a", "w1", adopt: false), .attach("b", .card("w1"), adopt: false), .visible("a", false), .visible("b", true)])
  }

  @Test func aMissingSlotLeavesTheViewHiddenInItsWindow() {
    let ops = TabViewPlan.plan(wanted: [want("a", "w1", .pane)], slots: [], current: ["a": .slot(.pane("w1", "a"))], visible: ["a": true])
    #expect(ops == [.hide("a", "w1", adopt: false), .visible("a", false)])
  }

  @Test func aTabWithNoSlotIsNeverVisibleEvenWhenWarm() {
    let ops = TabViewPlan.plan(wanted: [want("m", "w1", .none, warm: true), want("h", "w1", .none)], slots: [], current: ["m": .hidden("w1"), "h": .slot(.card("w1"))], visible: ["m": true, "h": true])
    #expect(ops == [.hide("h", "w1", adopt: false), .visible("h", false), .visible("m", false)])
  }

  @Test func warmNeighboursWaitBehindTheCardNotVisible() {
    let ops = TabViewPlan.plan(wanted: [want("a"), want("m", "w1", .none, warm: true)], slots: [.card("w1")], current: ["a": .slot(.card("w1")), "m": .hidden("w1")], visible: ["a": true, "m": false])
    #expect(ops == [.behind("m", .card("w1"), adopt: false)])
  }

  @Test func aFrozenTabIsNeverMadeVisible() {
    let ops = TabViewPlan.plan(wanted: [want("f", "w1", .card, frozen: true)], slots: [.card("w1")], current: ["f": .hidden("w1")], visible: ["f": false])
    #expect(ops == [.attach("f", .card("w1"), adopt: false)])
  }

  @Test func aCrossWindowMoveAdoptsWithoutRecreating() {
    let ops = TabViewPlan.plan(wanted: [want("a", "w2")], slots: [.card("w2"), .card("w1")], current: ["a": .slot(.card("w1"))], visible: ["a": true])
    #expect(ops == [.attach("a", .card("w2"), adopt: true)])
  }

  @Test func slotsOfOtherWindowsAreIgnored() {
    let ops = TabViewPlan.plan(wanted: [want("a", "w2", .pane)], slots: [.pane("w1", "a")], current: ["a": .slot(.pane("w1", "a"))], visible: ["a": true])
    #expect(ops == [.hide("a", "w2", adopt: true), .visible("a", false)])
  }

  @Test func aTabMovedToAWindowWithoutAShellParksThenDropsAtTheLimit() {
    var park = TabViewPark()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let moving = [want("a", "w2")]
    let parked = park.park(moving, now: start)
    #expect(parked == [want("a", "w2", .none)])
    #expect(TabViewPlan.plan(wanted: parked, slots: [.card("w1")], current: ["a": .slot(.card("w1"))], visible: ["a": true])
      == [.hide("a", "w2", adopt: true), .visible("a", false)])
    #expect(park.park(moving, now: start.addingTimeInterval(1.9)) == [want("a", "w2", .none)])
    let expired = park.park(moving, now: start.addingTimeInterval(2))
    #expect(expired.isEmpty)
    #expect(TabViewPlan.plan(wanted: expired, slots: [.card("w1")], current: ["a": .hidden("w2")], visible: ["a": false]) == [.drop("a")])
  }

  @Test func aParkedTabWhoseShellArrivesInTimeAttachesWithoutRecreating() {
    var park = TabViewPark()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    _ = park.park([want("a", "w2")], now: start)
    #expect(park.park([], now: start.addingTimeInterval(1.9)).isEmpty)
    #expect(park.since.isEmpty)
    #expect(TabViewPlan.plan(wanted: [want("a", "w2")], slots: [.card("w2")], current: ["a": .hidden("w2")], visible: ["a": false])
      == [.attach("a", .card("w2"), adopt: false), .visible("a", true)])
  }

  @Test func aTabParkedAgainLaterGetsAFreshLimit() {
    var park = TabViewPark()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    _ = park.park([want("a", "w2")], now: start)
    _ = park.park([], now: start.addingTimeInterval(1))
    #expect(park.park([want("a", "w3")], now: start.addingTimeInterval(2.5)) == [want("a", "w3", .none)])
  }

  @Test func theNextRecheckIsTheEarliestUnexpiredLimit() {
    var park = TabViewPark()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    _ = park.park([want("a", "w2")], now: start)
    _ = park.park([want("a", "w2"), want("b", "w2")], now: start.addingTimeInterval(1.5))
    #expect(park.nextExpiry(after: start.addingTimeInterval(1.5)) == start.addingTimeInterval(2))
    #expect(park.nextExpiry(after: start.addingTimeInterval(2)) == start.addingTimeInterval(3.5))
    #expect(park.nextExpiry(after: start.addingTimeInterval(3.5)) == nil)
  }

  @Test func oneSlotHoldsOneTab() {
    let ops = TabViewPlan.plan(wanted: [want("a"), want("b")], slots: [.card("w1")], current: [:], visible: [:])
    #expect(ops.filter { if case .attach = $0 { return true } else { return false } } == [.attach("a", .card("w1"), adopt: false)])
  }

  @Test func closedTabsAreDroppedFirst() {
    let ops = TabViewPlan.plan(wanted: [want("b")], slots: [.card("w1")], current: ["a": .hidden("w1"), "b": .slot(.card("w1"))], visible: ["a": false, "b": true])
    #expect(ops == [.drop("a")])
  }

  @Test func applyingAPlanMakesTheNextOneEmpty() {
    let wanted = [want("a"), want("b", "w1", .none, warm: true), want("c", "w2", .pane), want("d", "w2", .peek), want("e", "w1", .none, frozen: true)]
    let slots: Set<TabSlotKey> = [.card("w1"), .pane("w2", "c"), .peek("w2")]
    let start: [String: TabViewPlace] = ["z": .hidden("w1"), "b": .slot(.card("w1")), "e": .slot(.card("w1"))]
    let first = TabViewPlan.plan(wanted: wanted, slots: slots, current: start, visible: ["z": false, "b": true, "e": false])
    let after = TabViewPlan.apply(first, to: start, visible: ["z": false, "b": true, "e": false])
    #expect(TabViewPlan.plan(wanted: wanted, slots: slots, current: after.current, visible: after.visible).isEmpty)
  }
}

@MainActor
struct TabSlotsTests {
  @Test func removeIsANoOpForAContainerThatIsNoLongerRegistered() {
    let slots = TabSlots()
    let first = NSView(), second = NSView()
    slots.set(.pane("w1", "a"), container: first)
    slots.set(.pane("w1", "a"), container: second)
    slots.remove(.pane("w1", "a"), container: first)
    #expect(slots.container(for: .pane("w1", "a")) === second)
    slots.remove(.pane("w1", "a"), container: second)
    #expect(slots.container(for: .pane("w1", "a")) == nil)
  }

  @Test func keysAreScopedToAWindow() {
    let slots = TabSlots()
    slots.set(.card("w1"), container: NSView())
    slots.set(.peek("w2"), container: NSView())
    #expect(slots.keys(in: "w1") == [.card("w1")])
    #expect(slots.keys == [.card("w1"), .peek("w2")])
  }
}
