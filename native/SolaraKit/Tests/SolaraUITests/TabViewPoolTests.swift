import AppKit
import Testing
@testable import SolaraUI

@MainActor
final class FakePage: TabPoolPage {
  let view: NSView
  var shownLog: [Bool] = []
  var retired = false
  init(_ view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))) { self.view = view }
  func setShown(_ shown: Bool) { shownLog.append(shown) }
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

  func want(_ t: String, _ shown: TabViewWanted.Shown = .card, warm: Bool = false, frozen: Bool = false) -> TabViewWanted {
    TabViewWanted(tabId: t, windowId: "w1", shown: shown, warm: warm, frozen: frozen)
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
