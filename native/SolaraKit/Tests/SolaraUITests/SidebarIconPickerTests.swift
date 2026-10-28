import AppKit
import Testing
@testable import SolaraUI

@MainActor
@Suite struct SidebarIconPickerTests {
  func state(kind: String = "tab", current: String? = nil, emoji: Int = 48) -> SidebarIconPickerState {
    SidebarIconPickerState(
      id: "t3", kind: kind, current: current, anchor: [6, 181, 178, 34], sidebarWidth: 240, dark: true, shadowOpacity: 0.5,
      theme: ["panel": "#262425", "pickerCellHover": "rgba(255,255,255,0.25)"],
      emoji: (0..<emoji).map { ["e\($0)", $0 == 0 ? "star favorite" : "word\($0)"] },
      symbols: ["star", "heart", "star.circle", "bookmark"])
  }

  @Test func theGridFitsSevenColumnsBecauseTheBorderAndPaddingLeave239Points() {
    #expect(SidebarIconPickerMetrics.inner == 239)
    #expect(SidebarIconPickerMetrics.columns == 7)
  }

  @Test func itSitsBesideTheAnchorRowAndStaysInsideTheWindowEdge() {
    #expect(SidebarIconPickerMetrics.origin(anchor: CGRect(x: 6, y: 181, width: 178, height: 34), sidebarWidth: 240) == CGPoint(x: 190, y: 173))
    #expect(SidebarIconPickerMetrics.origin(anchor: CGRect(x: 6, y: 4, width: 300, height: 34), sidebarWidth: 240) == CGPoint(x: 246, y: 8))
    #expect(SidebarIconPickerMetrics.origin(anchor: nil, sidebarWidth: 240) == CGPoint(x: 246, y: 52))
  }

  @Test func searchMatchesEmojiWordsAndSymbolNames() {
    let s = state()
    #expect(SidebarIconPickerMetrics.items(s, tab: .emoji, query: " Star ") == ["e0"])
    #expect(SidebarIconPickerMetrics.items(s, tab: .symbols, query: "star") == ["symbol:star", "symbol:star.circle"])
    #expect(SidebarIconPickerMetrics.items(s, tab: .emoji, query: "").count == 48)
  }

  @Test func theHeightCapsTheGridAtSixRowsAndAddsTheFooterWhenThereIsSomethingToReset() {
    let view = SidebarIconPickerView()
    view.set(state())
    #expect(view.panelHeight == 231)
    view.set(state(kind: "group"))
    #expect(view.panelHeight == 265)
    view.set(state(emoji: 7))
    #expect(view.panelHeight == 81)
  }

  @Test func aSymbolIconOpensOnTheIconsTab() {
    let view = SidebarIconPickerView()
    view.set(state(current: "symbol:star"))
    #expect(view.tab == .symbols)
    #expect(view.items.first == "symbol:star")
  }

  @Test func returnChoosesTheFirstMatchAndEscapeCloses() {
    let view = SidebarIconPickerView()
    var events: [SidebarIconPickerView.Event] = []
    view.onEvent = { events.append($0) }
    view.set(state())
    let editor = NSTextView()
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    _ = view.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(events == [.choose("e0"), .close])
  }
}
