import AppKit
import QuartzCore

public struct CliPillState: Decodable, Equatable, Sendable {
  public var shown: Bool
  public var command: String
  public var product: String
  public var theme: MediaThemeState

  public static func decode(_ json: String) -> CliPillState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(CliPillState.self, from: data)
  }
}

public final class CliControlPillView: NSView {
  public static let height: CGFloat = 32
  public static let bottom: CGFloat = 12
  public static let sideInset: CGFloat = 12
  public static let border: CGFloat = 0.5
  static let appear = (duration: 0.16, easing: RNEasing.outCubic)
  static let hide = (duration: 0.2, easing: RNEasing.inQuad)

  public var onStop: (() -> Void)?

  private let motion = NSView()
  private let surface = SurfaceLayer()
  private let badge = CALayer()
  private let glyph = SymbolView()
  private let label = NSTextField(labelWithString: "")
  private let stop = MediaTextButton(title: "Stop", fontSize: 12, weight: .medium)
  private var state: CliPillState?
  private var tween = RNTween.resting(0)
  private var settleTimer: Timer?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    motion.wantsLayer = true
    motion.layer?.addSublayer(surface)
    badge.actions = SurfaceLayer.noActions
    badge.cornerRadius = 10
    motion.layer?.addSublayer(badge)
    motion.addSubview(glyph)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    label.isSelectable = false
    motion.addSubview(label)
    stop.radius = (Self.height - 8) / 2
    stop.paddingX = 10
    stop.onPress = { [weak self] in self?.onStop?() }
    motion.addSubview(stop)
    motion.setAccessibilityElement(true)
    motion.setAccessibilityRole(.group)
    motion.setAccessibilityChildren([stop])
    addSubview(motion)
    apply(progress: 0)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard state?.shown == true, !motion.isHidden else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public var shown: Bool { state?.shown ?? false }
  public var progress: Double { tween.value(at: CACurrentMediaTime()) }
  public var pillFrame: CGRect { motion.frame }
  public var stopTitleClipped: Bool { stop.titleClipped }
  var stopWidth: CGFloat { stop.frame.width }

  public func update(_ next: CliPillState) {
    let first = state == nil
    let wasShown = state?.shown ?? false
    state = next
    paint(next)
    needsLayout = true
    layoutSubtreeIfNeeded()
    if first {
      tween = .resting(next.shown ? 1 : 0)
      apply(progress: tween.to)
    } else if wasShown != next.shown {
      animate(to: next.shown ? 1 : 0)
    }
  }

  private func paint(_ state: CliPillState) {
    let palette = MediaPalette(state.theme)
    surface.fill = palette.panel
    surface.radius = (Self.height + 2 * Self.border) / 2
    surface.borderTint = palette.panelBorder
    surface.border = Self.border
    surface.glowColor = .black
    surface.glowOpacity = palette.panelShadowOpacity
    surface.glowRadius = 14
    surface.glowOffset = CGSize(width: 0, height: 4)
    MediaMotion.setInstantly { badge.backgroundColor = palette.textPrimary.cgColor }
    glyph.set("terminal.fill", size: 9, weight: .bold, color: palette.dark ? .black : .white)
    let text = NSMutableAttributedString(
      string: state.command, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: palette.textPrimary])
    text.append(NSAttributedString(string: " is controlling \(state.product)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: palette.textSecondary]))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    label.attributedStringValue = text
    stop.colors = (rest: palette.urlPill, hover: palette.toolbarHover, pressed: palette.toolbarPressed, text: palette.textPrimary)
    motion.setAccessibilityLabel("The \(state.command) command is controlling \(state.product)")
  }

  public override func layout() {
    super.layout()
    let border = Self.border
    let available = max(0, bounds.width - 2 * Self.sideInset)
    let stopSize = stop.fittingSize
    let textNatural = MediaText.pointCeil(label.attributedStringValue.size().width)
    let fixed: CGFloat = 2 * border + 6 + 20 + 8 + 8 + stopSize.width + 4
    let textWidth = max(0, min(textNatural, available - fixed))
    let width = min(available, fixed + textWidth)
    let height = Self.height + 2 * border
    let frame = CGRect(x: MediaText.pointRound((bounds.width - width) / 2), y: bounds.height - Self.bottom - height, width: width, height: height)
    if motion.frame != frame { motion.frame = frame }
    MediaMotion.setInstantly {
      surface.frame = motion.bounds
      badge.frame = CGRect(x: border + 6, y: border + 6, width: 20, height: 20)
    }
    glyph.frame = CGRect(x: border + 9, y: border + 9, width: 14, height: 14)
    let labelHeight = ceil(label.intrinsicContentSize.height)
    label.frame = CGRect(x: border + 34 - MediaText.inset, y: border + ((Self.height - labelHeight) / 2).rounded(), width: textWidth + 2 * MediaText.inset, height: labelHeight)
    stop.frame = CGRect(x: width - border - 4 - stopSize.width, y: border + 4, width: stopSize.width, height: Self.height - 8)
    apply(progress: tween.to)
  }

  private func animate(to target: Double) {
    let now = CACurrentMediaTime()
    let from = tween.value(at: now)
    let spec = target > from ? Self.appear : Self.hide
    tween = RNTween(from: from, to: target, start: now, duration: spec.duration, easing: spec.easing)
    guard let layer = motion.layer else { return }
    motion.isHidden = false
    let bounds = motion.bounds
    apply(progress: target)
    let fade = MediaMotion.keyframes("opacity", tween) { NSNumber(value: $0) }
    let move = MediaMotion.keyframes("sublayerTransform", tween) {
      NSValue(caTransform3D: MediaMotion.centeredScale(bounds, scale: 0.96 + 0.04 * $0, translateY: 8 * (1 - $0)))
    }
    layer.add(fade, forKey: "cliPillOpacity")
    layer.add(move, forKey: "cliPillTransform")
    settleTimer?.invalidate()
    settleTimer = Timer.scheduledTimer(withTimeInterval: spec.duration, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.settle() }
    }
  }

  private func settle() {
    settleTimer = nil
    apply(progress: tween.to)
  }

  private func apply(progress: Double) {
    guard let layer = motion.layer else { return }
    MediaMotion.setInstantly {
      layer.opacity = Float(progress)
      layer.sublayerTransform = MediaMotion.centeredScale(motion.bounds, scale: 0.96 + 0.04 * progress, translateY: 8 * (1 - progress))
    }
    let hidden = progress == 0 && tween.finished(at: CACurrentMediaTime())
    if motion.isHidden != hidden { motion.isHidden = hidden }
  }
}

final class MediaTextButton: NSView {
  private let plate = CALayer()
  private let label = NSTextField(labelWithString: "")
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { paint() } } }
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }
  var colors: (rest: NSColor, hover: NSColor, pressed: NSColor, text: NSColor) = (.clear, .clear, .clear, .labelColor) { didSet { paint() } }
  var radius: CGFloat = 6 { didSet { plate.cornerRadius = radius } }
  var paddingX: CGFloat = 10 { didSet { invalidateIntrinsicContentSize() } }
  var onPress: (() -> Void)?

  override var isFlipped: Bool { true }

  init(title: String, fontSize: CGFloat, weight: NSFont.Weight) {
    super.init(frame: .zero)
    DevPointer.observe(self, #selector(devPointerChanged(_:)))
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerCurve = .continuous
    layer?.addSublayer(plate)
    label.stringValue = title
    label.font = .systemFont(ofSize: fontSize, weight: weight)
    label.lineBreakMode = .byTruncatingTail
    label.isSelectable = false
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func devPointerChanged(_ note: Notification) {
    hovered = DevPointer.inside(self, note)
  }

  var title: String {
    get { label.stringValue }
    set {
      guard label.stringValue != newValue else { return }
      label.stringValue = newValue
      setAccessibilityLabel(newValue)
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }

  var titleClipped: Bool { label.frame.width < label.intrinsicContentSize.width }

  override var fittingSize: NSSize {
    let text = label.intrinsicContentSize
    return NSSize(width: MediaText.pointCeil(label.attributedStringValue.size().width) + 2 * paddingX, height: ceil(text.height))
  }

  override func layout() {
    super.layout()
    MediaMotion.setInstantly { plate.frame = bounds }
    let text = label.intrinsicContentSize
    label.frame = CGRect(x: paddingX - MediaText.inset, y: ((bounds.height - text.height) / 2).rounded(), width: max(0, bounds.width - 2 * paddingX + 2 * MediaText.inset), height: text.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovered = false; pressed = false }
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseDragged(with event: NSEvent) {
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  private func paint() {
    MediaMotion.setInstantly { plate.backgroundColor = (pressed ? colors.pressed : hovered ? colors.hover : colors.rest).cgColor }
    label.textColor = colors.text
  }
}

enum MediaText {
  static let inset: CGFloat = 2

  static func pointCeil(_ width: CGFloat) -> CGFloat { (width * 2).rounded(.up) / 2 }

  static func pointRound(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}
