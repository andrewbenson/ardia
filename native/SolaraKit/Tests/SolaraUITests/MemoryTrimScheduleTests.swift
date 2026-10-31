import Testing
@testable import SolaraUI

@Suite struct MemoryTrimScheduleTests {
  @Test func countChangesDebounceAndMetadataChangesKeepTheExistingTimer() {
    var trim = MemoryTrimSchedule(tabCount: 3)
    #expect(trim.dueAt == nil)
    let outcome1 = !trim.fire(now: 100000, inputIdleSeconds: 10, quitting: false)
    #expect(outcome1)
    let outcome2 = !trim.tabsChanged(count: 3, now: 100000)
    #expect(outcome2)
    #expect(trim.dueAt == nil)
    let outcome3 = trim.tabsChanged(count: 2, now: 100000)
    #expect(outcome3)
    #expect(trim.dueAt == 105000)
    let outcome4 = !trim.tabsChanged(count: 2, now: 101000)
    #expect(outcome4)
    #expect(trim.dueAt == 105000)
    let outcome5 = trim.tabsChanged(count: 4, now: 102000)
    #expect(outcome5)
    #expect(trim.dueAt == 107000)
    let outcome6 = trim.fire(now: 107000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome6)
    #expect(trim.dueAt == nil)
    #expect(trim.lastTrimAt == 107000)
  }

  @Test func theMinimumGapRunsBeforeIdleAndDoesNotConsumeAPostponement() {
    var trim = MemoryTrimSchedule(tabCount: 1)
    trim.tabsChanged(count: 0, now: 100000)
    let outcome7 = trim.fire(now: 105000, inputIdleSeconds: nil, quitting: false)
    #expect(outcome7)
    trim.tabsChanged(count: 1, now: 106000)
    let outcome8 = !trim.fire(now: 111100, inputIdleSeconds: 0, quitting: false)
    #expect(outcome8)
    #expect(trim.dueAt == 135000)
    #expect(trim.postponements == 0)
    let outcome9 = trim.fire(now: 135000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome9)
  }

  @Test func idleAndLatenessKeepTheirExactBoundaries() {
    for (late, idle, expected) in [(49.0, 2.0, true), (50, 2, false), (0, 1.999, false), (0, 3600, true)] {
      var trim = MemoryTrimSchedule(tabCount: 1)
      trim.tabsChanged(count: 2, now: 100000)
      let outcome10 = trim.fire(now: 105000 + late, inputIdleSeconds: idle, quitting: false) == expected
      #expect(outcome10)
      #expect(trim.dueAt == (expected ? nil : 106000 + late))
    }
  }

  @Test func thirtyPostponementsDropTheRequestUntilTheCountChangesAgain() {
    var trim = MemoryTrimSchedule(tabCount: 1)
    trim.tabsChanged(count: 2, now: 100000)
    for retry in 0..<30 {
      let outcome11 = !trim.fire(now: 105000 + Double(retry) * 1000, inputIdleSeconds: 0, quitting: false)
      #expect(outcome11)
      #expect(trim.postponements == retry + 1)
      #expect(trim.dueAt == 106000 + Double(retry) * 1000)
    }
    let outcome12 = !trim.fire(now: 135000, inputIdleSeconds: 0, quitting: false)
    #expect(outcome12)
    #expect(trim.dueAt == nil)
    #expect(trim.lastTrimAt == 0)
    let outcome13 = !trim.tabsChanged(count: 2, now: 136000)
    #expect(outcome13)
    let outcome14 = trim.tabsChanged(count: 1, now: 136000)
    #expect(outcome14)
    #expect(trim.postponements == 0)
    let outcome15 = trim.fire(now: 141000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome15)
  }

  @Test func aCountChangeReplacesABusyRetryWithoutResettingTheLastTrim() {
    var trim = MemoryTrimSchedule(tabCount: 1)
    trim.tabsChanged(count: 2, now: 100000)
    let outcome16 = trim.fire(now: 105000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome16)
    trim.tabsChanged(count: 1, now: 140000)
    let outcome17 = !trim.fire(now: 145000, inputIdleSeconds: 0, quitting: false)
    #expect(outcome17)
    #expect(trim.dueAt == 146000)
    trim.tabsChanged(count: 0, now: 145100)
    #expect(trim.dueAt == 150100)
    #expect(trim.postponements == 0)
    #expect(trim.lastTrimAt == 105000)
  }

  @Test func quittingDropsWorkAndCancellationNeedsAFreshCountChange() {
    var trim = MemoryTrimSchedule(tabCount: 1)
    trim.tabsChanged(count: 2, now: 100000)
    let outcome18 = !trim.fire(now: 105000, inputIdleSeconds: 2, quitting: true)
    #expect(outcome18)
    #expect(trim.dueAt == nil)
    #expect(trim.lastTrimAt == 0)
    let outcome19 = !trim.fire(now: 106000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome19)
    trim.tabsChanged(count: 1, now: 107000)
    let outcome20 = trim.fire(now: 112000, inputIdleSeconds: 2, quitting: false)
    #expect(outcome20)
  }

  @Test func environmentOnlyDisablesTheSameExactValues() {
    #expect(MemoryTrimSchedule.enabled(environment: [:]))
    #expect(MemoryTrimSchedule.enabled(environment: ["SOLARA_MEMORY_TRIM_HEAP": "off"]))
    #expect(MemoryTrimSchedule.enabled(environment: ["SOLARA_MEMORY_TRIM_ENGINE": "off"]))
    for key in ["SOLARA_MEMORY_TRIM"] {
      for off in ["off", "0", "false"] {
        #expect(!MemoryTrimSchedule.enabled(environment: [key: off]))
      }
      for on in ["", "on", "1", "true", "OFF", "False", " off "] {
        #expect(MemoryTrimSchedule.enabled(environment: [key: on]))
      }
    }
  }
}
