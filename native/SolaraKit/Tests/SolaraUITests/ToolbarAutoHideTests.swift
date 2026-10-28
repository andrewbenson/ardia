import CoreGraphics
import Testing
@testable import SolaraUI

struct ToolbarAutoHideTests {
  @Test func modeFollowsRNsRules() {
    func mode(_ enabled: Bool, _ page: Bool, _ down: Bool, _ peek: Bool, _ bar: Bool) -> ToolbarAutoHideMode {
      ToolbarAutoHideInput(enabled: enabled, hasPage: page, scrolledDown: down, peek: peek, needsBar: bar).mode
    }
    #expect(mode(false, true, true, false, false) == .shown)
    #expect(mode(true, false, true, false, false) == .shown)
    #expect(mode(true, true, false, true, false) == .shown)
    #expect(mode(true, true, true, false, true) == .shown)
    #expect(mode(true, true, true, false, false) == .collapsed)
    #expect(mode(true, true, true, true, false) == .peek)
  }

  @Test func curvesMatchRNsInterpolations() {
    #expect(ToolbarAutoHideCurves.controlsOpacity(fade: 0) == 1)
    #expect(abs(ToolbarAutoHideCurves.controlsOpacity(fade: 0.2) - 0.45) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.controlsOpacity(fade: 0.3) - 0.3) < 1e-9)
    #expect(ToolbarAutoHideCurves.controlsOpacity(fade: 0.6) == 0)
    #expect(ToolbarAutoHideCurves.labelOpacity(fade: 0.5) == 0)
    #expect(abs(ToolbarAutoHideCurves.labelOpacity(fade: 0.75) - 0.5) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.toolbarScale(bar: 1) - 0.94) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.toolbarLift(bar: 1) - (-(0.06 * 41) / 2 - 3)) < 1e-9)
    #expect(abs(ToolbarAutoHideCurves.bandScale(bar: 1) - 20.0 / 41) < 1e-9)
    #expect(ToolbarAutoHideCurves.bandLift(bar: 1) == -10.5)
    #expect(ToolbarAutoHideCurves.dividerLift(bar: 1) == -21)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0, collapsed: true, shownTop: 41) == 41)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0.5, collapsed: true, shownTop: 41) == 30.5)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 1, collapsed: true, shownTop: 41) == 20)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 0, page: 1, collapsed: false, shownTop: 71) == 20)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 0, page: 0, collapsed: false, shownTop: 71) == 71)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0, collapsed: true, shownTop: 71) == 71)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 0.5, collapsed: true, shownTop: 71) == 45.5)
    #expect(ToolbarAutoHideCurves.liveTop(laid: 1, page: 1, collapsed: true, shownTop: 71) == 20)
  }

  @Test func transitionsTakeRNsTimings() throws {
    let hide = try #require(ToolbarAutoHideTransition.between(.shown, .collapsed, current: (0, 0, 0), at: 10, reduceMotion: false))
    #expect(hide.page.duration == 0.15 && hide.page.to == 1 && hide.bar.to == 1 && hide.laid == 1)
    let show = try #require(ToolbarAutoHideTransition.between(.collapsed, .shown, current: (1, 1, 1), at: 10, reduceMotion: false))
    #expect(show.page.duration == 0.2 && show.page.to == 0 && show.fade.to == 0)
    let peek = try #require(ToolbarAutoHideTransition.between(.collapsed, .peek, current: (1, 1, 1), at: 10, reduceMotion: false))
    #expect(peek.bar == .resting(0) && peek.fade == .resting(0))
    let unpeek = try #require(ToolbarAutoHideTransition.between(.peek, .collapsed, current: (1, 0, 0), at: 10, reduceMotion: false))
    #expect(unpeek.bar.duration == 0.15 && unpeek.bar.to == 1)
    #expect(ToolbarAutoHideTransition.between(.shown, .shown, current: (0, 0, 0), at: 10, reduceMotion: false) == nil)
    let reduced = try #require(ToolbarAutoHideTransition.between(.shown, .collapsed, current: (0, 0, 0), at: 10, reduceMotion: true))
    #expect(reduced.page == .resting(1) && reduced.fade.duration == 0.15)
  }
}

