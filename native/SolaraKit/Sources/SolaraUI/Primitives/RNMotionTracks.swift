import AppKit
import QuartzCore

public struct RNTween: Sendable, Equatable {
  public var from: Double
  public var to: Double
  public var start: CFTimeInterval
  public var duration: CFTimeInterval
  public var easing: RNEasing

  public init(from: Double, to: Double, start: CFTimeInterval, duration: CFTimeInterval, easing: RNEasing) {
    self.from = from
    self.to = to
    self.start = start
    self.duration = duration
    self.easing = easing
  }

  public static func resting(_ value: Double) -> RNTween {
    RNTween(from: value, to: value, start: 0, duration: 0, easing: .linear)
  }

  public func value(at time: CFTimeInterval) -> Double {
    guard duration > 0 else { return to }
    let t = (time - start) / duration
    if t >= 1 { return to }
    if t <= 0 { return from }
    return from + (to - from) * easing(t)
  }

  public func finished(at time: CFTimeInterval) -> Bool { duration <= 0 || time - start >= duration }

  public func samples(rate: Double = 120) -> [Double] {
    let count = max(2, Int((duration * rate).rounded(.up)) + 1)
    return (0..<count).map { i in from + (to - from) * easing(Double(i) / Double(count - 1)) }
  }
}

public struct SpringTrack: Sendable, Equatable {
  public var params: SpringParams
  public var from: Double
  public var to: Double
  public var velocity: Double
  public var start: CFTimeInterval
  public let duration: CFTimeInterval

  public init(_ params: SpringParams, from: Double, to: Double, velocity: Double = 0, start: CFTimeInterval) {
    self.params = params
    self.from = from
    self.to = to
    self.velocity = velocity
    self.start = start
    var spring = RNSpring(params, from: from, to: to, initialVelocity: velocity)
    var t = 0.0
    while !spring.finished && t < 10 {
      _ = spring.step(at: t)
      t += 1.0 / 240
    }
    duration = max(0, t - 1.0 / 240)
  }

  public static func resting(_ value: Double) -> SpringTrack {
    SpringTrack(SpringParams(stiffness: 0, damping: 0), from: value, to: value, start: 0)
  }

  private func clamped(_ time: CFTimeInterval) -> Double { min(max(0, time - start), duration) }

  public func value(at time: CFTimeInterval) -> Double {
    guard duration > 0, params.stiffness > 0 else { return to }
    if time - start >= duration { return to }
    return RNSpring.solve(params, from: from, to: to, initialVelocity: velocity, t: clamped(time)).0
  }

  public func velocity(at time: CFTimeInterval) -> Double {
    guard duration > 0, params.stiffness > 0, time - start < duration else { return 0 }
    return RNSpring.solve(params, from: from, to: to, initialVelocity: velocity, t: clamped(time)).1
  }

  public func samples(rate: Double = 120) -> [Double] {
    let count = max(2, Int((duration * rate).rounded(.up)) + 1)
    return (0..<count).map { i in
      let t = duration * Double(i) / Double(count - 1)
      return i == count - 1 ? to : RNSpring.solve(params, from: from, to: to, initialVelocity: velocity, t: t).0
    }
  }
}

public struct BezierCurve: Sendable, Equatable {
  public let x1, y1, x2, y2: Double

  public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    self.x1 = x1
    self.y1 = y1
    self.x2 = x2
    self.y2 = y2
  }

  public var timingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
  }

  public func callAsFunction(_ x: Double) -> Double {
    let t0 = min(1, max(0, x))
    func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
    func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
    var lo = 0.0
    var hi = 1.0
    for _ in 0..<40 {
      let mid = (lo + hi) / 2
      if bx(mid) < t0 { lo = mid } else { hi = mid }
    }
    return by((lo + hi) / 2)
  }
}

@MainActor
enum PrimitiveMotion {
  static func keyframes(_ keyPath: String, _ values: [Double], duration: CFTimeInterval, start: CFTimeInterval, map: (Double) -> Any) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values.map(map)
    animation.calculationMode = .linear
    animation.duration = duration
    animation.beginTime = start
    animation.fillMode = .backwards
    return animation
  }

  static func scale(about point: CGPoint, scale: Double, translateY: Double = 0) -> CATransform3D {
    var t = CATransform3DMakeTranslation(point.x, point.y + translateY, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    return CATransform3DTranslate(t, -point.x, -point.y, 0)
  }

  static func setInstantly(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }
}
