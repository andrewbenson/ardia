import Foundation
import Testing
@testable import SolaraUI

struct DockToggleTests {
  @Test func closingSpringsAndGoesAwayOnlyWhenSettled() {
    var dock = DockToggle(open: true)
    #expect(dock.set(open: false, .init()) == .run(to: 0, curve: .spring(.dock)))
    #expect(dock.moving && !dock.away)
    dock.settled()
    #expect(!dock.moving && dock.away)
  }

  @Test func openingComesBackBeforeItMoves() {
    var dock = DockToggle(open: false)
    #expect(dock.away)
    #expect(dock.set(open: true, .init()) == .run(to: 1, curve: .spring(.dock)))
    #expect(!dock.away && dock.moving)
    dock.settled()
    #expect(!dock.away && !dock.moving)
  }

  @Test func arcHidesInAHundredMillisecondsEasingOut() {
    var dock = DockToggle(open: true)
    #expect(dock.set(open: false, .init(arc: true)) == .run(to: 0, curve: .timed(duration: 0.1, ease: .outCubic)))
    #expect(dock.set(open: true, .init(arc: true)) == .run(to: 1, curve: .spring(.dock)))
  }

  @Test func arcOpeningFromAPeekJumpsInPlace() {
    var dock = DockToggle(open: false)
    #expect(dock.set(open: true, .init(arc: true, peekShown: true)) == .jump(to: 1))
    #expect(!dock.away && !dock.moving)
  }

  @Test func fullScreenReduceMotionAndTheKillSwitchJump() {
    for options in [DockToggle.Options(animate: false), .init(reduceMotion: true), .init(slideSwitch: false)] {
      var dock = DockToggle(open: true)
      #expect(dock.set(open: false, options) == .jump(to: 0))
      #expect(dock.away && !dock.moving)
    }
  }

  @Test func sameValueDoesNothing() {
    var dock = DockToggle(open: true)
    #expect(dock.set(open: true, .init()) == .none)
    dock.settled()
    #expect(!dock.away)
  }

  @Test func aReversalBeforeSettlingKeepsTheSidebarHere() {
    var dock = DockToggle(open: true)
    _ = dock.set(open: false, .init())
    _ = dock.set(open: true, .init())
    dock.settled()
    #expect(!dock.away)
  }
}

@MainActor
struct EdgePeekTests {
  final class Clock {
    var timers: [(at: Double, run: () -> Void, id: Int)] = []
    var now = 0.0
    var next = 0
    func advance(_ seconds: Double) {
      now += seconds
      while let i = timers.indices.filter({ timers[$0].at <= now + 1e-9 }).min(by: { timers[$0].at < timers[$1].at }) {
        let t = timers.remove(at: i)
        t.run()
      }
    }
  }

  final class Token {
    let id: Int
    init(_ id: Int) { self.id = id }
  }

  final class Harness {
    let peek: EdgePeek
    let clock = Clock()
    var runs: [(to: Double, curve: DockAnimator.Curve, done: () -> Void)] = []
    var lives: [Bool] = []
    var slidOut = 0
    var holding = false

    @MainActor init(arc: Bool = false, enabled: Bool = true) {
      peek = EdgePeek(enabled: enabled, arc: arc)
      peek.schedule = { [clock] seconds, run in
        clock.next += 1
        clock.timers.append((clock.now + seconds, run, clock.next))
        return Token(clock.next)
      }
      peek.cancel = { [clock] token in clock.timers.removeAll { $0.id == (token as! Token).id } }
      peek.animate = { [unowned self] to, curve, done in runs.append((to, curve, done)) }
      peek.onLive = { [unowned self] in lives.append($0) }
      peek.onSlideOut = { [unowned self] in slidOut += 1 }
      peek.held = { [unowned self] in holding }
    }
  }

  @Test func showSlidesInAndHideWaitsThenSlidesOut() {
    let h = Harness()
    h.peek.show()
    #expect(h.peek.live)
    #expect(h.runs.last?.to == 1)
    #expect(h.runs.last?.curve == .timed(duration: 0.18, ease: .outCubic))
    h.peek.hide()
    h.clock.advance(0.119)
    #expect(h.runs.count == 1)
    h.clock.advance(0.002)
    #expect(h.runs.last?.to == 0)
    #expect(h.slidOut == 1)
    #expect(h.peek.live)
    h.runs.last?.done()
    #expect(!h.peek.live)
    #expect(h.lives == [true, false])
  }

  @Test func comingBackWithinTheDelayCancelsTheHide() {
    let h = Harness()
    h.peek.show()
    h.peek.hide()
    h.clock.advance(0.05)
    h.peek.show()
    h.clock.advance(0.5)
    #expect(h.runs.allSatisfy { $0.to == 1 })
    #expect(h.peek.live)
  }

  @Test func aSlideOutInterruptedByShowStaysLive() {
    let h = Harness()
    h.peek.show()
    h.peek.hide()
    h.clock.advance(0.2)
    let out = h.runs.last!
    h.peek.show()
    out.done()
    #expect(h.peek.live)
  }

  @Test func aHoldKeepsItOutUntilARecheckFindsItReleased() {
    let h = Harness()
    h.peek.show()
    h.holding = true
    h.peek.hide()
    h.clock.advance(0.2)
    #expect(h.slidOut == 0)
    h.peek.recheck()
    #expect(h.slidOut == 0)
    h.holding = false
    h.peek.recheck()
    h.clock.advance(0.121)
    #expect(h.slidOut == 1)
  }

  @Test func arcSpringsInAndEasesOutInOneFiftyMilliseconds() {
    let h = Harness(arc: true)
    h.peek.show()
    #expect(h.runs.last?.curve == .spring(.arcPeek))
    h.peek.hide()
    h.clock.advance(0.13)
    #expect(h.runs.last?.curve == .timed(duration: 0.15, ease: .inOutCubic))
  }

  @Test func disablingSlidesOutAtOnceAndBlocksShow() {
    let h = Harness()
    h.peek.show()
    h.peek.hide()
    h.peek.setEnabled(false)
    #expect(h.slidOut == 1)
    h.clock.advance(1)
    #expect(h.slidOut == 1)
    h.runs.last?.done()
    h.peek.show()
    #expect(!h.peek.live)
  }
}
