import AppKit
import QuartzCore

public struct DownloadsPanelPlacement: Decodable, Equatable, Sendable {
  public var width: Double
  public var left: Double
  public var top: Double?
  public var bottom: Double?
  public var arrow: PopoverArrowEdge
  public var arrowX: Double

  public init(width: Double, left: Double, top: Double? = nil, bottom: Double? = nil, arrow: PopoverArrowEdge, arrowX: Double) {
    self.width = width
    self.left = left
    self.top = top
    self.bottom = bottom
    self.arrow = arrow
    self.arrowX = arrowX
  }
}

public struct DownloadsPanelState: Decodable, Equatable, Sendable {
  public var list: DownloadsListState
  public var placement: DownloadsPanelPlacement
  public var closing: Bool

  public init(list: DownloadsListState, placement: DownloadsPanelPlacement, closing: Bool) {
    self.list = list
    self.placement = placement
    self.closing = closing
  }

  public static func decode(_ json: String) -> DownloadsPanelState? {
    json.data(using: .utf8).flatMap { try? JSONDecoder().decode(DownloadsPanelState.self, from: $0) }
  }
}

public enum DownloadsPanelMetrics {
  public static let radius: CGFloat = 12
  public static let arrowWidth: CGFloat = 20
  public static let arrowHeight: CGFloat = 9
  public static let edge: CGFloat = 0.5
  public static let shadowRadius: CGFloat = 18
  public static let shadowOffsetY: CGFloat = 8
  public static let fromShift = 4.0
}

@MainActor
public final class DownloadsPanelView: NSView {
  public var onEvent: (DownloadsEvent) -> Void = { _ in }
  public var onDismiss: () -> Void = {}
  public var onClosed: () -> Void = {}
  public let list = DownloadsListView(frame: .zero)
  public private(set) var state: DownloadsPanelState?
  private let motion = PrimitiveFlippedView()
  private let card = PrimitiveFlippedView()
  private let bubble = PopoverBubbleView(frame: .zero)
  private var listHeight: CGFloat = 0
  private var tween = RNTween.resting(0)
  private var opened = false
  private var closing = false
  private var closeTimer: Timer?
  private var pressedOutside = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    motion.wantsLayer = true
    addSubview(motion)
    card.wantsLayer = true
    card.layer?.masksToBounds = false
    motion.addSubview(card)
    bubble.cornerRadius = DownloadsPanelMetrics.radius
    bubble.arrowWidth = DownloadsPanelMetrics.arrowWidth
    bubble.arrowHeight = DownloadsPanelMetrics.arrowHeight
    bubble.edgeWidth = DownloadsPanelMetrics.edge
    bubble.shadowRadius = DownloadsPanelMetrics.shadowRadius
    bubble.shadowOffsetY = DownloadsPanelMetrics.shadowOffsetY
    card.addSubview(bubble)
    card.addSubview(list)
    list.onEvent = { [weak self] e in self?.onEvent(e) }
    list.onHeight = { [weak self] h in
      DispatchQueue.main.async {
        guard let self, abs(h - self.listHeight) > 0.25 else { return }
        self.listHeight = h
        self.needsLayout = true
      }
    }
    motion.layer?.opacity = 0
  }

  required init?(coder: NSCoder) { fatalError() }

  public var cardFrame: CGRect? { listHeight > 0 && state != nil ? card.frame : nil }
  public var isClosing: Bool { closing }
  public var progress: Double { tween.value(at: CACurrentMediaTime()) }
  public var presentedOpacity: Double { Double(motion.layer?.presentation()?.opacity ?? motion.layer?.opacity ?? 0) }

  public func update(_ next: DownloadsPanelState) {
    let wasClosing = state?.closing ?? false
    state = next
    let dark = next.list.dark
    bubble.dark = dark
    bubble.tint = CSSColor(dark ? "rgba(38,36,37,0.3)" : "rgba(252,251,252,0.3)")?.ns
    bubble.edgeColor = CSSColor(dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)")?.ns
    bubble.shadowOpacity = dark ? 0.45 : 0.16
    bubble.arrowEdge = next.placement.arrow
    bubble.arrowX = CGFloat(next.placement.arrowX)
    if !next.closing { list.update(next.list) }
    needsLayout = true
    layoutSubtreeIfNeeded()
    if next.closing && !wasClosing { close() } else if !next.closing && closing { reopen() }
  }

  private var arrowRoom: CGFloat { state?.placement.arrow == PopoverArrowEdge.none ? 0 : DownloadsPanelMetrics.arrowHeight }
  private var upward: Bool { state?.placement.bottom != nil }

  public override func layout() {
    super.layout()
    guard let state else { return }
    let p = state.placement
    let width = CGFloat(p.width)
    motion.frame = bounds
    list.frame = CGRect(x: 0, y: upward ? 0 : arrowRoom, width: width, height: max(listHeight, 1))
    guard listHeight > 0 else { return }
    let height = listHeight + arrowRoom
    let y = p.bottom.map { bounds.height - CGFloat($0) - height } ?? CGFloat(p.top ?? 0)
    PrimitiveMotion.setInstantly { card.frame = CGRect(x: CGFloat(p.left), y: y, width: width, height: height) }
    bubble.frame = card.bounds
    if !opened, !closing, window != nil { animate(to: 1) } else { apply(progress: tween.to) }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { needsLayout = true }
  }

  public func close() {
    guard !closing else { return }
    closing = true
    guard opened else { return finishClosing(after: 0) }
    animate(to: 0)
  }

  private func reopen() {
    closing = false
    closeTimer?.invalidate()
    if opened { animate(to: 1) }
  }

  private var origin: CGPoint {
    let f = card.frame
    return CGPoint(x: f.minX + CGFloat(state?.placement.arrowX ?? 0), y: upward ? f.maxY : f.minY)
  }

  private func transform(_ point: CGPoint, _ p: Double) -> CATransform3D {
    let shift = upward ? DownloadsPanelMetrics.fromShift : -DownloadsPanelMetrics.fromShift
    return PrimitiveMotion.scale(about: point, scale: PopoverMetrics.fromScale + (1 - PopoverMetrics.fromScale) * p, translateY: shift * (1 - p))
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
    layer.add(PrimitiveMotion.keyframes("opacity", values, duration: tween.duration, start: now) { NSNumber(value: $0) }, forKey: "downloadsOpacity")
    layer.add(PrimitiveMotion.keyframes("sublayerTransform", values, duration: tween.duration, start: now) { [self] in NSValue(caTransform3D: transform(point, $0)) }, forKey: "downloadsTransform")
    if target == 0 { finishClosing(after: spec.duration) }
  }

  private func finishClosing(after delay: Double) {
    closeTimer?.invalidate()
    closeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.onClosed() }
    }
  }

  private func apply(progress: Double) {
    guard let layer = motion.layer else { return }
    let point = origin
    PrimitiveMotion.setInstantly {
      layer.opacity = Float(opened ? progress : 0)
      layer.sublayerTransform = transform(point, progress)
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    if closing || isHidden { return nil }
    let local = convert(point, from: superview)
    if let frame = cardFrame, frame.contains(local) { return super.hitTest(point) }
    return bounds.contains(local) ? self : nil
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  public override func mouseDown(with event: NSEvent) { pressedOutside = true }

  public override func mouseUp(with event: NSEvent) {
    let was = pressedOutside
    pressedOutside = false
    let local = convert(event.locationInWindow, from: nil)
    if was, bounds.contains(local), !(cardFrame?.contains(local) ?? false) { onDismiss() }
  }
}
