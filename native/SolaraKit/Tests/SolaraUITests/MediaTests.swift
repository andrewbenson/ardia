import AppKit
import Testing

@testable import SolaraUI

@Suite struct MediaFormatTests {
  @Test func timeMatchesJS() {
    #expect(MediaFormat.time(0) == "0:00")
    #expect(MediaFormat.time(5.9) == "0:05")
    #expect(MediaFormat.time(65) == "1:05")
    #expect(MediaFormat.time(3600) == "1:00:00")
    #expect(MediaFormat.time(3725) == "1:02:05")
    #expect(MediaFormat.time(-4) == "0:00")
  }

  func session(_ playbackState: String, position: Double = 10, timestamp: Double = 1000, rate: Double = 1, duration: Double? = 60) -> MediaPlayerState {
    MediaPlayerState(
      tabId: "t", title: "T", subtitle: "S", muted: false, playbackState: playbackState, position: position, timestamp: timestamp,
      playbackRate: rate, duration: duration, tracks: false, artwork: nil, url: "https://a.test/", favicon: nil, profileId: "p",
      theme: MediaThemeState(dark: true))
  }

  @Test func positionAdvancesOnlyWhilePlaying() {
    #expect(session("playing").position(at: 3000) == 12)
    #expect(session("paused").position(at: 3000) == 10)
    #expect(session("playing", rate: 2).position(at: 3000) == 14)
    #expect(session("playing", rate: 0).position(at: 3000) == 12)
  }

  @Test func positionClampsToDuration() {
    #expect(session("playing", duration: 11).position(at: 9000) == 11)
    #expect(session("playing", position: -5, duration: nil).position(at: 1000) == 0)
    #expect(session("playing", duration: nil).position(at: 101_000) == 110)
  }
}

@Suite struct MediaMotionTests {
  @Test func tweenFollowsRNEasing() {
    let tween = RNTween(from: 0, to: 1, start: 10, duration: 0.16, easing: .outCubic)
    #expect(tween.value(at: 10) == 0)
    #expect(abs(tween.value(at: 10.08) - 0.875) < 1e-9)
    #expect(tween.value(at: 10.2) == 1)
    let hide = RNTween(from: 1, to: 0, start: 0, duration: 0.2, easing: .inQuad)
    #expect(abs(hide.value(at: 0.1) - 0.75) < 1e-9)
    #expect(tween.samples().count == 21)
  }

  @Test func marqueeLoopMatchesRNSequence() {
    let timing = MarqueeTiming(maxOverflow: 60)
    #expect(timing.leg == 2)
    #expect(timing.period == 7)
    #expect(timing.progress(at: 1) == 0)
    #expect(timing.progress(at: 2.5) == 0.5)
    #expect(timing.progress(at: 4) == 1)
    #expect(timing.progress(at: 6) == 0.5)
    #expect(timing.progress(at: 8.5) == 0)
    #expect(MarqueeTiming(maxOverflow: 0.5).progress(at: 2.5) == 0)
    let leading = timing.edgeKeys(leading: true)
    #expect(leading.values == [0, 0, 1, 1, 0])
    #expect(abs(leading.times[2] * 7 - 1.56) < 1e-9)
  }
}

@MainActor
@Suite struct MediaLayoutTests {
  let theme = MediaThemeState(dark: true, colors: ["panel": "#2A2A2A"], panelShadowOpacity: 0.5)

  @Test func cliPillSitsCentredAboveTheBottom() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.layoutSubtreeIfNeeded()
    let pill = view.pillFrame
    #expect(pill.height == 32)
    #expect(abs(pill.maxY - 588) < 0.01)
    #expect(abs(pill.midX - 400) <= 0.5)
    #expect(view.progress == 1)
  }

  @Test func cliPillNeverOverflowsANarrowPane() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.layoutSubtreeIfNeeded()
    #expect(view.pillFrame.width <= 96)
  }

  @Test func cliPillHidesWithRNTiming() {
    let view = CliControlPillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.update(CliPillState(shown: true, command: "solara", product: "Solara", theme: theme))
    view.update(CliPillState(shown: false, command: "solara", product: "Solara", theme: theme))
    #expect(view.progress > 0.99)
    #expect(!view.shown)
  }

  @Test func smallBarFieldMatchesSmallChrome() {
    #expect(SmallBarMetrics.fieldFrame(width: 600, buttons: 3) == CGRect(x: 84, y: 5, width: 416, height: 28))
    #expect(SmallBarMetrics.fieldFrame(width: 600, buttons: 2) == CGRect(x: 84, y: 5, width: 446, height: 28))
  }

  @Test func shareBarButtonsSitRightOfTheText() {
    let bar = ShareBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 38))
    bar.update(ShareBarState(capturer: "c", tabId: "t", shared: false, host: "meet.test", theme: theme))
    bar.layoutSubtreeIfNeeded()
    let f = bar.controlFrames
    #expect(f["dismiss"]!.maxX == 892)
    #expect(f["primary"]!.maxX == f["dismiss"]!.minX - 10)
    #expect(f["dismiss"]!.height == 28 && f["dismiss"]!.minY == 5)
    #expect(bar.primaryTitle == "Share This Tab Instead")
    #expect(f["text"]!.minX == 42)
  }

  @Test func sidebarPlayerMatchesRNGeometry() {
    let player = SidebarPlayerView(frame: NSRect(x: 0, y: 0, width: 220, height: 74))
    player.update(MediaPlayerState(
      tabId: "t", title: "T", subtitle: "S", muted: false, playbackState: "playing", position: 30, timestamp: MediaClock.nowMs(),
      playbackRate: 1, duration: 60, tracks: false, artwork: nil, url: "https://a.test/", favicon: nil, profileId: "p", theme: theme))
    player.layoutSubtreeIfNeeded()
    let f = player.controlFrames
    #expect(f["art"] == CGRect(x: 7, y: 7, width: 32, height: 32))
    #expect(f["play"] == CGRect(x: 27, y: 43, width: 24, height: 24))
    #expect(f["seek"] == CGRect(x: 81, y: 49, width: 132, height: 12))
    #expect(f["close"] == CGRect(x: 208, y: -6, width: 18, height: 18))
    #expect(abs(player.seekProgress - 0.5) < 0.01)
  }
}
