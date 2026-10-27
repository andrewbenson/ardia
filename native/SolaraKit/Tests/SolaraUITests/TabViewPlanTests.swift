import Testing
@testable import SolaraUI

struct TabViewPlanTests {
  let w1 = "w1", w2 = "w2"
  func key(_ w: String, _ t: String) -> TabSlotKey { TabSlotKey(windowId: w, tabId: t) }

  @Test func aShownTabIsCreatedAttachedAndMadeVisible() {
    let ops = TabViewPlan.plan(wanted: [TabViewWanted(tabId: "a", windowId: w1)], slots: [key(w1, "a")], current: [:], visible: [:])
    #expect(ops == [.create("a"), .attach("a", key(w1, "a")), .visible("a", true)])
  }

  @Test func aTabWithoutASlotParksHiddenUnlessWarm() {
    let ops = TabViewPlan.plan(wanted: [TabViewWanted(tabId: "a", windowId: w1), TabViewWanted(tabId: "m", windowId: w1, warm: true)], slots: [], current: [:], visible: [:])
    #expect(ops == [.create("a"), .create("m"), .visible("a", false), .visible("m", true)])
  }

  @Test func aSwitchParksTheOldTabBeforeAttachingTheNewOne() {
    let ops = TabViewPlan.plan(
      wanted: [TabViewWanted(tabId: "a", windowId: w1), TabViewWanted(tabId: "b", windowId: w1)], slots: [key(w1, "b")],
      current: ["a": .slot(key(w1, "a")), "b": .parked], visible: ["a": true, "b": false])
    #expect(ops == [.park("a"), .attach("b", key(w1, "b")), .visible("a", false), .visible("b", true)])
  }

  @Test func aCrossWindowMoveReparentsWithoutRecreating() {
    let ops = TabViewPlan.plan(wanted: [TabViewWanted(tabId: "a", windowId: w2)], slots: [key(w2, "a")], current: ["a": .slot(key(w1, "a"))], visible: ["a": true])
    #expect(ops == [.attach("a", key(w2, "a"))])
  }

  @Test func aSlotInAnotherWindowIsNotUsed() {
    let ops = TabViewPlan.plan(wanted: [TabViewWanted(tabId: "a", windowId: w1)], slots: [key(w2, "a")], current: ["a": .slot(key(w2, "a"))], visible: ["a": true])
    #expect(ops == [.park("a"), .visible("a", false)])
  }

  @Test func aClosedTabIsDroppedFirst() {
    let ops = TabViewPlan.plan(wanted: [TabViewWanted(tabId: "b", windowId: w1)], slots: [key(w1, "b")], current: ["a": .slot(key(w1, "a")), "b": .slot(key(w1, "b"))], visible: ["a": true, "b": true])
    #expect(ops == [.drop("a")])
  }

  @Test func applyingAPlanMakesTheNextPlanEmpty() {
    let wanted = [TabViewWanted(tabId: "a", windowId: w1), TabViewWanted(tabId: "b", windowId: w1, warm: true), TabViewWanted(tabId: "c", windowId: w2)]
    let slots: Set = [key(w1, "a"), key(w2, "c")]
    let first = TabViewPlan.plan(wanted: wanted, slots: slots, current: ["z": .parked, "b": .slot(key(w1, "b"))], visible: ["z": false, "b": true])
    let after = TabViewPlan.apply(first, to: ["z": .parked, "b": .slot(key(w1, "b"))], visible: ["z": false, "b": true])
    #expect(TabViewPlan.plan(wanted: wanted, slots: slots, current: after.current, visible: after.visible).isEmpty)
  }

  @Test func everyViewIsCreatedAtMostOnceAndAttachedAtMostOnce() {
    let wanted = (0..<20).map { TabViewWanted(tabId: "t\($0)", windowId: $0 % 2 == 0 ? "w1" : "w2", warm: $0 % 5 == 0) }
    let slots = Set(wanted.filter { Int($0.tabId.dropFirst())! % 3 != 0 }.map { key($0.windowId, $0.tabId) })
    let ops = TabViewPlan.plan(wanted: wanted, slots: slots, current: [:], visible: [:])
    var created: [String: Int] = [:], attached: [String: Int] = [:]
    for op in ops {
      if case .create(let id) = op { created[id, default: 0] += 1 }
      if case .attach(let id, _) = op { attached[id, default: 0] += 1 }
    }
    #expect(created.values.allSatisfy { $0 == 1 } && created.count == 20)
    #expect(attached.values.allSatisfy { $0 == 1 } && attached.count == slots.count)
  }
}
