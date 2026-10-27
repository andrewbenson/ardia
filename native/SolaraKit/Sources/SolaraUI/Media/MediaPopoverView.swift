import AppKit
import QuartzCore

public struct MediaPopoverPlacement: Decodable, Equatable, Sendable {
  public var width: Double
  public var top: Double
  public var right: Double?
  public var left: Double?

  public init(width: Double, top: Double, right: Double? = nil, left: Double? = nil) {
    self.width = width
    self.top = top
    self.right = right
    self.left = left
  }
}

public enum MediaPopoverMotion {
  public static let open = (duration: 0.15, easing: RNEasing.outCubic)
  public static let fromScale = 0.94
  public static let fromTranslateY = -4.0
  public static let radius: CGFloat = 12
  public static let border: CGFloat = 0.5
}

public final class MediaPopoverView: NSView {
  public var onDismiss: (() -> Void)?

  public let body: NSView
  private let motion = FlippedDocument()
  private let card = FlippedDocument()
  private let surface = SurfaceLayer()
  private let effect = NSVisualEffectView()
  private let overlay = CALayer()
  private let rim = SurfaceLayer()
  private var placement = MediaPopoverPlacement(width: 0, top: 0)
  private var bodyHeight: CGFloat = 0
  private var dark = true
  private var tween = RNTween.resting(0)
  private var opened = false
  private var pressedOutside = false

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { body.acceptsFirstResponder }

  public init(body: NSView) {
    self.body = body
    super.init(frame: .zero)
    wantsLayer = true
    motion.wantsLayer = true
    addSubview(motion)
    card.wantsLayer = true
    card.layer?.masksToBounds = false
    card.layer?.addSublayer(surface)
    surface.radius = MediaPopoverMotion.radius
    surface.glowColor = .black
    surface.glowRadius = 18
    surface.glowOffset = CGSize(width: 0, height: 8)
    effect.material = .menu
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = MediaPopoverMotion.radius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    card.addSubview(effect)
    overlay.cornerRadius = MediaPopoverMotion.radius
    overlay.cornerCurve = .continuous
    overlay.actions = SurfaceLayer.noActions
    effect.layer?.addSublayer(overlay)
    card.addSubview(body)
    rim.radius = MediaPopoverMotion.radius
    rim.border = MediaPopoverMotion.border
    rim.zPosition = 10
    card.layer?.addSublayer(rim)
    motion.addSubview(card)
    motion.layer?.opacity = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(placement next: MediaPopoverPlacement, dark nextDark: Bool) {
    placement = next
    dark = nextDark
    surface.fill = MediaPalette.parse(dark ? "rgba(38,36,37,0.94)" : "rgba(252,251,252,0.96)")
    surface.glowOpacity = dark ? 0.45 : 0.16
    rim.borderTint = MediaPalette.parse(dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")
    effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    MediaMotion.setInstantly { overlay.backgroundColor = MediaPalette.parse(dark ? "rgba(38,36,37,0.72)" : "rgba(252,251,252,0.7)")?.cgColor }
    needsLayout = true
  }

  public func set(bodyHeight next: CGFloat) {
    guard abs(next - bodyHeight) > 0.25 else { return }
    bodyHeight = next
    needsLayout = true
  }

  public var cardFrame: CGRect { card.frame }
  public var progress: Double { tween.value(at: CACurrentMediaTime()) }
  public var presentedOpacity: Double { Double(motion.layer?.presentation()?.opacity ?? motion.layer?.opacity ?? 0) }

  private var origin: CGPoint {
    let f = card.frame
    return CGPoint(x: placement.right != nil ? f.maxX : f.minX, y: f.minY)
  }

  public override func layout() {
    super.layout()
    let width = CGFloat(placement.width)
    let height = bodyHeight + 2 * MediaPopoverMotion.border
    let x = placement.right.map { bounds.width - CGFloat($0) - width } ?? CGFloat(placement.left ?? 0)
    motion.frame = bounds
    card.frame = CGRect(x: x, y: CGFloat(placement.top), width: width, height: height)
    MediaMotion.setInstantly {
      surface.frame = card.bounds
      rim.frame = card.bounds
      overlay.frame = card.bounds
    }
    effect.frame = card.bounds
    body.frame = CGRect(x: MediaPopoverMotion.border, y: MediaPopoverMotion.border, width: width - 2 * MediaPopoverMotion.border, height: bodyHeight)
    if !opened, window != nil, bodyHeight > 0 { open() } else { apply(progress: tween.to) }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, !opened, bodyHeight > 0 { needsLayout = true }
  }

  private func open() {
    opened = true
    let now = CACurrentMediaTime()
    tween = RNTween(from: 0, to: 1, start: now, duration: MediaPopoverMotion.open.duration, easing: MediaPopoverMotion.open.easing)
    guard let layer = motion.layer else { return }
    let point = origin
    apply(progress: 1)
    layer.add(MediaMotion.keyframes("opacity", tween) { NSNumber(value: $0) }, forKey: "popoverOpacity")
    layer.add(MediaMotion.keyframes("sublayerTransform", tween) { NSValue(caTransform3D: Self.transform(point, $0)) }, forKey: "popoverTransform")
  }

  private static func transform(_ point: CGPoint, _ p: Double) -> CATransform3D {
    let scale = MediaPopoverMotion.fromScale + (1 - MediaPopoverMotion.fromScale) * p
    return MediaMotion.scale(about: point, scale: scale, translateY: MediaPopoverMotion.fromTranslateY * (1 - p))
  }

  private func apply(progress: Double) {
    guard let layer = motion.layer else { return }
    let point = origin
    MediaMotion.setInstantly {
      layer.opacity = Float(opened ? progress : 0)
      layer.sublayerTransform = Self.transform(point, progress)
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if card.frame.contains(local) { return super.hitTest(point) }
    return onDismiss == nil ? nil : self
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func mouseDown(with event: NSEvent) { pressedOutside = true }

  public override func mouseUp(with event: NSEvent) {
    let was = pressedOutside
    pressedOutside = false
    let local = convert(event.locationInWindow, from: nil)
    if was, bounds.contains(local), !card.frame.contains(local) { onDismiss?() }
  }

  public override func keyDown(with event: NSEvent) {
    if body.acceptsFirstResponder { body.keyDown(with: event) } else { super.keyDown(with: event) }
  }
}
