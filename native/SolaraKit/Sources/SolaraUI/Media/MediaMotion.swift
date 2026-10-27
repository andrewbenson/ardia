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

@MainActor
enum MediaMotion {
  static func keyframes(_ keyPath: String, _ tween: RNTween, map: (Double) -> Any) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = tween.samples().map(map)
    animation.calculationMode = .linear
    animation.duration = tween.duration
    animation.beginTime = tween.start
    animation.fillMode = .backwards
    return animation
  }

  static func centeredScale(_ bounds: CGRect, scale: Double, translateY: Double) -> CATransform3D {
    var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY + translateY, 0)
    t = CATransform3DScale(t, scale, scale, 1)
    return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
  }

  static func scale(about point: CGPoint, scale: Double, translateY: Double) -> CATransform3D {
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
