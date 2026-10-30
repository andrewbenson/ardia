import AppKit
import Testing
@testable import SolaraUI

@MainActor
final class FakePage: TabPoolPage {
  let view: NSView
  var shownLog: [Bool] = []
  var shownIn: [NSView?] = []
  var retired = false
  var focused = 0
  init(_ view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))) { self.view = view }
  func setShown(_ shown: Bool) {
    shownLog.append(shown)
    shownIn.append(view.superview)
  }
  func focus() { focused += 1 }
  func retire() {
    retired = true
    view.removeFromSuperview()
  }
}

final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
struct TabViewPoolTests {
  @MainActor final class Rig {
    let slots = TabSlots()
    var made: [String: FakePage] = [:]
    var pending: [@MainActor () -> Void] = []
    var pool: TabViewPool!
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    let card = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let hiddenBox = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var pageView: @MainActor (String) -> NSView = { _ in NSView(frame: .zero) }

    init() {
      window.isReleasedWhenClosed = false
      hiddenBox.isHidden = true
      window.contentView!.addSubview(card)
      window.contentView!.addSubview(hiddenBox)
      pool = TabViewPool(slots: slots, make: { [unowned self] id, _ in
        let page = FakePage(self.pageView(id))
        self.made[id] = page
        return page
      }, schedule: { [unowned self] work in self.pending.append(work) })
      pool.hiddenContainer = { [unowned self] w in w == "w1" ? self.hiddenBox : nil }
    }

    func turn() {
      let work = pending
      pending = []
      work.forEach { $0() }
    }
  }

  func want(_ t: String, _ shown: TabViewWanted.Shown = .card, warm: Bool = false, frozen: Bool = false, identity: String = "") -> TabViewWanted {
    TabViewWanted(tabId: t, windowId: "w1", shown: shown, warm: warm, frozen: frozen, identity: identity)
  }

  @Test func aPageWhoseEngineOrProfileChangesIsMadeAgainInItsPlace() {
    let rig = Rig()
    var replaced: [(String, Bool)] = []
    rig.pool.onReplace = { id in replaced.append((id, rig.made[id]?.retired ?? true)) }
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a", identity: "chromium|default"), want("b", .none, identity: "chromium|default")])
    rig.turn()
    let first = rig.made["a"]!
    let other = rig.made["b"]!
    rig.pool.update([want("a", identity: "chromium|work"), want("b", .none, identity: "chromium|default")])
    rig.turn()
    let moved = rig.made["a"]!
    #expect(first.retired)
    #expect(moved !== first)
    #expect(moved.view.superview === rig.card)
    #expect(moved.shownLog.last == true)
    #expect(rig.pool.page("a") === moved)
    #expect(!other.retired && rig.made["b"] === other)
    rig.pool.update([want("a", identity: "chromium|default"), want("b", .none, identity: "chromium|default")])
    rig.turn()
    let back = rig.made["a"]!
    #expect(moved.retired && back !== moved && back !== first)
    #expect(back.view.superview === rig.card)
    rig.pool.update([want("a", identity: "webkit|default"), want("b", .none, identity: "chromium|default")])
    rig.turn()
    #expect(back.retired && rig.made["a"] !== back)
    let settled = rig.made["a"]!
    rig.pool.update([want("a", .none, identity: "webkit|default"), want("b", identity: "chromium|default")])
    rig.turn()
    rig.pool.update([want("a", .none), want("b", identity: "chromium|default")])
    rig.turn()
    #expect(!settled.retired && rig.made["a"] === settled, "an entry with no identity, such as a parked one, keeps its page")
    #expect(replaced.map(\.0) == ["a", "a", "a"])
    #expect(replaced.allSatisfy { !$0.1 }, "the replace hook runs before the old page retires")
  }

  @Test func reconcilesOncePerTurnHoweverManyChanges() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a")])
    rig.pool.update([want("a"), want("b", .none)])
    #expect(rig.pending.count == 1)
    rig.turn()
    #expect(rig.made.keys.sorted() == ["a", "b"])
    #expect(rig.made["a"]!.view.superview === rig.card)
  }

  @Test func aPageWithNoSlotSitsInTheHiddenContainerAndIsNeverShown() {
    let rig = Rig()
    rig.pool.update([want("a", .none, warm: false)])
    rig.turn()
    let page = rig.made["a"]!
    #expect(page.view.superview === rig.hiddenBox)
    #expect(page.view.isHiddenOrHasHiddenAncestor)
    #expect(!page.shownLog.contains(true))
  }

  @Test func aWarmPageWaitsBehindTheCardNotShown() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a"), want("b", .none, warm: true)])
    rig.turn()
    #expect(rig.card.subviews.first === rig.made["b"]!.view)
    #expect(rig.card.subviews.last === rig.made["a"]!.view)
    #expect(rig.made["b"]!.shownLog == [false] || rig.made["b"]!.shownLog.isEmpty)
    #expect(rig.made["a"]!.shownLog == [true])
  }

  @Test func pagesNeverCoverWhatTheShellPutsAboveThem() {
    let rig = Rig()
    let overlay = NSView(frame: rig.card.bounds)
    rig.card.addSubview(overlay)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a"), want("b", .none, warm: true)])
    rig.turn()
    #expect(rig.card.subviews.last === overlay)
    rig.pool.update([want("a", .none, warm: true), want("b")])
    rig.turn()
    #expect(rig.card.subviews.last === overlay)
    #expect(rig.card.subviews.map { ObjectIdentifier($0) } == [rig.made["a"]!.view, rig.made["b"]!.view, overlay].map { ObjectIdentifier($0) })
  }

  @Test func aFrozenPageIsAttachedButNotShown() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a", frozen: true)])
    rig.turn()
    #expect(rig.made["a"]!.view.superview === rig.card)
    #expect(!rig.made["a"]!.shownLog.contains(true))
  }

  @Test func aTabSwitchMovesPagesWithoutRecreatingThem() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a"), want("b", .none)])
    rig.turn()
    let a = rig.made["a"]!, b = rig.made["b"]!
    rig.pool.update([want("a", .none), want("b")])
    rig.turn()
    #expect(rig.made["a"] === a && rig.made["b"] === b)
    #expect(a.view.superview === rig.hiddenBox)
    #expect(b.view.superview === rig.card)
    #expect(a.shownLog.last == false && b.shownLog.last == true)
  }

  @Test func aPageGoingAwayIsHiddenWhileStillInItsSlot() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a"), want("b", .none)])
    rig.turn()
    let a = rig.made["a"]!
    rig.pool.update([want("a", .none), want("b")])
    rig.turn()
    #expect(a.shownLog.last == false)
    #expect(a.shownIn.last == rig.card)
    #expect(a.view.superview === rig.hiddenBox)
  }

  @Test func aSlotAppearingLaterReconcilesOnItsOwn() {
    let rig = Rig()
    rig.pool.update([want("a")])
    rig.turn()
    #expect(rig.made["a"]!.view.superview === rig.hiddenBox)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.turn()
    #expect(rig.made["a"]!.view.superview === rig.card)
  }

  @Test func paneSlotsTakeTheirOwnTabs() {
    let rig = Rig()
    let left = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300)), right = NSView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
    rig.card.addSubview(left)
    rig.card.addSubview(right)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.slots.set(.pane("w1", "a"), container: left)
    rig.slots.set(.pane("w1", "b"), container: right)
    rig.pool.update([want("a", .pane), want("b", .pane)])
    rig.turn()
    #expect(rig.made["a"]!.view.superview === left)
    #expect(rig.made["b"]!.view.superview === right)
    #expect(rig.made["a"]!.view.frame == left.bounds)
  }

  @Test func aDroppedTabIsRetired() {
    let rig = Rig()
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a")])
    rig.turn()
    rig.pool.update([])
    rig.turn()
    #expect(rig.made["a"]!.retired)
    #expect(rig.pool.page("a") == nil)
  }

  @Test func aWindowWithNoHiddenContainerUsesTheHiddenKeeper() {
    let rig = Rig()
    rig.pool.update([TabViewWanted(tabId: "a", windowId: "w2", shown: .none)])
    rig.turn()
    #expect(rig.made["a"]!.view.superview === rig.pool.keeper)
    #expect(rig.pool.keeper.isHidden)
  }

  @Test func movingTheFocusedPageInsideItsWindowKeepsFocus() {
    let rig = Rig()
    rig.pageView = { _ in FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) }
    let other = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    rig.window.contentView!.addSubview(other)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a")])
    rig.turn()
    let view = rig.made["a"]!.view
    #expect(rig.window.makeFirstResponder(view))
    rig.slots.set(.card("w1"), container: other)
    rig.turn()
    #expect(view.superview === other)
    #expect(rig.window.firstResponder === view)
  }

  @Test func aReplacedPageThatHadKeyboardFocusHandsItToItsReplacement() {
    let rig = Rig()
    rig.pageView = { _ in FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) }
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    rig.window.contentView!.addSubview(pane)
    rig.slots.set(.card("w1"), container: rig.card)
    rig.slots.set(.pane("w1", "b"), container: pane)
    rig.pool.update([want("a", identity: "webkit|default"), want("b", .pane, identity: "webkit|default")])
    rig.turn()
    let a = rig.made["a"]!, b = rig.made["b"]!
    #expect(rig.window.makeFirstResponder(a.view))
    rig.pool.update([want("a", identity: "chromium|work"), want("b", .pane, identity: "chromium|work")])
    rig.turn()
    #expect(a.retired && b.retired)
    #expect(rig.made["a"]!.focused == 1)
    #expect(rig.made["a"]!.view.superview === rig.card)
    #expect(rig.made["b"]!.focused == 0, "a page that didn't have focus doesn't take it")
  }

  @Test func placementsAreReportedAfterEachChange() {
    let rig = Rig()
    var reports: [[String: String]] = []
    rig.pool.onPlaced = { reports.append($0) }
    rig.slots.set(.card("w1"), container: rig.card)
    rig.pool.update([want("a"), want("b", .none)])
    rig.turn()
    #expect(reports == [["a": "card", "b": "hidden"]])
    rig.turn()
    #expect(reports.count == 1)
  }
}
