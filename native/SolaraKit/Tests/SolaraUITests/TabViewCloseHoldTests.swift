import Testing
@testable import SolaraUI

struct TabViewCloseHoldTests {
  @Test func survivingPinnedAndSharedTabsDoNotReleaseAnOrdinaryClose() {
    let hold = TabViewCloseHold(tabIds: ["closed", "pinned", "shared"], presentTabIds: ["pinned", "shared", "other"])
    #expect(hold.absentTabIds == ["closed"])
    #expect(!hold.restored(presentTabIds: ["pinned", "shared", "other"], freshTabIds: ["shared", "other"], unloadedTabIds: ["pinned"]))
  }

  @Test func aCloseContainingOnlySurvivorsWaitsForItsWindow() {
    let hold = TabViewCloseHold(tabIds: ["pinned", "shared"], presentTabIds: ["pinned", "shared"])
    #expect(hold.absentTabIds.isEmpty)
    #expect(!hold.restored(presentTabIds: ["pinned", "shared"], freshTabIds: ["shared"], unloadedTabIds: ["pinned"]))
  }

  @Test func noReturnedClosedTabDoesNotReleaseTheHold() {
    let hold = TabViewCloseHold(tabIds: ["closed"], presentTabIds: [])
    #expect(!hold.restored(presentTabIds: ["other"], freshTabIds: ["other"], unloadedTabIds: []))
  }

  @Test func aPartialRestoreReleasesOnceEveryReturnedTabIsFresh() {
    let hold = TabViewCloseHold(tabIds: ["first", "second", "shared"], presentTabIds: ["shared"])
    #expect(hold.restored(presentTabIds: ["first", "shared"], freshTabIds: ["first"], unloadedTabIds: []))
  }

  @Test func anUnloadedRestoreReleasesWithoutMakingAPage() {
    let hold = TabViewCloseHold(tabIds: ["first", "second"], presentTabIds: [])
    #expect(hold.restored(presentTabIds: ["first", "second"], freshTabIds: ["first"], unloadedTabIds: ["second"]))
  }

  @Test func anyStaleReturnedTabWaitsEvenWhenAnotherReturnedTabIsFresh() {
    let hold = TabViewCloseHold(tabIds: ["first", "second"], presentTabIds: [])
    #expect(!hold.restored(presentTabIds: ["first", "second"], freshTabIds: ["first"], unloadedTabIds: []))
    #expect(hold.restored(presentTabIds: ["first", "second"], freshTabIds: ["first", "second"], unloadedTabIds: []))
  }
}
