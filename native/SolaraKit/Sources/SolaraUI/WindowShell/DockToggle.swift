import Foundation

public struct DockToggle: Equatable, Sendable {
  public enum Move: Equatable, Sendable {
    case none
    case jump(to: Double)
    case run(to: Double, curve: DockAnimator.Curve)
  }

  public struct Options: Equatable, Sendable {
    public var animate: Bool
    public var reduceMotion: Bool
    public var slideSwitch: Bool
    public var arc: Bool
    public var peekShown: Bool

    public init(animate: Bool = true, reduceMotion: Bool = false, slideSwitch: Bool = true, arc: Bool = false, peekShown: Bool = false) {
      self.animate = animate
      self.reduceMotion = reduceMotion
      self.slideSwitch = slideSwitch
      self.arc = arc
      self.peekShown = peekShown
    }
  }

  public private(set) var open: Bool
  public private(set) var away: Bool
  public private(set) var moving = false

  public init(open: Bool) {
    self.open = open
    away = !open
  }

  public mutating func set(open next: Bool, _ o: Options) -> Move {
    guard next != open else { return .none }
    open = next
    if !o.animate || o.reduceMotion || !o.slideSwitch {
      moving = false
      away = !next
      return .jump(to: next ? 1 : 0)
    }
    if o.arc && next && o.peekShown {
      moving = false
      away = false
      return .jump(to: 1)
    }
    if next { away = false }
    moving = true
    if o.arc && !next { return .run(to: 0, curve: .timed(duration: DockMotion.arcHideMs / 1000, ease: .outCubic)) }
    return .run(to: next ? 1 : 0, curve: .spring(.dock))
  }

  public mutating func settled() {
    guard moving else { return }
    moving = false
    if !open { away = true }
  }
}
