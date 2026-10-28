import AppKit
import QuartzCore

public enum AutoHideStripEvent: Equatable, Sendable {
  case reveal
  case peek(Bool)
}

public struct AutoHideStripStyle: Equatable, Sendable {
  public var card: CSSColor
  public var band: CSSColor
  public var divider: CSSColor
  public var secondary: CSSColor
  public var host: String
  public var hasPage: Bool

  public init(card: CSSColor, band: CSSColor, divider: CSSColor, secondary: CSSColor, host: String, hasPage: Bool) {
    self.card = card
    self.band = band
    self.divider = divider
    self.secondary = secondary
    self.host = host
    self.hasPage = hasPage
  }
}

public struct AutoHideFrame: Equatable, Sendable {
  public var bar: Double
  public var fade: Double
  public var liveTop: Double
  public var interactive: Bool
  public var controlsOpacity: Double { ToolbarAutoHideCurves.controlsOpacity(fade: fade) }
  public var toolbarScale: Double { ToolbarAutoHideCurves.toolbarScale(bar: bar) }
  public var toolbarLift: Double { ToolbarAutoHideCurves.toolbarLift(bar: bar) }
}

@MainActor
public final class AutoHideStripView: NSView {
  public var onEvent: (AutoHideStripEvent) -> Void = { _ in }
  public var onFrame: (AutoHideFrame) -> Void = { _ in }
  public var onMotion: (Bool) -> Void = { _ in }

  private let backdrop = CALayer()
  private let band = CALayer()
  private let divider = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var style: AutoHideStripStyle?
  private var mode = ToolbarAutoHideMode.shown
  private var shownTop: Double = Double(ToolbarAutoHideMetrics.toolbarHeight)
  private var page = RNTween.resting(0)
  private var bar = RNTween.resting(0)
  private var fade = RNTween.resting(0)
  private var laid: Double = 0
  private var moved = false
  private var configured = false
  private var link: CADisplayLink?
  private var peekTimer: Timer?
  private var tracking: NSTrackingArea?
  public var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [backdrop, band, divider] { l.actions = SurfaceLayer.noActions }
    backdrop.addSublayer(band)
    layer?.addSublayer(backdrop)
    layer?.addSublayer(divider)
    label.font = .systemFont(ofSize: ToolbarAutoHideMetrics.labelSize, weight: .medium)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.alphaValue = 0
    label.toolTip = "Show Toolbar"
    label.setAccessibilityRole(.button)
    label.setAccessibilityLabel("Show Toolbar")
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var restingTop: Double {
    ToolbarAutoHideCurves.liveTop(laid: laid, page: page.to, collapsed: mode != .shown, shownTop: shownTop)
  }

  public func set(style next: AutoHideStripStyle, mode nextMode: ToolbarAutoHideMode, shownTop top: Double) {
    style = next
    shownTop = top
    PrimitiveMotion.setInstantly {
      backdrop.backgroundColor = next.card.cg
      band.backgroundColor = next.band.cg
      divider.backgroundColor = next.divider.cg
      divider.isHidden = !next.hasPage
    }
    label.stringValue = next.host
    label.textColor = next.secondary.ns
    if !configured {
      configured = true
      jump(to: nextMode)
    } else if nextMode != mode {
      transition(to: nextMode)
    }
    needsLayout = true
  }

  private func jump(to next: ToolbarAutoHideMode) {
    mode = next
    moved = next != .shown
    let collapsed = next != .shown
    page = .resting(collapsed ? 1 : 0)
    bar = .resting(next == .collapsed ? 1 : 0)
    fade = .resting(next == .collapsed ? 1 : 0)
    laid = collapsed ? 1 : 0
    tick()
  }

  private func transition(to next: ToolbarAutoHideMode) {
    let now = CACurrentMediaTime()
    let current = (page: page.value(at: now), bar: bar.value(at: now), fade: fade.value(at: now))
    defer { mode = next }
    if next != .shown { moved = true }
    guard let t = ToolbarAutoHideTransition.between(mode, next, current: current, at: now, reduceMotion: reduceMotion) else { return }
    page = t.page
    bar = t.bar
    fade = t.fade
    laid = t.laid
    onMotion(true)
    startLink()
    tick()
  }

  private func startLink() {
    guard link == nil else { return }
    let made = displayLink(target: self, selector: #selector(step))
    made.add(to: .main, forMode: .common)
    link = made
  }

  @objc private func step() { tick() }

  private func tick() {
    let now = CACurrentMediaTime()
    let b = bar.value(at: now)
    let f = fade.value(at: now)
    let p = page.value(at: now)
    let top = ToolbarAutoHideCurves.liveTop(laid: laid, page: p, collapsed: mode != .shown, shownTop: shownTop)
    apply(bar: b, fade: f)
    onFrame(AutoHideFrame(bar: b, fade: f, liveTop: top, interactive: mode != .collapsed))
    if page.finished(at: now), bar.finished(at: now), fade.finished(at: now) {
      link?.invalidate()
      link = nil
      onMotion(false)
    }
  }

  private func apply(bar b: Double, fade f: Double) {
    let h = Double(ToolbarAutoHideMetrics.toolbarHeight)
    PrimitiveMotion.setInstantly {
      backdrop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
      band.frame = backdrop.bounds
      if moved {
        let scale = ToolbarAutoHideCurves.bandScale(bar: b)
        var t = CATransform3DMakeTranslation(0, ToolbarAutoHideCurves.bandLift(bar: b), 0)
        t = CATransform3DTranslate(t, 0, h / 2, 0)
        t = CATransform3DScale(t, 1, scale, 1)
        backdrop.transform = CATransform3DTranslate(t, 0, -h / 2, 0)
        divider.frame = CGRect(x: 0, y: h - 1 + ToolbarAutoHideCurves.dividerLift(bar: b), width: bounds.width, height: 1)
      } else {
        backdrop.transform = CATransform3DIdentity
        divider.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
      }
    }
    label.alphaValue = moved ? ToolbarAutoHideCurves.labelOpacity(fade: f) : 0
  }

  public override func layout() {
    super.layout()
    let strip = ToolbarAutoHideMetrics.stripHeight
    label.frame = CGRect(x: ToolbarAutoHideMetrics.labelPadding, y: (strip - 14) / 2, width: max(0, bounds.width - 2 * ToolbarAutoHideMetrics.labelPadding), height: 14)
    let now = CACurrentMediaTime()
    apply(bar: bar.value(at: now), fade: fade.value(at: now))
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let made = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
    addTrackingArea(made)
    tracking = made
  }

  private func inStrip(_ event: NSEvent) -> Bool {
    convert(event.locationInWindow, from: nil).y < ToolbarAutoHideMetrics.stripHeight
  }

  public override func mouseMoved(with event: NSEvent) {
    if mode == .collapsed {
      if inStrip(event) { peekLater(true, ToolbarAutoHideMetrics.peekDelay) } else { peekTimer?.invalidate() }
    }
  }

  public override func mouseEntered(with event: NSEvent) {
    if mode == .peek { peekTimer?.invalidate() } else { mouseMoved(with: event) }
  }

  public override func mouseExited(with event: NSEvent) {
    if mode == .peek { peekLater(false, ToolbarAutoHideMetrics.unpeekDelay) } else if mode == .collapsed { peekTimer?.invalidate() }
  }

  private func peekLater(_ on: Bool, _ delay: TimeInterval) {
    peekTimer?.invalidate()
    peekTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.onEvent(.peek(on)) }
    }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard mode == .collapsed else { return nil }
    let local = convert(point, from: superview)
    return local.y < ToolbarAutoHideMetrics.stripHeight && local.y >= 0 ? self : nil
  }

  public override func mouseUp(with event: NSEvent) {
    guard mode == .collapsed, inStrip(event) else { return }
    peekTimer?.invalidate()
    onEvent(.reveal)
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil {
      link?.invalidate()
      link = nil
      peekTimer?.invalidate()
    }
  }
}
