import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct StripControlsTests {
  @Test func theIndicatorShowsWithTwoProfilesOrIncognito() {
    #expect(!StripControlsLayout.indicator(textWidth: 60, incognito: false, profiles: 1).shown)
    #expect(StripControlsLayout.indicator(textWidth: 60, incognito: true, profiles: 1).shown)
    #expect(StripControlsLayout.indicator(textWidth: 60, incognito: false, profiles: 2) == StripIndicatorLayout(shown: true, showName: true, width: 78))
  }

  @Test func aLongNameIsCutAtTheRoomAndANarrowRoomShowsTheIcon() {
    #expect(StripControlsLayout.indicator(textWidth: 300, incognito: false, profiles: 2).width == 140)
    #expect(StripControlsLayout.indicator(textWidth: 300, room: 60, incognito: false, profiles: 2) == StripIndicatorLayout(shown: true, showName: false, width: 32))
    #expect(!StripControlsLayout.indicator(textWidth: 300, room: 20, incognito: false, profiles: 2).shown)
  }

  @Test func theControlsAreTheIndicatorAGapAndTheDownloadsBox() {
    #expect(StripControlsLayout.width(indicator: 0) == 34)
    #expect(StripControlsLayout.width(indicator: 78) == 114)
  }

  @Test func theDownloadsButtonSitsAtTheRightAndShowsOpenAsPressed() {
    let view = StripControlsView(frame: .zero)
    var actions: [StripControlAction] = []
    view.onAction = { actions.append($0) }
    view.update(StripControlsState(title: "Work", incognito: false, profiles: 2, nameColor: "#FF0000", downloadsOpen: true, downloadsTooltip: "Downloads"), theme: [:])
    #expect(view.downloads.frame.maxX == view.width)
    #expect(view.downloads.active)
    #expect(view.downloads.toolTip == nil)
    view.downloads.onPress?()
    view.indicator.press(SidebarClickMods(NSEvent.ModifierFlags()))
    #expect(actions == [.toggleDownloads, .profileMenu])
  }
}

@Suite struct StripNameWidthTests {
  @Test func theNameIsMeasuredAsRNsOnLayoutReportsItThenRoundedUp() {
    #expect(StripControlsLayout.measuredLikeYoga(54.834) == 56)
    #expect(StripControlsLayout.measuredLikeYoga(54.3) == 55)
    #expect(StripControlsLayout.measuredLikeYoga(55) == 56)
  }
}

@MainActor @Suite struct StripPeekRowTests {
  @Test func theStripFillsTheRowUpToTheControlsAsTopTabStripLaysItOut() {
    let frames = StripPeekRow.frames(width: 1187, controls: 114)
    #expect(frames.strip == CGRect(x: 8, y: 0, width: 1187 - 8 - 128, height: 42))
    #expect(frames.controls == CGRect(x: 1187 - 8 - 114, y: 4, width: 114, height: 34.5))
    #expect(StripPeekRow.frames(width: 1187, controls: 34).strip.width == CGFloat(1095))
  }
}
