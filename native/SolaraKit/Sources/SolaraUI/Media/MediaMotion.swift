import AppKit
import QuartzCore

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
