import Foundation
import Testing
@testable import SolaraModel

@MainActor
@Suite struct LaunchSuccessTests {
  @MainActor final class Clock {
    var pending: [(TimeInterval, @MainActor () -> Void)] = []
    func run(_ delay: TimeInterval) {
      let due = pending.filter { $0.0 == delay }
      pending.removeAll { $0.0 == delay }
      due.forEach { $0.1() }
    }
  }

  func watch() -> (LaunchSuccess, Clock, () -> Int) {
    let clock = Clock()
    var reports = 0
    let success = LaunchSuccess(after: { delay, work in clock.pending.append((delay, work)) }, report: { reports += 1 })
    return (success, clock, { reports })
  }

  @Test func aQuitBeforeAnyWindowShowedCountsAsAFinishedLaunch() {
    let (success, _, reports) = watch()
    success.start()
    success.quitting()
    #expect(reports() == 1)
    success.quitting()
    #expect(reports() == 1)
  }

  @Test func aMinuteUpWithNoWindowCountsAsAFinishedLaunch() {
    let (success, clock, reports) = watch()
    success.start()
    #expect(clock.pending.map(\.0) == [60])
    #expect(reports() == 0)
    clock.run(60)
    #expect(reports() == 1)
    #expect(success.succeeded && !success.windowSeen)
  }

  @Test func aShownWindowCountsAfterItSettlesAndOnlyOnce() {
    let (success, clock, reports) = watch()
    success.start()
    success.windowShown()
    success.windowShown()
    #expect(clock.pending.map(\.0) == [60, 15])
    clock.run(15)
    #expect(reports() == 1)
    clock.run(60)
    success.quitting()
    #expect(reports() == 1)
  }

  @Test func aCrashBeforeAnyOfThemLeavesTheLaunchUnfinished() {
    let (success, clock, reports) = watch()
    success.start()
    success.windowShown()
    #expect(reports() == 0)
    #expect(!success.succeeded)
    #expect(clock.pending.count == 2)
  }
}
