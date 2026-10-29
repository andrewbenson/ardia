import AppKit
import Testing
@testable import SolaraUI

@MainActor
struct DockAnimatorLifetimeTests {
  @Test func aStoppedRunCanBeResumedToTheSameTarget() {
    let animator = DockAnimator(value: 1)
    var settled: Double?
    animator.onSettle = { settled = $0 }
    animator.animate(to: 0, in: NSView())
    for _ in 0..<3 { animator.step(by: 1.0 / 60) }
    animator.stop()
    #expect(!animator.moving)
    #expect(animator.value > 0)
    animator.animate(to: 0, in: NSView())
    #expect(animator.moving)
    for _ in 0..<60 where animator.moving { animator.step(by: 1.0 / 60) }
    #expect(settled == 0)
    #expect(animator.value == 0)
  }

  @Test func aRetargetFromOnChangeOnTheLastFrameKeepsRunning() {
    let animator = DockAnimator(value: 1)
    let view = NSView()
    var settles: [Double] = []
    animator.onSettle = { settles.append($0) }
    var retargeted = false
    animator.onChange = { value in
      if value == 0 && !retargeted {
        retargeted = true
        animator.animate(to: 1, in: view)
      }
    }
    animator.animate(to: 0, curve: .timed(duration: 0.1, ease: .outCubic), in: view)
    for _ in 0..<6 { animator.step(by: 1.0 / 60) }
    #expect(retargeted)
    #expect(animator.moving)
    #expect(settles.isEmpty)
    for _ in 0..<60 where animator.moving { animator.step(by: 1.0 / 60) }
    #expect(settles == [1])
  }

  @Test func aMovingAnimatorIsNotKeptAliveByItsDisplayLink() {
    weak var weakAnimator: DockAnimator?
    do {
      let animator = DockAnimator(value: 1)
      animator.animate(to: 0, in: NSView())
      #expect(animator.moving)
      weakAnimator = animator
    }
    #expect(weakAnimator == nil)
  }

  @Test func aTimedRunFollowsTheWallClockAfterAStall() {
    let animator = DockAnimator(value: 1)
    animator.animate(to: 0, curve: .timed(duration: 0.1, ease: .outCubic), in: NSView())
    animator.step(by: 0.1)
    #expect(!animator.moving)
    #expect(animator.value == 0)
  }

  @Test func withNoDisplayFramesTheRunStillSettlesOnTheWallClock() {
    var clock: CFTimeInterval = 100
    let animator = DockAnimator(value: 1)
    animator.now = { clock }
    var settled: Double?
    animator.onSettle = { settled = $0 }
    animator.animate(to: 0, curve: .timed(duration: 0.3, ease: .outCubic), in: NSView())
    clock += DockMotion.stalledFrame / 2
    animator.tickIfStalled()
    #expect(animator.value == 1)
    for _ in 0..<10 where animator.moving {
      clock += DockMotion.stalledFrame
      animator.tickIfStalled()
    }
    #expect(settled == 0)
    #expect(animator.value == 0)
  }

  @Test func aFreshDisplayFrameHoldsOffTheStallTick() {
    var clock: CFTimeInterval = 100
    let animator = DockAnimator(value: 1)
    animator.now = { clock }
    animator.animate(to: 0, curve: .timed(duration: 0.3, ease: .outCubic), in: NSView())
    clock += DockMotion.stalledFrame / 2
    animator.tick()
    let afterFrame = animator.value
    clock += DockMotion.stalledFrame / 2
    animator.tickIfStalled()
    #expect(animator.value == afterFrame)
  }

  @Test func aSpringStillClampsAStall() {
    let animator = DockAnimator(value: 1)
    animator.animate(to: 0, in: NSView())
    animator.step(by: 1)
    #expect(animator.moving)
  }
}
