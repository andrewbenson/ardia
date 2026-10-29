import AppKit
import Testing

@testable import SolaraUI

@Suite @MainActor struct SidebarAddressBarsTests {
  @Test func clearingTheStateKeepsAClaimedViewUntilItsRelease() {
    let bars = SidebarAddressBars()
    let view = bars.view("w1")
    bars.claim("w1")
    bars.set("w1", json: nil)
    #expect(bars.existing("w1") === view)
    #expect(bars.view("w1") === view)
    bars.release("w1")
    #expect(bars.existing("w1") == nil)
  }

  @Test func clearingTheStateDropsAnUnclaimedView() {
    let bars = SidebarAddressBars()
    _ = bars.view("w1")
    bars.set("w1", json: nil)
    #expect(bars.existing("w1") == nil)
  }
}
