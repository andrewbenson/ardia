import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarGroupCardTests {
  private func state(_ titles: [String]) -> SidebarGroupCardState {
    let now = Date().timeIntervalSince1970 * 1000
    let rows = titles.enumerated().map { i, title in
      SidebarGroupCardState.Row(id: "t\(i)", title: title, url: "https://\(title.lowercased()).example/", usedAt: now - Double(i) * 120_000, favicon: nil, icon: nil, profileId: "p")
    }
    return SidebarGroupCardState(groupId: "g", rows: rows, anchor: [8, 100, 184, 34], windowHeight: 800, dark: true, theme: [:])
  }

  @Test func theHeightCountsUpToSevenRows() {
    let m = SidebarGroupCardMetrics.self
    #expect(m.height(0) == 44 + m.separator + 8 + 44)
    #expect(m.height(3) == 44 + m.separator + 8 + 3 * 44)
    #expect(m.height(20) == m.height(7))
  }

  @Test func itOpensRightOfTheRowAndStaysInTheWindow() {
    let m = SidebarGroupCardMetrics.self
    #expect(m.origin(anchor: CGRect(x: 8, y: 100, width: 184, height: 34), height: 200, windowHeight: 800) == CGPoint(x: 200, y: 94))
    #expect(m.origin(anchor: CGRect(x: 8, y: 700, width: 184, height: 34), height: 200, windowHeight: 800).y == 592)
  }

  @Test func searchRanksLikeRN() {
    let rows = state(["Mail", "Calendar", "Maps"]).rows
    #expect(SidebarGroupCardMetrics.matching("", rows).map(\.id) == ["t0", "t1", "t2"])
    #expect(SidebarGroupCardMetrics.matching("cal", rows).map(\.id) == ["t1"])
    #expect(SidebarGroupCardMetrics.matching("ma", rows).map(\.id).first == "t0")
  }

  @Test func agoReadsLikeRN() {
    let now = 1_000_000_000_000.0
    #expect(SidebarGroupCardMetrics.ago(now - 30_000, now: now) == "just now")
    #expect(SidebarGroupCardMetrics.ago(now - 60_000, now: now) == "1 minute ago")
    #expect(SidebarGroupCardMetrics.ago(now - 3 * 3_600_000, now: now) == "3 hours ago")
    #expect(SidebarGroupCardMetrics.ago(now - 86_400_000, now: now) == "yesterday")
    #expect(SidebarGroupCardMetrics.ago(now - 14 * 86_400_000, now: now) == "2 weeks ago")
  }

  @Test func arrowsMoveTheSelectionAndReturnChoosesIt() {
    let card = SidebarGroupCardView(favicons: SidebarFavicons())
    var events: [SidebarGroupCardEvent] = []
    card.onEvent = { events.append($0) }
    card.set(state(["A", "B", "C"]))
    card.layoutSubtreeIfNeeded()
    let text = NSTextView()
    let field = NSTextField()
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(events == [.choose("t2")])
    _ = card.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(events.last == .close)
  }
}
