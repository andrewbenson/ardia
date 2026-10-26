import Foundation
import SwiftUI

public enum RNEasing: Sendable, Hashable {
  case linear, inQuad, outQuad, inCubic, outCubic, inOutCubic

  public func callAsFunction(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    switch self {
    case .linear: return t
    case .inQuad: return t * t
    case .outQuad: return 1 - (1 - t) * (1 - t)
    case .inCubic: return t * t * t
    case .outCubic: return 1 - pow(1 - t, 3)
    case .inOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
  }
}

struct RNTimingAnimation: CustomAnimation {
  let duration: Double
  let easing: RNEasing

  func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
    if time >= duration { return nil }
    return value.scaled(by: easing(time / duration))
  }
}

struct RNSpringAnimation: CustomAnimation {
  let params: SpringParams

  func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
    let (position, speed) = RNSpring.solve(params, from: 0, to: 1, initialVelocity: 0, t: time)
    if abs(speed) <= RNSpring.restThreshold && abs(1 - position) <= RNSpring.restThreshold && time > 0 { return nil }
    return value.scaled(by: position)
  }
}

extension SpringParams {
  static func origami(friction: Double, tension: Double) -> SpringParams {
    SpringParams(stiffness: (tension - 30) * 3.62 + 194, damping: (friction - 8) * 3 + 25)
  }
}

extension Animation {
  static func rn(_ milliseconds: Double, _ easing: RNEasing, delay: Double = 0) -> Animation {
    let animation = Animation(RNTimingAnimation(duration: milliseconds / 1000, easing: easing))
    return delay > 0 ? animation.delay(delay / 1000) : animation
  }

  static func rnSpring(friction: Double, tension: Double) -> Animation {
    Animation(RNSpringAnimation(params: .origami(friction: friction, tension: tension)))
  }
}

func rnInterpolate(_ x: Double, _ input: [Double], _ output: [Double], clamp: Bool = false) -> Double {
  guard input.count >= 2, input.count == output.count else { return output.first ?? x }
  var i = 1
  while i < input.count - 1 && x > input[i] { i += 1 }
  let lo = input[i - 1], hi = input[i]
  var x = x
  if clamp { x = min(max(x, input[0]), input[input.count - 1]) }
  if hi == lo { return output[i] }
  let t = (x - lo) / (hi - lo)
  return output[i - 1] + (output[i] - output[i - 1]) * t
}

struct MotionTween: Equatable {
  var from: Double
  var to: Double
  var start: Date
  var duration: Double
  var easing: RNEasing

  init(at value: Double) {
    from = value
    to = value
    start = .distantPast
    duration = 0
    easing = .linear
  }

  func value(at date: Date) -> Double {
    guard duration > 0 else { return to }
    let t = date.timeIntervalSince(start) * 1000 / duration
    if t >= 1 { return to }
    if t <= 0 { return from }
    return from + (to - from) * easing(t)
  }

  func active(at date: Date) -> Bool { duration > 0 && date.timeIntervalSince(start) * 1000 < duration }

  mutating func retarget(_ target: Double, duration: Double, easing: RNEasing, at date: Date = Date()) {
    guard target != to else { return }
    from = value(at: date)
    to = target
    start = date
    self.duration = duration
    self.easing = easing
  }
}
