import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarTabCardTests {
  private func state(title: String = "Example", host: String? = "example.com", sleeping: Bool = false, buttons: Int = 3) throws -> SidebarTabCardState {
    let actions = ["pin", "bookmark", "split", "pip", "back"].prefix(buttons).map { ["action": $0, "icon": "pin", "label": $0] }
    let value: [String: Any] = [
      "tabId": "a", "title": title, "host": host as Any? ?? NSNull(), "sleeping": sleeping, "buttons": actions,
      "anchor": [8, 100, 184, 34], "sidebarWidth": 200, "windowHeight": 800,
      "look": ["fill": "#262626", "border": "#404040", "primary": "rgba(255,255,255,0.86)", "secondary": "rgba(255,255,255,0.585)",
               "tertiary": "#FFFFFF59", "hover": "rgba(255,255,255,0.1)", "pressed": "rgba(255,255,255,0.18)", "shadowOpacity": 0.5],
    ]
    return try #require(SidebarTabCardState.decode(value))
  }

  @Test func aOneLineCardIsRNsHeight() throws {
    let card = SidebarTabCardView()
    card.set(try state())
    #expect(card.frame.size == NSSize(width: 200, height: 16.5 + 16 + 16 + 10 + 28 + 6))
  }

  @Test func aLongTitleWrapsToTwoLinesAndNoFurther() throws {
    let card = SidebarTabCardView()
    card.set(try state(title: String(repeating: "A very long page title ", count: 8), host: nil))
    #expect(card.frame.height == 16.5 + 32 + 10 + 28 + 6)
  }

  @Test func buttonsShareTheWidthAtRNsPitch() throws {
    let card = SidebarTabCardView()
    card.set(try state(buttons: 5))
    card.layoutSubtreeIfNeeded()
    let buttons = card.subviews.compactMap { $0 as? SidebarIconButton }
    #expect(buttons.count == 5)
    let pitch = min(49, 196.0 / 5)
    #expect(abs((buttons[1].frame.minX - buttons[0].frame.minX) - pitch) < 0.001)
    #expect(abs(buttons[0].frame.minX - ((200 - pitch * 5) / 2 + (pitch - 28) / 2)) < 0.001)
    #expect(buttons.map(\.frame.minY).allSatisfy { $0 == 16.5 + 32 + 10 })
  }

  @Test func theCardSitsAtTheSidebarEdgeCentredOnTheRowAndClamped() {
    let row = CGRect(x: 8, y: 100, width: 192, height: 34)
    #expect(SidebarTabCardMetrics.origin(anchor: row, sidebarWidth: 200, cardHeight: 92, windowHeight: 800) == CGPoint(x: 200.5, y: 117 - 46))
    let tile = CGRect(x: 8, y: 10, width: 40, height: 40)
    #expect(SidebarTabCardMetrics.origin(anchor: tile, sidebarWidth: 200, cardHeight: 92, windowHeight: 800) == CGPoint(x: 200.5, y: 8))
    let low = CGRect(x: 8, y: 780, width: 192, height: 34)
    #expect(SidebarTabCardMetrics.origin(anchor: low, sidebarWidth: 200, cardHeight: 92, windowHeight: 800).y == 700)
  }

  @Test func pressingAButtonReportsItsAction() throws {
    let card = SidebarTabCardView()
    var pressed: [String] = []
    card.onAction = { pressed.append($0) }
    card.set(try state(buttons: 2))
    let buttons = card.subviews.compactMap { $0 as? SidebarIconButton }
    buttons[1].onPress?()
    #expect(pressed == ["bookmark"])
    #expect(buttons[1].accessibilityLabel() == "bookmark")
  }
}
