import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct DownloadsPanelTests {
  private func list(rows: Int = 0) -> DownloadsListState {
    DownloadsListState(
      rows: (0..<rows).map { DownloadRowState(id: "d\($0)", filename: "file\($0).zip", path: "/tmp/file\($0).zip", state: "finished", received: 10, total: 10, speed: 0, paused: false) },
      clearable: rows > 0, listMax: 400, dark: false, theme: [:])
  }

  private func panel(_ placement: DownloadsPanelPlacement, closing: Bool = false) async throws -> DownloadsPanelView {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    let v = DownloadsPanelView(frame: host.bounds)
    host.addSubview(v)
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: closing))
    for _ in 0..<20 where v.cardFrame == nil {
      try await Task.sleep(for: .milliseconds(10))
      v.layoutSubtreeIfNeeded()
    }
    return v
  }

  @Test func itHangsBelowItsButtonWithTheArrowOnTop() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .top, arrowX: 30))
    let card = try #require(v.cardFrame)
    #expect(card.minX == 40 && card.minY == 60 && card.width == 300)
    #expect(v.list.frame.minY == DownloadsPanelMetrics.arrowHeight)
    #expect(card.height == v.list.frame.height + DownloadsPanelMetrics.arrowHeight)
  }

  @Test func itStandsOnItsBottomOffsetWhenItOpensUpward() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 10, bottom: 50, arrow: .bottom, arrowX: 20))
    let card = try #require(v.cardFrame)
    #expect(abs(card.maxY - (700 - 50)) < 0.01)
    #expect(v.list.frame.minY == 0)
  }

  @Test func outsideClicksAreCaughtAndInsideClicksReachTheList() async throws {
    let v = try await panel(DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .none, arrowX: 150))
    let card = try #require(v.cardFrame)
    #expect(v.hitTest(NSPoint(x: 900, y: 50)) === v)
    let inside = v.hitTest(NSPoint(x: card.midX, y: 700 - card.midY))
    #expect(inside != nil && inside !== v)
    v.close()
    #expect(v.isClosing && v.hitTest(NSPoint(x: 900, y: 50)) == nil)
  }

  @Test func closingReportsClosedAndReopeningCancelsIt() async throws {
    let placement = DownloadsPanelPlacement(width: 300, left: 40, top: 60, arrow: .top, arrowX: 30)
    let v = try await panel(placement)
    var closed = 0
    v.onClosed = { closed += 1 }
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: true))
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: false))
    try await Task.sleep(for: .milliseconds(200))
    #expect(closed == 0 && !v.isClosing)
    v.update(DownloadsPanelState(list: list(rows: 2), placement: placement, closing: true))
    try await Task.sleep(for: .milliseconds(200))
    #expect(closed == 1)
  }
}
