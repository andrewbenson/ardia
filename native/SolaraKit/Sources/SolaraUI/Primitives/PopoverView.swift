import AppKit
import QuartzCore

public struct PopoverPlacement: Decodable, Equatable, Sendable {
  public var width: Double
  public var top: Double
  public var right: Double?
  public var left: Double?
  public var modal: Bool?
  public var fitHeight: Bool?

  public init(width: Double, top: Double, right: Double? = nil, left: Double? = nil, modal: Bool? = nil, fitHeight: Bool? = nil) {
    self.width = width
    self.top = top
    self.right = right
    self.left = left
    self.modal = modal
    self.fitHeight = fitHeight
  }
}

public enum PopoverMetrics {
  public static let open = (duration: 0.15, easing: RNEasing.outCubic)
  public static let close = (duration: 0.1, easing: RNEasing.inQuad)
  public static let fromScale = 0.94
  public static let fromTranslateY = -4.0
  public static let radius: CGFloat = 12
  public static let border: CGFloat = 0.5
  public static let margin: CGFloat = 8
}

public final class PopoverView: NSView {
  public var onDismiss: (() -> Void)?
  public var onClosed: (() -> Void)?

  public let body: NSView
  private let motion = PrimitiveFlippedView()
  private let card = PrimitiveFlippedView()
  private let scroll = NSScrollView()
  private let surface = SurfaceLayer()
  private let effect = NSVisualEffectView()
  private let overlay = CALayer()
  private let rim = SurfaceLayer()
  private var placement = PopoverPlacement(width: 0, top: 0)
  private var bodyHeight: CGFloat = 0
  private var tween = RNTween.resting(0)
  private var opened = false
  private var closing = false
  private var closeTimer: Timer?
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
    surface.radius = PopoverMetrics.radius
    surface.glowColor = .black
    surface.glowRadius = 18
    surface.glowOffset = CGSize(width: 0, height: 8)
    effect.material = .menu
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = PopoverMetrics.radius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    card.addSubview(effect)
    overlay.cornerRadius = PopoverMetrics.radius
    overlay.cornerCurve = .continuous
    overlay.actions = SurfaceLayer.noActions
    effect.layer?.addSublayer(overlay)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = body
    card.addSubview(scroll)
    rim.radius = PopoverMetrics.radius
    rim.border = PopoverMetrics.border
    rim.zPosition = 10
    card.layer?.addSublayer(rim)
    motion.addSubview(card)
    motion.layer?.opacity = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(placement next: PopoverPlacement, dark: Bool) {
    placement = next
    surface.fill = CSSColor(dark ? "rgba(38,36,37,0.94)" : "rgba(252,251,252,0.96)")?.ns
    surface.glowOpacity = dark ? 0.45 : 0.16
    rim.borderTint = CSSColor(dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")?.ns
    effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    PrimitiveMotion.setInstantly { overlay.backgroundColor = CSSColor(dark ? "rgba(38,36,37,0.72)" : "rgba(252,251,252,0.7)")?.cg }
    needsLayout = true
  }

  public func set(bodyHeight next: CGFloat) {
    guard abs(next - bodyHeight) > 0.25 else { return }
    bodyHeight = next
    needsLayout = true
  }

  public var modal: Bool { placement.modal ?? true }
  public var cardFrame: CGRect { card.frame }
  public var progress: Double { tween.value(at: CACurrentMediaTime()) }
  public var isClosing: Bool { closing }
  public var presentedOpacity: Double { Double(motion.layer?.presentation()?.opacity ?? motion.layer?.opacity ?? 0) }

  private var origin: CGPoint {
    let f = card.frame
    return CGPoint(x: placement.right != nil ? f.maxX : f.minX, y: f.minY)
  }

  public override func layout() {
    super.layout()
    let width = CGFloat(placement.width)
    let inner = width - 2 * PopoverMetrics.border
    var height = bodyHeight + 2 * PopoverMetrics.border
    if placement.fitHeight == true { height = min(height, max(0, bounds.height - CGFloat(placement.top) - PopoverMetrics.margin)) }
    let x = placement.right.map { bounds.width - CGFloat($0) - width } ?? CGFloat(placement.left ?? 0)
    motion.frame = bounds
    card.frame = CGRect(x: x, y: CGFloat(placement.top), width: width, height: height)
    PrimitiveMotion.setInstantly {
      surface.frame = card.bounds
      rim.frame = card.bounds
      overlay.frame = card.bounds
    }
    effect.frame = card.bounds
    scroll.frame = CGRect(x: PopoverMetrics.border, y: PopoverMetrics.border, width: inner, height: max(0, height - 2 * PopoverMetrics.border))
    body.frame = CGRect(x: 0, y: 0, width: inner, height: bodyHeight)
    if !opened, !closing, window != nil, bodyHeight > 0 { animate(to: 1) } else { apply(progress: tween.to) }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, !opened, bodyHeight > 0 { needsLayout = true }
  }

  public func close() {
    guard !closing else { return }
    closing = true
    animate(to: 0)
  }

  private func animate(to target: Double) {
    let now = CACurrentMediaTime()
    let spec = target > 0 ? PopoverMetrics.open : PopoverMetrics.close
    if target > 0 { opened = true }
    tween = RNTween(from: tween.value(at: now), to: target, start: now, duration: spec.duration, easing: spec.easing)
    guard let layer = motion.layer else { return }
    let point = origin
    apply(progress: target)
    let values = tween.samples()
    layer.add(PrimitiveMotion.keyframes("opacity", values, duration: tween.duration, start: now) { NSNumber(value: $0) }, forKey: "popoverOpacity")
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", values, duration: tween.duration, start: now) { NSValue(caTransform3D: Self.transform(point, $0)) }, forKey: "popoverTransform")
    closeTimer?.invalidate()
    guard target == 0 else { return }
    closeTimer = Timer.scheduledTimer(withTimeInterval: spec.duration, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClosed?() }
    }
  }

  static func transform(_ point: CGPoint, _ p: Double) -> CATransform3D {
    let scale = PopoverMetrics.fromScale + (1 - PopoverMetrics.fromScale) * p
    return PrimitiveMotion.scale(about: point, scale: scale, translateY: PopoverMetrics.fromTranslateY * (1 - p))
  }

  private func apply(progress: Double) {
    guard let layer = motion.layer else { return }
    let point = origin
    PrimitiveMotion.setInstantly {
      layer.opacity = Float(opened ? progress : 0)
      layer.sublayerTransform = Self.transform(point, progress)
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    if closing { return nil }
    let local = convert(point, from: superview)
    if card.frame.contains(local) { return super.hitTest(point) }
    return modal && onDismiss != nil ? self : nil
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

final class PrimitiveFlippedView: NSView {
  override var isFlipped: Bool { true }
}
