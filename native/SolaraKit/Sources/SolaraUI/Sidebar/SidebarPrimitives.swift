import AppKit
import QuartzCore

final class SurfaceLayer: CALayer {
  var fill: NSColor? { didSet { if fill != oldValue { setNeedsLayout() } } }
  var radius: CGFloat = 0 { didSet { if radius != oldValue { setNeedsLayout() } } }
  var borderTint: NSColor? { didSet { if borderTint != oldValue { setNeedsLayout() } } }
  var border: CGFloat = 0 { didSet { if border != oldValue { setNeedsLayout() } } }
  var borderColors: [NSColor] = [] { didSet { if borderColors != oldValue { setNeedsLayout() } } }
  var glowColor: NSColor? { didSet { if glowColor != oldValue { setNeedsLayout() } } }
  var glowOpacity: Double = 0 { didSet { if glowOpacity != oldValue { setNeedsLayout() } } }
  var glowRadius: CGFloat = 0 { didSet { if glowRadius != oldValue { setNeedsLayout() } } }
  var glowOffset = CGSize(width: 0, height: 0.5) { didSet { if glowOffset != oldValue { setNeedsLayout() } } }

  private let plate = CALayer()
  private let shadowLayer = CALayer()
  private let shadowMask = CAShapeLayer()
  private let borderGradient = CAGradientLayer()
  private let borderStroke = CAShapeLayer()

  override init() {
    super.init()
    setUp()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError() }

  private func setUp() {
    masksToBounds = false
    shadowMask.fillRule = .evenOdd
    shadowLayer.mask = shadowMask
    borderStroke.fillColor = nil
    borderStroke.strokeColor = NSColor.black.cgColor
    borderGradient.mask = borderStroke
    for layer in [shadowLayer, plate, borderGradient] as [CALayer] { addSublayer(layer) }
    for layer in [self, plate, shadowLayer, shadowMask, borderGradient, borderStroke] as [CALayer] { layer.actions = Self.noActions }
  }

  nonisolated(unsafe) static let noActions: [String: CAAction] = [
    "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(),
    "cornerRadius": NSNull(), "shadowOpacity": NSNull(), "shadowPath": NSNull(), "shadowColor": NSNull(), "shadowRadius": NSNull(), "path": NSNull(),
    "colors": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "sublayers": NSNull(), "mask": NSNull(), "transform": NSNull(),
  ]

  override func layoutSublayers() {
    super.layoutSublayers()
    apply()
  }

  func apply() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let rect = bounds
    plate.frame = rect
    plate.cornerRadius = radius
    plate.cornerCurve = .continuous
    plate.backgroundColor = fill?.cgColor
    if borderColors.count >= 2, border > 0 {
      plate.borderWidth = 0
      borderGradient.isHidden = false
      borderGradient.frame = rect
      borderGradient.colors = borderColors.map(\.cgColor)
      borderGradient.startPoint = CGPoint(x: 0.5, y: 0)
      borderGradient.endPoint = CGPoint(x: 0.5, y: 1)
      let inset = border / 2
      borderStroke.frame = rect
      borderStroke.lineWidth = border
      borderStroke.path = CGPath(
        roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: max(radius - inset, 0), cornerHeight: max(radius - inset, 0), transform: nil)
    } else {
      borderGradient.isHidden = true
      plate.borderColor = borderTint?.cgColor
      plate.borderWidth = border
    }
    if let glowColor, glowOpacity > 0 {
      let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
      shadowLayer.isHidden = false
      shadowLayer.frame = rect
      shadowLayer.shadowColor = glowColor.cgColor
      shadowLayer.shadowOpacity = Float(glowOpacity)
      shadowLayer.shadowRadius = glowRadius
      shadowLayer.shadowOffset = glowOffset
      shadowLayer.shadowPath = shape
      let outset = glowRadius * 3 + abs(glowOffset.height) + abs(glowOffset.width) + 4
      let mask = CGMutablePath()
      mask.addRect(rect.insetBy(dx: -outset, dy: -outset))
      mask.addPath(shape)
      shadowMask.frame = rect
      shadowMask.path = mask
    } else {
      shadowLayer.isHidden = true
    }
  }
}

final class FadeLabel: NSView {
  private let field = NSTextField(labelWithString: "")
  private let fade = CAGradientLayer()
  private var fontSize: CGFloat = 13
  private var weight: NSFont.Weight = .regular

  var text = "" { didSet { if text != oldValue { field.stringValue = text; relayout() } } }
  var color: NSColor = .labelColor { didSet { if color != oldValue { field.textColor = color } } }
  var fadeWidth: CGFloat = 24 { didSet { relayout() } }

  override var isFlipped: Bool { true }

  init(fontSize: CGFloat = 13, weight: NSFont.Weight = .regular) {
    self.fontSize = fontSize
    self.weight = weight
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    field.lineBreakMode = .byClipping
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = false
    field.isSelectable = false
    field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    field.wantsLayer = true
    addSubview(field)
    fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.actions = SurfaceLayer.noActions
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { relayout() }
  }

  var textWidth: CGFloat { field.fittingSize.width }

  private func relayout() {
    let fitting = field.fittingSize
    field.frame = NSRect(x: 0, y: (bounds.height - fitting.height) / 2, width: max(bounds.width, fitting.width), height: fitting.height)
    guard bounds.width > 0, fitting.width > bounds.width + 0.5 else {
      field.layer?.mask = nil
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: field.frame.height)
    let start = max(0, 1 - fadeWidth / bounds.width)
    fade.locations = [0, NSNumber(value: Double(start)), 1]
    field.layer?.mask = fade
    CATransaction.commit()
  }
}

final class SpinnerView: NSView {
  private let track = CAShapeLayer()
  private let ring = CAShapeLayer()

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for shape in [track, ring] {
      shape.fillColor = nil
      shape.lineWidth = 1.5
      shape.actions = SurfaceLayer.noActions
      layer?.addSublayer(shape)
    }
    ring.lineCap = .round
    ring.strokeStart = 0
    ring.strokeEnd = 0.72
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let path = CGPath(ellipseIn: bounds.insetBy(dx: 1.25, dy: 1.25), transform: nil)
    for shape in [track, ring] {
      shape.frame = bounds
      shape.path = path
    }
    CATransaction.commit()
    recolor()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    recolor()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    spin()
  }

  override func viewDidHide() {
    super.viewDidHide()
    spin()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    spin()
  }

  private func recolor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
      ring.strokeColor = NSColor.secondaryLabelColor.cgColor
    }
  }

  private func spin() {
    guard window != nil, !isHiddenOrHasHiddenAncestor else { return ring.removeAnimation(forKey: "activityRotation") }
    guard ring.animation(forKey: "activityRotation") == nil else { return }
    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = 2 * Double.pi
    turn.duration = 1.88
    turn.repeatCount = .infinity
    turn.timingFunction = CAMediaTimingFunction(name: .linear)
    turn.isRemovedOnCompletion = false
    ring.add(turn, forKey: "activityRotation")
  }
}

final class SymbolView: NSView {
  private let imageView = NSImageView()
  private var shown: (name: String, size: CGFloat, weight: NSFont.Weight)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    imageView.imageScaling = .scaleNone
    imageView.autoresizingMask = [.width, .height]
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    imageView.frame = bounds
  }

  func set(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    if shown?.name != name || shown?.size != size || shown?.weight != weight {
      shown = (name, size, weight)
      imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
    if imageView.contentTintColor != color { imageView.contentTintColor = color }
  }
}

enum SidebarSymbol {
  static func weight(_ name: String) -> NSFont.Weight {
    switch name {
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "light": .light
    default: .regular
    }
  }
}
