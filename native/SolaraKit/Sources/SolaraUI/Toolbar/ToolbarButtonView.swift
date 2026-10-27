import AppKit

final class ToolbarButtonView: NSView {
  var state: ToolbarButtonState { didSet { if state != oldValue { apply() } } }
  var palette: ToolbarPaletteState { didSet { if palette != oldValue { apply() } } }
  var onClick: (ToolbarClick) -> Void = { _ in }
  var forcedHover = false { didSet { apply() } }

  private let plate = CALayer()
  private let image = NSImageView()
  private var hovered = false
  private var pressed = false
  private var longPressTimer: Timer?
  private var longPressFired = false
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  var box: CGFloat { CGFloat(state.box ?? 30) }

  init(state: ToolbarButtonState, palette: ToolbarPaletteState) {
    self.state = state
    self.palette = palette
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(plate)
    image.imageScaling = .scaleNone
    addSubview(image)
    apply()
  }

  required init?(coder: NSCoder) { fatalError() }

  var enabled: Bool { state.enabled ?? true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    apply()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard enabled || state.menu == true else { return nil }
    return super.hitTest(point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    pressed = true
    longPressFired = false
    apply()
    if state.longPress == true {
      longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.pressed else { return }
          self.longPressFired = true
          self.pressed = false
          self.apply()
          self.onClick(ToolbarClick(id: self.state.id, kind: .menu))
        }
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    longPressTimer?.invalidate()
    longPressTimer = nil
    let wasPressed = pressed
    pressed = false
    apply()
    guard wasPressed, !longPressFired, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick(ToolbarClick(id: state.id, kind: .press, flags: event.modifierFlags))
  }

  override func rightMouseDown(with event: NSEvent) {
    guard state.menu == true, enabled else { return super.rightMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .menu))
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2, state.middle == true, enabled else { return super.otherMouseDown(with: event) }
    onClick(ToolbarClick(id: state.id, kind: .middle, flags: event.modifierFlags))
  }

  override func layout() {
    super.layout()
    apply()
  }

  func apply() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let b = box
    plate.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    plate.cornerRadius = CGFloat(state.radius ?? 7)
    let plain = state.plain == true
    let background: String? =
      plain || !enabled ? nil : pressed || state.active == true ? palette.pressed : (hovered || forcedHover) ? palette.hover : nil
    plate.backgroundColor = toolbarColor(background)?.cgColor
    CATransaction.commit()
    let tint = toolbarColor(state.color) ?? toolbarColor(enabled ? palette.icon : palette.iconDisabled) ?? .labelColor
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(state.size ?? 15), weight: ToolbarButtonView.weight(state.weight))
    image.image = NSImage(systemSymbolName: state.icon, accessibilityDescription: state.tooltip)?.withSymbolConfiguration(config)
    image.contentTintColor = tint
    image.frame = CGRect(x: (bounds.width - b) / 2, y: (bounds.height - b) / 2, width: b, height: b)
    toolTip = state.tooltip
    setAccessibilityLabel(state.tooltip)
    setAccessibilityRole(.button)
  }

  static func weight(_ name: String?) -> NSFont.Weight {
    switch name {
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "light": .light
    default: .regular
    }
  }
}
