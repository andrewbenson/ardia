import CoreGraphics
import Testing
@testable import SolaraUI

struct PeekMotionTests {
  @Test func frameIsInsetFivePointFivePercentWithASixteenPointFloor() {
    #expect(PeekMetrics.frame(width: 1000, height: 800) == CGRect(x: 55, y: 44, width: 890, height: 712))
    #expect(PeekMetrics.frame(width: 200, height: 100) == CGRect(x: 16, y: 16, width: 168, height: 68))
    #expect(PeekMetrics.frame(width: 20, height: 20).width == 0)
  }

  @Test func pageSitsUnderTheBarInsideTheInsets() {
    #expect(PeekMetrics.pageFrame(in: CGSize(width: 890, height: 712)) == CGRect(x: 6, y: 38, width: 878, height: 668))
  }

  @Test func pinchCommitsPastItsThresholds() {
    #expect(PeekPinch.outcome(0.3) == .open)
    #expect(PeekPinch.outcome(0.29) == .stay)
    #expect(PeekPinch.outcome(-0.25) == .close)
    #expect(PeekPinch.outcome(-0.1) == .stay)
  }

  @Test func pinchFollowsTheFingers() {
    #expect(PeekPinch.follow(0.2) == (1, 0.5))
    #expect(PeekPinch.follow(1).expand == 1)
    let shrink = PeekPinch.follow(-0.44)
    #expect(abs(shrink.progress - 0.5) < 0.001 && shrink.expand == 0)
    #expect(PeekPinch.follow(-1).progress == 0)
  }

  @Test func poseGrowsFromTheLinkAndFadesTheDimWhenExpanding() {
    let frame = CGRect(x: 55, y: 44, width: 890, height: 712)
    let container = CGSize(width: 1000, height: 800)
    let start = PeekPose.at(progress: 0, expand: 0, frame: frame, container: container, from: CGPoint(x: 100, y: 100), fade: false)
    #expect(abs(start.scaleX - 0.12) < 0.0001 && start.translateX == 100 - frame.midX && start.cardOpacity == 0 && start.dim == 0)
    let shown = PeekPose.at(progress: 1, expand: 0, frame: frame, container: container, from: CGPoint(x: 100, y: 100), fade: false)
    #expect(shown == PeekPose(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0, cardOpacity: 1, dim: 1))
    let full = PeekPose.at(progress: 1, expand: 1, frame: frame, container: container, from: nil, fade: false)
    #expect(abs(full.scaleX - 1000 / 890) < 0.0001 && abs(full.scaleY - 800 / 712) < 0.0001 && full.dim == 0)
    let early = PeekPose.at(progress: 0.175, expand: 0, frame: frame, container: container, from: nil, fade: false)
    #expect(abs(early.cardOpacity - 0.5) < 0.0001)
  }

  @Test func reduceMotionOnlyFades() {
    let pose = PeekPose.at(progress: 0.4, expand: 0, frame: .zero, container: .zero, from: nil, fade: true)
    #expect(pose == PeekPose(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0, cardOpacity: 0.4, dim: 0.4))
  }
}

@MainActor
struct PeekOverlayViewTests {
  static func state(fullscreen: Bool = false, splitFull: Bool = false) -> PeekState {
    PeekState(
      tabId: "t1", dark: false, host: "example.com", title: "Example", favicon: nil, insecure: false, loading: nil, splitFull: splitFull,
      fullscreen: fullscreen, from: PeekPoint(x: 100, y: 100), reduceMotion: true,
      palette: ToolbarPaletteState(
        background: nil, text: "#000000CC", secondary: "#00000080", icon: "#000000D4", iconDisabled: "#0000006E", hover: "#0000000F",
        pressed: "#0000001A", pill: "#0000000A", divider: "#0000001A", urlHost: nil, urlPath: nil),
      panel: "#F7F2F3", card: "#FFFFFF", accent: "#3478F6")
  }

  @Test func theCardAndPageSitWhereRNPutsThem() {
    let view = PeekOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    view.apply(Self.state())
    view.layoutSubtreeIfNeeded()
    let page = view.pageSlot.convert(view.pageSlot.bounds, to: view)
    #expect(page == CGRect(x: 55 + 6, y: 44 + 38, width: 878, height: 668))
  }

  @Test func fullScreenDropsTheChrome() {
    let view = PeekOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    view.apply(Self.state(fullscreen: true))
    view.layoutSubtreeIfNeeded()
    #expect(view.pageSlot.convert(view.pageSlot.bounds, to: view) == CGRect(x: 0, y: 0, width: 1000, height: 800))
  }

  @Test func closingReportsTheTabOnce() async {
    let view = PeekOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    var events: [PeekEvent] = []
    view.onEvent = { events.append($0) }
    view.apply(Self.state())
    view.close()
    view.close()
    for _ in 0..<40 where events.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
    #expect(events == [.closed("t1")])
  }
}
