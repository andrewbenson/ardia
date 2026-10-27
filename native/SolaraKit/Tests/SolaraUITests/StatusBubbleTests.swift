import Foundation
import Testing
@testable import SolaraUI

@MainActor
final class ManualBubbleClock: StatusBubbleClock {
  final class Timer: StatusBubbleTimer {
    let due: Double
    var work: (@MainActor () -> Void)?

    init(due: Double, work: @escaping @MainActor () -> Void) {
      self.due = due
      self.work = work
    }

    func cancel() { work = nil }
  }

  private(set) var now: Double = 0
  private var timers: [Timer] = []

  func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> StatusBubbleTimer {
    let timer = Timer(due: now + seconds, work: work)
    timers.append(timer)
    return timer
  }

  func advance(_ seconds: Double) {
    let end = now + seconds
    while let next = timers.filter({ $0.work != nil && $0.due <= end + 1e-9 }).min(by: { $0.due < $1.due }) {
      now = next.due
      let work = next.work
      next.work = nil
      work?()
    }
    now = end
  }
}

@MainActor
struct StatusBubbleTests {
  @Test func showsAfterHalfASecondAndExpandsAfterOneAndAHalf() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://github.com/andrewbenson")
    #expect(model.presentation == .pendingPresentation)
    #expect(model.text == "https://github.com/andrewbenson")
    #expect(!model.opaque)
    clock.advance(0.49)
    #expect(model.presentation == .pendingPresentation)
    clock.advance(0.01)
    #expect(model.presentation == .visible && model.opaque)
    #expect(!model.expanded && model.expansionPending)
    clock.advance(1.49)
    #expect(!model.expanded)
    clock.advance(0.01)
    #expect(model.expanded && !model.expansionPending)
  }

  @Test func leavingBeforeTheDelayShowsNothing() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(0.3)
    model.setStatus("")
    #expect(model.presentation == .hidden && model.text.isEmpty)
    clock.advance(2)
    #expect(model.presentation == .hidden)
  }

  @Test func anotherLinkWhilePendingRestartsTheDelay() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(0.4)
    model.setStatus("https://b.example/")
    clock.advance(0.4)
    #expect(model.presentation == .pendingPresentation)
    clock.advance(0.1)
    #expect(model.presentation == .visible && model.text == "https://b.example/")
  }

  @Test func hidesHalfASecondAfterLeavingThenFades() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(0.5)
    model.setStatus("")
    #expect(model.presentation == .pendingDismissal && model.opaque)
    #expect(!model.expansionPending)
    clock.advance(0.5)
    #expect(model.presentation == .hiding && !model.opaque && model.mounted)
    #expect(model.text == "https://a.example/")
    clock.advance(0.1)
    #expect(model.presentation == .hidden && model.text.isEmpty && !model.mounted)
  }

  @Test func aLinkDuringTheHideDelayShowsAtOnceAndStaysCompact() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(2.0)
    #expect(model.expanded)
    model.setStatus("")
    clock.advance(0.2)
    model.setStatus("https://b.example/")
    #expect(model.presentation == .visible && model.text == "https://b.example/")
    #expect(!model.expanded && model.expansionPending)
    clock.advance(1.5)
    #expect(model.expanded)
  }

  @Test func aLinkWhileFadingOutComesBackAtOnce() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(0.5)
    model.setStatus("")
    clock.advance(0.55)
    #expect(model.presentation == .hiding)
    model.setStatus("https://b.example/")
    #expect(model.presentation == .visible && model.opaque)
    clock.advance(1)
    #expect(model.presentation == .visible)
  }

  @Test func movingBetweenLinksKeepsAnExpandedBubbleExpanded() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(2.0)
    #expect(model.expanded)
    model.setStatus("https://b.example/long")
    #expect(model.expanded && model.text == "https://b.example/long")
  }

  @Test func movingBetweenLinksBeforeExpansionRestartsIt() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(1.5)
    model.setStatus("https://b.example/")
    clock.advance(1.0)
    #expect(!model.expanded)
    clock.advance(0.5)
    #expect(model.expanded)
  }

  @Test func displayKeepsTheSchemeAndDecodesEscapes() {
    #expect(StatusBubbleText.display("https://github.com/andrewbenson") == "https://github.com/andrewbenson")
    #expect(StatusBubbleText.display("http://example.com/") == "http://example.com/")
    #expect(StatusBubbleText.display("https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC") == "https://ja.wikipedia.org/wiki/東京")
    #expect(StatusBubbleText.display("https://a.example/a%20b") == "https://a.example/a b")
    #expect(StatusBubbleText.display("https://a.example/%0Aevil") == "https://a.example/%0Aevil")
    #expect(StatusBubbleText.display("https://a.example/%E2%80%AEcod.exe") == "https://a.example/%E2%80%AEcod.exe")
    #expect(StatusBubbleText.display("https://a.example/%ZZ") == "https://a.example/%ZZ")
    #expect(StatusBubbleText.display("  ") == "")
    #expect(StatusBubbleText.display("mailto:someone@example.com") == "mailto:someone@example.com")
  }

  @Test func widthIsCappedAt400UntilExpanded() {
    #expect(StatusBubbleMetrics.width(text: 196.21, containerWidth: 800, expanded: false) == 214.5)
    #expect(StatusBubbleMetrics.width(text: 900, containerWidth: 800, expanded: false) == 400)
    #expect(StatusBubbleMetrics.width(text: 900, containerWidth: 800, expanded: true) == 780)
    #expect(StatusBubbleMetrics.width(text: 900, containerWidth: 300, expanded: false) == 280)
  }

  @Test func pinMovesRightWhenThePointerNearsTheBubbleAndBack() {
    let bubble = CGRect(x: 10, y: 566, width: 200, height: 24)
    #expect(StatusBubblePin.trailing(pointer: CGPoint(x: 100, y: 580), bubble: bubble, containerWidth: 1000, current: false))
    #expect(StatusBubblePin.trailing(pointer: CGPoint(x: 215, y: 560), bubble: bubble, containerWidth: 1000, current: false))
    #expect(!StatusBubblePin.trailing(pointer: CGPoint(x: 100, y: 500), bubble: bubble, containerWidth: 1000, current: false))
    let right = CGRect(x: 790, y: 566, width: 200, height: 24)
    #expect(StatusBubblePin.trailing(pointer: CGPoint(x: 100, y: 580), bubble: right, containerWidth: 1000, current: true))
    #expect(!StatusBubblePin.trailing(pointer: CGPoint(x: 600, y: 580), bubble: right, containerWidth: 1000, current: true))
    let wide = CGRect(x: 10, y: 566, width: 980, height: 24)
    #expect(StatusBubblePin.trailing(pointer: CGPoint(x: 500, y: 580), bubble: wide, containerWidth: 1000, current: true))
    #expect(!StatusBubblePin.trailing(pointer: CGPoint(x: 500, y: 580), bubble: wide, containerWidth: 1000, current: false))
  }

  @Test func pointerIsIgnoredWhileHidden() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.pointerMoved(CGPoint(x: 20, y: 580), bubble: CGRect(x: 10, y: 566, width: 200, height: 24), containerWidth: 1000)
    #expect(!model.pinnedTrailing)
    model.setStatus("https://a.example/")
    clock.advance(0.5)
    model.pointerMoved(CGPoint(x: 20, y: 580), bubble: CGRect(x: 10, y: 566, width: 200, height: 24), containerWidth: 1000)
    #expect(model.pinnedTrailing)
  }
}

@MainActor
struct StatusBubbleRepeatTests {
  @Test func theSameStatusAgainChangesNothing() {
    let clock = ManualBubbleClock()
    let model = StatusBubbleModel(clock: clock)
    model.setStatus("https://a.example/")
    clock.advance(1.0)
    model.setStatus("https://a.example/")
    clock.advance(1.0)
    #expect(model.expanded)
  }
}
