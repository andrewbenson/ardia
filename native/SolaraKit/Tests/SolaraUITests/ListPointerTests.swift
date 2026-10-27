import CoreGraphics
import Testing
@testable import SolaraUI

struct ListPointerTests {
  @Test func listAppearingUnderAStillPointerShowsNoHover() {
    var pointer = ListPointer()
    pointer.observe(CGPoint(x: 100, y: 400))
    pointer.observe(CGPoint(x: 100, y: 400))
    #expect(!pointer.moved)
  }

  @Test func movingThePointerShowsHover() {
    var pointer = ListPointer()
    pointer.observe(CGPoint(x: 100, y: 400))
    pointer.observe(CGPoint(x: 101, y: 400))
    #expect(pointer.moved)
  }

  @Test func rowsChangingUnderAStillPointerHideHoverUntilItMoves() {
    var pointer = ListPointer()
    pointer.observe(CGPoint(x: 100, y: 400))
    pointer.observe(CGPoint(x: 100, y: 420))
    #expect(pointer.moved)
    pointer.listChanged()
    #expect(!pointer.moved)
    pointer.observe(CGPoint(x: 100, y: 420))
    #expect(!pointer.moved)
    pointer.observe(CGPoint(x: 100, y: 421))
    #expect(pointer.moved)
  }

  @Test func leavingResets() {
    var pointer = ListPointer()
    pointer.observe(CGPoint(x: 1, y: 1))
    pointer.observe(CGPoint(x: 2, y: 1))
    pointer.leave()
    #expect(!pointer.moved)
  }
}
