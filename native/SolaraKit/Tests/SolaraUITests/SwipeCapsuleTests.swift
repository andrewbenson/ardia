import AppKit
import Testing

@testable import SolaraUI

@MainActor
struct SwipeCapsuleTests {
  private let theme = SwipeCapsuleTheme(dark: false, textPrimary: "#000000D9", textSecondary: "#00000080")

  private func view(_ direction: SwipeCapsuleDirection = .back) -> SwipeCapsuleView {
    let v = SwipeCapsuleView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    v.show(direction, theme: theme, profileId: "default", now: 0)
    return v
  }

  private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
  }

  @Test func aNewSwipeStartsOffTheEdgeAtTheMiddle() {
    let s = view().sample(at: 0)
    #expect(near(s.frame, CGRect(x: -72, y: 264, width: 72, height: 72)))
    #expect(s.radius == 36 && s.opacity == 1 && s.iconScale == 1 && abs(s.iconOpacity - 0.5) < 0.001)
  }

  @Test func confirmingGrowsTheCapsuleAndIconOnTheirSprings() {
    let v = view()
    v.move(x: 14, now: 0.01)
    v.setConfirmed(true, now: 0.01)
    let mid = v.sample(at: 0.06)
    #expect(mid.frame.width > 72 && mid.frame.width < 82.5)
    let s = v.sample(at: 2)
    #expect(near(s.frame, CGRect(x: 14, y: 259, width: 82, height: 82)))
    #expect(abs(s.radius - 41) < 0.01 && abs(s.iconScale - 34.0 / 28) < 0.001 && abs(s.iconOpacity - 1) < 0.001)
  }

  @Test func theListReplacesTheCapsuleAndThePillFollowsTheSelection() {
    let v = view()
    v.setConfirmed(true, now: 0)
    v.move(x: 14, now: 0.4)
    v.presentList([SwipeCapsuleItem(title: "Two", url: "https://two.test"), SwipeCapsuleItem(title: "One", url: "https://one.test")], now: 0.4)
    var s = v.sample(at: 2)
    #expect(near(s.frame, CGRect(x: 14, y: 273, width: 200, height: 92)))
    #expect(abs(s.radius - 18) < 0.01 && s.list == 1 && s.iconOpacity == 0)
    v.select(1, now: 2)
    v.move(x: 14, nudge: 3, now: 2)
    s = v.sample(at: 4)
    #expect(abs(s.pill - 38) < 0.01 && abs(s.frame.minY - 276) < 0.01)
  }

  @Test func aForwardSwipeComesInFromTheRight() {
    let v = view(.forward)
    v.move(x: 20, now: 0)
    #expect(near(v.sample(at: 0).frame, CGRect(x: 800 - 20 - 72, y: 264, width: 72, height: 72)))
  }

  @Test func dismissFadesAndShrinksAfterItsDelay() {
    let v = view()
    v.dismiss(delay: 0.12, now: 1)
    #expect(v.sample(at: 1.1).opacity == 1)
    let mid = v.sample(at: 1.22)
    #expect(mid.opacity < 1 && mid.opacity > 0 && mid.scale < 1)
    let end = v.sample(at: 1.33)
    #expect(end.opacity == 0 && abs(end.scale - 0.01) < 0.0001)
    #expect(!v.active)
  }
}
