import AppKit
import QuartzCore

public enum PopoverArrowEdge: String, Decodable, Sendable {
  case top, bottom, none
}

@MainActor
public final class PopoverBubbleView: NSView {
  public var cornerRadius: CGFloat = 12 { didSet { needsLayout = true } }
  public var arrowEdge: PopoverArrowEdge = .none { didSet { needsLayout = true } }
  public var arrowX: CGFloat = 0 { didSet { needsLayout = true } }
  public var arrowWidth: CGFloat = 20 { didSet { needsLayout = true } }
  public var arrowHeight: CGFloat = 9 { didSet { needsLayout = true } }
  public var tint: NSColor? { didSet { needsLayout = true } }
  public var edgeColor: NSColor? { didSet { needsLayout = true } }
  public var edgeWidth: CGFloat = 0 { didSet { needsLayout = true } }
  public var shadowOpacity: Double = 0 { didSet { needsLayout = true } }
  public var shadowRadius: CGFloat = 0 { didSet { needsLayout = true } }
  public var shadowOffsetY: CGFloat = 0 { didSet { needsLayout = true } }

  private let effect = NSVisualEffectView()
  private let overlay = PrimitiveFlippedView()
  private let shadowLayer = CALayer()
  private let shadowMask = CAShapeLayer()
  private let tintLayer = CAShapeLayer()
  private let edgeLayer = CAShapeLayer()
  private let edgeMask = CAShapeLayer()
  private var maskKey = ""

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    effect.state = .active
    effect.blendingMode = .withinWindow
    effect.material = .popover
    addSubview(effect)
    overlay.wantsLayer = true
    overlay.layer?.masksToBounds = false
    shadowMask.fillRule = .evenOdd
    shadowLayer.mask = shadowMask
    shadowLayer.shadowColor = NSColor.black.cgColor
    edgeLayer.fillColor = nil
    edgeLayer.mask = edgeMask
    overlay.layer?.addSublayer(shadowLayer)
    overlay.layer?.addSublayer(tintLayer)
    overlay.layer?.addSublayer(edgeLayer)
    addSubview(overlay)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var dark: Bool = false { didSet { effect.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) } }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public override func layout() {
    super.layout()
    apply()
  }

  public static func shape(size: CGSize, radius: CGFloat, edge: PopoverArrowEdge, arrowX: CGFloat, arrowWidth: CGFloat, arrowHeight: CGFloat) -> CGPath {
    let lift = edge == .none ? 0 : min(arrowHeight, size.height)
    let body = CGRect(x: 0, y: lift, width: size.width, height: size.height - lift)
    let r = max(0, min(radius, body.width / 2, body.height / 2))
    let half = arrowWidth / 2
    guard edge != .none, half > 0, body.width >= 2 * (r + half) else {
      return CGPath(roundedRect: body, cornerWidth: r, cornerHeight: r, transform: nil)
    }
    let x = min(max(arrowX, r + half), body.width - r - half)
    let top = body.minY
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r, y: top))
    path.addArc(tangent1End: CGPoint(x: x - half, y: top), tangent2End: CGPoint(x: x, y: 0), radius: 3)
    path.addArc(tangent1End: CGPoint(x: x, y: 0), tangent2End: CGPoint(x: x + half, y: top), radius: 2.5)
    path.addArc(tangent1End: CGPoint(x: x + half, y: top), tangent2End: CGPoint(x: body.maxX - r, y: top), radius: 3)
    path.addArc(tangent1End: CGPoint(x: body.maxX, y: top), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
    path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
    path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: top), radius: r)
    path.addArc(tangent1End: CGPoint(x: body.minX, y: top), tangent2End: CGPoint(x: r, y: top), radius: r)
    path.closeSubpath()
    if edge == .top { return path }
    var flip = CGAffineTransform(translationX: 0, y: size.height).scaledBy(x: 1, y: -1)
    return path.copy(using: &flip) ?? path
  }

  private func apply() {
    let size = bounds.size
    effect.frame = bounds
    overlay.frame = bounds
    guard size.width > 0, size.height > 0 else { return }
    let path = Self.shape(size: size, radius: cornerRadius, edge: arrowEdge, arrowX: arrowX, arrowWidth: arrowWidth, arrowHeight: arrowHeight)
    let key = "\(size.width)x\(size.height) \(cornerRadius) \(arrowEdge.rawValue) \(arrowX) \(arrowWidth) \(arrowHeight)"
    if key != maskKey {
      maskKey = key
      effect.maskImage = NSImage(size: size, flipped: true) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.fillPath()
        return true
      }
    }
    PrimitiveMotion.setInstantly {
      let local = overlay.bounds
      tintLayer.frame = local
      tintLayer.path = path
      tintLayer.fillColor = tint?.cgColor
      edgeLayer.frame = local
      edgeMask.frame = local
      edgeMask.path = path
      edgeLayer.path = path
      edgeLayer.lineWidth = edgeWidth * 2
      edgeLayer.strokeColor = edgeColor?.cgColor
      edgeLayer.isHidden = edgeColor == nil || edgeWidth <= 0
      shadowLayer.frame = local
      shadowLayer.isHidden = shadowOpacity <= 0
      guard shadowOpacity > 0 else { return }
      shadowLayer.shadowOpacity = Float(shadowOpacity)
      shadowLayer.shadowRadius = shadowRadius
      shadowLayer.shadowOffset = CGSize(width: 0, height: shadowOffsetY)
      shadowLayer.shadowPath = path
      let outset = shadowRadius * 3 + abs(shadowOffsetY) + 4
      let mask = CGMutablePath()
      mask.addRect(local.insetBy(dx: -outset, dy: -outset))
      mask.addPath(path)
      shadowMask.frame = local
      shadowMask.path = mask
    }
  }
}
